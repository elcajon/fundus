import Foundation

enum ClientError: LocalizedError, Equatable {
    case notConfigured
    /// Pangolin (badger) hat die Anfrage abgefangen, bevor sie Paperless erreicht hat.
    case pangolinLoginRequired
    /// Pangolin hat durchgelassen, aber Paperless kennt uns nicht.
    case paperlessUnauthorized
    /// Schreibende Aufrufe brauchen den API-Token (Session-Auth verlangt sonst CSRF).
    case tokenRequired
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Noch kein Server eingerichtet.")
        case .pangolinLoginRequired:
            String(localized: "Pangolin verlangt eine Anmeldung.")
        case .paperlessUnauthorized:
            String(localized: "Paperless hat die Anmeldung abgelehnt. API-Token prüfen.")
        case .tokenRequired:
            String(localized: "Dafür wird ein Paperless-API-Token benötigt (Einstellungen → Verbindung).")
        case let .http(code, body):
            String(localized: "Serverfehler \(code): \(ClientError.shortDetail(body))")
        }
    }

    /// Paperless verpackt Fehler meist als `{"detail": "…"}` oder `{"feld": ["…"]}`.
    static func shortDetail(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                if let detail = dict["detail"] as? String { return detail }
                let parts = dict.compactMap { key, value -> String? in
                    if let list = value as? [String] { return "\(key): \(list.joined(separator: ", "))" }
                    if let text = value as? String { return "\(key): \(text)" }
                    return nil
                }
                if !parts.isEmpty { return parts.sorted().joined(separator: "; ") }
            }
        }
        return String(body.prefix(200))
    }
}

/// Wie eine Antwort zu verstehen ist. Getrennt von der Netzwerkschicht, damit sie testbar bleibt.
enum ResponseKind: Equatable {
    case ok
    case pangolinLogin
    case paperlessUnauthorized
    case retryWithAnyAccept
    case failure(Int)

    static func classify(status: Int, contentType: String, location: String?, requestURL: URL?,
                         host: String, accept: String?) -> ResponseKind {
        if (300..<400).contains(status) {
            // Relative Redirects (Django-Slash-Korrekturen) gehören zu Paperless, nicht zu Pangolin.
            let location = location ?? ""
            let target = URL(string: location, relativeTo: requestURL)?.absoluteURL
            if location.contains("/auth/resource/") || target?.host() != host {
                return .pangolinLogin
            }
            return .failure(status)
        }
        // Paperless kennt die API-Version vielleicht nicht, und DRF lehnt manche Accept-Header ab:
        // dann einmal ohne Einschränkung wiederholen.
        if status == 406, accept != "*/*" { return .retryWithAnyAccept }
        if status == 401 || status == 403 {
            // badger antwortet mit text/plain "Unauthorized", Paperless immer mit JSON.
            return contentType.contains("json") ? .paperlessUnauthorized : .pangolinLogin
        }
        guard (200..<300).contains(status) else { return .failure(status) }
        // Wenn Pangolin doch eine HTML-Seite mit 200 ausliefert (z. B. Anmelde- oder Wartungsseite).
        if contentType.contains("text/html"), accept?.contains("json") == true { return .pangolinLogin }
        return .ok
    }
}

