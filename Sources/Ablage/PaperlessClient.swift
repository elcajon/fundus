import Foundation

enum ClientError: LocalizedError {
    case notConfigured
    /// Pangolin (badger) hat die Anfrage abgefangen, bevor sie Paperless erreicht hat.
    case pangolinLoginRequired
    /// Pangolin hat durchgelassen, aber Paperless kennt uns nicht.
    case paperlessUnauthorized
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Noch kein Server eingerichtet."
        case .pangolinLoginRequired: "Pangolin verlangt eine Anmeldung."
        case .paperlessUnauthorized: "Paperless hat die Anmeldung abgelehnt. API-Token prüfen."
        case let .http(code, body): "HTTP \(code): \(body.prefix(200))"
        }
    }
}

/// Spricht die Paperless-REST-API hinter Pangolin.
///
/// Durch Pangolin kommen wir mit dem Resource-Session-Cookie (`p_session_token`), das der
/// Login-Dialog aus dem WebView in `HTTPCookieStorage.shared` kopiert. Paperless selbst
/// authentifiziert per `Authorization: Token …`, ersatzweise über sein eigenes Session-Cookie.
final class PaperlessClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let baseURL: URL
    var token: String?
    /// Optionaler Pangolin-Access-Token als Alternative zum SSO-Cookie.
    var pangolinTokenID: String?
    var pangolinToken: String?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 60
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    var host: String { baseURL.host() ?? "" }

    // Redirects auf fremde Hosts (Pangolin-Login unter proxy.…) nicht folgen, sonst
    // landet deren HTML-Seite als "Antwort" im JSON-Decoder.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host() == host ? request : nil
    }

    // MARK: - Requests

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("application/json; version=9", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        if let id = pangolinTokenID, !id.isEmpty, let secret = pangolinToken, !secret.isEmpty {
            req.setValue(id, forHTTPHeaderField: "P-Access-Token-Id")
            req.setValue(secret, forHTTPHeaderField: "P-Access-Token")
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""

        if (300..<400).contains(http.statusCode) {
            // Relative Redirects (Django-Slash-Korrekturen) gehören zu Paperless, nicht zu Pangolin.
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            let target = URL(string: location, relativeTo: req.url)?.absoluteURL
            if location.contains("/auth/resource/") || target?.host() != host {
                throw ClientError.pangolinLoginRequired
            }
        }
        // Ältere Paperless-Versionen kennen API-Version 9 nicht: ohne Versions-Pin wiederholen.
        if http.statusCode == 406, req.value(forHTTPHeaderField: "Accept")?.contains("version=") == true {
            var retry = req
            retry.setValue("application/json", forHTTPHeaderField: "Accept")
            return try await perform(retry)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            // badger antwortet mit text/plain "Unauthorized", Paperless immer mit JSON.
            throw type.contains("json") ? ClientError.paperlessUnauthorized : ClientError.pangolinLoginRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        // Wenn Pangolin doch eine HTML-Seite mit 200 ausliefert (z. B. Wartungsmodus).
        if type.contains("text/html"), req.value(forHTTPHeaderField: "Accept")?.contains("json") == true {
            throw ClientError.pangolinLoginRequired
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(request(path, query: query))
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - API

    func profile() async throws -> Profile {
        try await get("api/profile/")
    }

    func documents(page: Int, filter: SidebarItem, search: String, pageSize: Int = 60) async throws -> Page<Document> {
        var q: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "page_size", value: String(pageSize)),
            .init(name: "truncate_content", value: "true"),
        ]
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            q.append(.init(name: "ordering", value: "-created"))
        } else {
            // Volltextsuche über den Whoosh-Index von Paperless, sortiert nach Relevanz.
            q.append(.init(name: "query", value: trimmed))
        }
        switch filter {
        case .all: break
        case .inbox: q.append(.init(name: "is_in_inbox", value: "true"))
        case let .tag(id): q.append(.init(name: "tags__id__all", value: String(id)))
        case let .correspondent(id): q.append(.init(name: "correspondent__id", value: String(id)))
        case let .documentType(id): q.append(.init(name: "document_type__id", value: String(id)))
        }
        return try await get("api/documents/", query: q)
    }

    func allNamed(_ endpoint: String) async throws -> [NamedItem] {
        let page: Page<NamedItem> = try await get("api/\(endpoint)/", query: [
            .init(name: "page_size", value: "1000"),
            .init(name: "ordering", value: "name"),
        ])
        return page.results
    }

    func document(_ id: Int) async throws -> Document {
        try await get("api/documents/\(id)/")
    }

    func thumbnail(_ id: Int) async throws -> Data {
        var req = request("api/documents/\(id)/thumb/")
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        return try await perform(req)
    }

    func preview(_ id: Int) async throws -> Data {
        var req = request("api/documents/\(id)/preview/")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await perform(req)
    }

    func download(_ id: Int, original: Bool) async throws -> Data {
        var req = request("api/documents/\(id)/download/",
                          query: original ? [.init(name: "original", value: "true")] : [])
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        return try await perform(req)
    }

    /// Lädt eine Datei in den Consume-Workflow hoch. Braucht den API-Token, weil Paperless
    /// bei reiner Session-Auth für POST ein CSRF-Token verlangt.
    func upload(fileURL: URL) async throws {
        guard token?.isEmpty == false else { throw ClientError.paperlessUnauthorized }
        let boundary = "Ablage-\(UUID().uuidString)"
        var req = request("api/documents/post_document/", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"document\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        req.httpBody = body
        _ = try await perform(req)
    }

    func webURL(for id: Int) -> URL {
        baseURL.appending(path: "documents/\(id)/details")
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