/// Spricht die Paperless-REST-API hinter Pangolin.
///
/// Durch Pangolin kommen wir mit dem Resource-Session-Cookie (`p_session_token`), das der
/// Login-Dialog aus dem WebView in `HTTPCookieStorage.shared` kopiert. Paperless selbst
/// authentifiziert per `Authorization: Token …` (wird vor der Session geprüft, also ohne CSRF),
/// ersatzweise über sein eigenes Session-Cookie.
///
/// Hinweis: DELETE ohne Body wird von CrowdSec auf dem Pangolin-Stack über HTTP/3 geblockt.
/// Die App löscht deshalb nichts per DELETE, sondern deaktiviert z. B. Workflows per PATCH.
final class PaperlessClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let baseURL: URL
    var token: String?
    /// Paperless-Version aus dem `X-Version`-Header, z. B. "2.18.4".
    private(set) var serverVersion: String?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 60
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    var host: String { baseURL.host() ?? "" }
    var hasToken: Bool { token?.isEmpty == false }

    // Redirects auf fremde Hosts (Pangolin-Login unter proxy.…) nicht folgen, sonst
    // landet deren HTML-Seite als "Antwort" im JSON-Decoder.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host() == host ? request : nil
    }

    // MARK: - Requests

    /// URLComponents lässt `+` stehen, Django liest es als Leerzeichen (z. B. in `+02:00`).
    static func url(base: URL, path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") -> URLRequest {
        var req = URLRequest(url: Self.url(base: baseURL, path: path, query: query))
        req.httpMethod = method
        req.setValue("application/json; version=9", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func validate(_ data: Data, _ response: URLResponse, for req: URLRequest) throws -> ResponseKind {
        guard let http = response as? HTTPURLResponse else { return .ok }
        if let version = http.value(forHTTPHeaderField: "X-Version") { serverVersion = version }
        let kind = ResponseKind.classify(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
            location: http.value(forHTTPHeaderField: "Location"),
            requestURL: req.url,
            host: host,
            accept: req.value(forHTTPHeaderField: "Accept")
        )
        let path = req.url?.path() ?? ""
        switch kind {
        case .ok, .retryWithAnyAccept:
            return kind
        case .pangolinLogin:
            Log.network.info("\(req.httpMethod ?? "", privacy: .public) \(path, privacy: .public): Pangolin verlangt Anmeldung")
            throw ClientError.pangolinLoginRequired
        case .paperlessUnauthorized:
            Log.network.error("\(req.httpMethod ?? "", privacy: .public) \(path, privacy: .public): Paperless \(http.statusCode) \(String(decoding: data.prefix(300), as: UTF8.self), privacy: .public)")
            throw ClientError.paperlessUnauthorized
        case let .failure(code):
            let body = String(decoding: data, as: UTF8.self)
            Log.network.error("\(req.httpMethod ?? "", privacy: .public) \(path, privacy: .public): HTTP \(code) \(body.prefix(300), privacy: .public)")
            throw ClientError.http(code, body)
        }
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        if try validate(data, response, for: req) == .retryWithAnyAccept {
            var retry = req
            retry.setValue("*/*", forHTTPHeaderField: "Accept")
            return try await perform(retry)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(request(path, query: query))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.network.error("GET \(path, privacy: .public): Antwort nicht lesbar: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body) async throws -> T {
        guard hasToken else { throw ClientError.tokenRequired }
        var req = request(path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let data = try await perform(req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Lesen

    func profile() async throws -> Profile {
        try await get("api/profile/")
    }

    func documents(_ query: DocumentQuery, page: Int, pageSize: Int = 60) async throws -> Page<Document> {
        try await get("api/documents/", query: query.queryItems(page: page, pageSize: pageSize))
    }

    /// Die zuletzt hinzugefügten Dokumente, unabhängig von Suche und Ansicht.
    func latestDocuments(count: Int = 25) async throws -> [Document] {
        let page: Page<Document> = try await get("api/documents/", query: [
            .init(name: "ordering", value: "-added"),
            .init(name: "page_size", value: String(count)),
            .init(name: "truncate_content", value: "true"),
        ])
        return page.results
    }

    /// Eine Seite der vollständigen Bibliothek mit Text, für Offline-Kopie und Spotlight.
    func libraryPage(page: Int, modifiedAfter: String?, pageSize: Int = 100) async throws -> Page<Document> {
        var query: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "page_size", value: String(pageSize)),
            .init(name: "ordering", value: "id"),
            .init(name: "fields", value: "id,title,correspondent,document_type,tags,created,added,modified,content,page_count,original_file_name,custom_fields"),
        ]
        if let modifiedAfter { query.append(.init(name: "modified__gt", value: modifiedAfter)) }
        return try await get("api/documents/", query: query)
    }

    /// Nur die IDs aller Dokumente, um Gelöschtes zu erkennen.
    func allDocumentIDs() async throws -> [Int] {
        struct IDs: Decodable { let all: [Int]? }
        let page: IDs = try await get("api/documents/", query: [
            .init(name: "page_size", value: "1"),
            .init(name: "fields", value: "id"),
        ])
        return page.all ?? []
    }

    func allNamed(_ endpoint: String) async throws -> [NamedItem] {
        let page: Page<NamedItem> = try await get("api/\(endpoint)/", query: [
            .init(name: "page_size", value: "100000"),
            .init(name: "ordering", value: "name"),
        ])
        return page.results
    }

    /// Holt einen API-Token mit Benutzername und Passwort (`/api/token/`).
    /// Läuft bewusst ohne Wiederholung: Eine falsche Eingabe ergibt einen 4xx, und davon
    /// sollen keine Serien entstehen.
    func obtainToken(username: String, password: String) async throws -> String {
        var req = request("api/token/", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, response) = try await session.data(for: req)
        _ = try validate(data, response, for: req)
        struct Answer: Decodable { let token: String }
        return try JSONDecoder().decode(Answer.self, from: data).token
    }

    func customFields() async throws -> [CustomFieldDefinition] {
        let page: Page<CustomFieldDefinition> = try await get("api/custom_fields/", query: [
            .init(name: "page_size", value: "100000"),
            .init(name: "ordering", value: "name"),
        ])
        return page.results
    }

    func document(_ id: Int) async throws -> Document {
        try await get("api/documents/\(id)/")
    }

    private func binary(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var req = request(path, query: query)
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await perform(req)
    }

    func thumbnail(_ id: Int) async throws -> Data {
        try await binary("api/documents/\(id)/thumb/")
    }

    func preview(_ id: Int) async throws -> Data {
        try await binary("api/documents/\(id)/preview/")
    }

    func download(_ id: Int, original: Bool) async throws -> Data {
        try await binary("api/documents/\(id)/download/", query: original ? [.init(name: "original", value: "true")] : [])
    }

    func task(_ taskID: String) async throws -> TaskStatus? {
        let list: TaskList = try await get("api/tasks/", query: [.init(name: "task_id", value: taskID)])
        return list.tasks.first
    }

    // MARK: - Schreiben

    func update(_ id: Int, _ update: DocumentUpdate) async throws -> Document {
        try await send("PATCH", "api/documents/\(id)/", body: update)
    }

    /// Lädt eine Datei in den Consume-Workflow hoch und gibt die Task-ID zurück.
    /// Der Body wird als Datei gestreamt, damit große Scans nicht komplett im Speicher landen.
    func upload(fileURL: URL) async throws -> String {
        guard hasToken else { throw ClientError.tokenRequired }
        let boundary = "Ablage-\(UUID().uuidString)"
        var req = request("api/documents/post_document/", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyURL = TempFiles.directory.appending(path: "upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Self.writeMultipartBody(to: bodyURL, file: fileURL, boundary: boundary)

        let (data, response) = try await session.upload(for: req, fromFile: bodyURL)
        _ = try validate(data, response, for: req)
        // Paperless antwortet mit der Task-ID als JSON-String (v10: als Objekt).
        if let id = try? JSONDecoder().decode(String.self, from: data) { return id }
        struct Wrapped: Decodable { let task_id: String }
        return try JSONDecoder().decode(Wrapped.self, from: data).task_id
    }

    static func writeMultipartBody(to target: URL, file: URL, boundary: String) throws {
        FileManager.default.createFile(atPath: target.path(), contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    func webURL(for id: Int) -> URL {
        baseURL.appending(path: "documents/\(id)/details")
    }
}

/// Ein gemeinsamer Temp-Ordner, der beim Start geleert wird.
enum TempFiles {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "Ablage", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func cleanUp() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path().hasPrefix(directory.standardizedFileURL.path())
    }
}
