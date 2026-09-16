import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case unconfigured
        case connecting
        case ready
        case failed(String)
    }

    var phase: Phase = .unconfigured
    var showLogin = false
    var loginHint = "Melde dich über Pangolin an. Das Fenster schließt sich, sobald Paperless erreichbar ist."

    var serverURL: URL?
    var profile: Profile?

    var tags: [NamedItem] = []
    var correspondents: [NamedItem] = []
    var documentTypes: [NamedItem] = []
    private var tagsByID: [Int: NamedItem] = [:]
    private var correspondentsByID: [Int: NamedItem] = [:]
    private var typesByID: [Int: NamedItem] = [:]

    var filter: SidebarItem = .all
    var search = ""
    var documents: [Document] = []
    var totalCount = 0
    var isLoadingPage = false
    var toast: String?
    private var nextPage: Int? = 1
    private var loadGeneration = 0

    private(set) var client: PaperlessClient?
    let thumbnails = ThumbnailCache()

    private let defaults = UserDefaults.standard

    init() {
        if let stored = defaults.string(forKey: "serverURL"), let url = URL(string: stored) {
            serverURL = url
            Task { await connect() }
        }
    }

    // MARK: - Einstellungen

    var apiToken: String {
        get { serverURL.flatMap { Keychain.token(for: $0.absoluteString) } ?? "" }
        set {
            guard let serverURL else { return }
            Keychain.setToken(newValue, for: serverURL.absoluteString)
            client?.token = newValue
        }
    }

    var pangolinTokenID: String {
        get { defaults.string(forKey: "pangolinTokenID") ?? "" }
        set { defaults.set(newValue, forKey: "pangolinTokenID"); client?.pangolinTokenID = newValue }
    }

    var pangolinToken: String {
        get { serverURL.flatMap { Keychain.token(for: "pangolin@" + $0.absoluteString) } ?? "" }
        set {
            guard let serverURL else { return }
            Keychain.setToken(newValue, for: "pangolin@" + serverURL.absoluteString)
            client?.pangolinToken = newValue
        }
    }

    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    func configure(server: String, apiToken: String) async {
        guard let url = Self.normalize(server) else {
            phase = .failed("Das sieht nicht nach einer Server-Adresse aus.")
            return
        }
        serverURL = url
        defaults.set(url.absoluteString, forKey: "serverURL")
        if !apiToken.isEmpty { self.apiToken = apiToken }
        await connect()
    }

    // MARK: - Verbindung

    func connect() async {
        guard let serverURL else { phase = .unconfigured; return }
        phase = .connecting
        let client = PaperlessClient(baseURL: serverURL, token: apiToken)
        client.pangolinTokenID = pangolinTokenID
        client.pangolinToken = pangolinToken
        self.client = client
        await CookieBridge.syncFromWebView(host: client.host)

        do {
            try await finishConnecting(client)
        } catch ClientError.pangolinLoginRequired {
            loginHint = "Pangolin verlangt eine Anmeldung. Das Fenster schließt sich, sobald Paperless erreichbar ist."
            showLogin = true
            phase = .failed("Anmeldung bei Pangolin erforderlich.")
        } catch ClientError.paperlessUnauthorized {
            loginHint = "Pangolin lässt dich durch. Jetzt noch bei Paperless anmelden."
            showLogin = true
            phase = .failed("Paperless hat die Anmeldung abgelehnt.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func finishConnecting(_ client: PaperlessClient) async throws {
        let profile = try await client.profile()
        self.profile = profile
        // Nach dem SSO-Login kennt Paperless uns per Session-Cookie. Wenn der Nutzer schon einen
        // API-Token hat, übernehmen wir ihn, dann funktionieren auch Uploads ohne CSRF-Tanz.
        if apiToken.isEmpty, let token = profile.authToken, !token.isEmpty {
            apiToken = token
        }
        showLogin = false
        phase = .ready
        await loadMetadata()
        await reload()
    }

    /// Wird vom Login-WebView bei jeder fertig geladenen Seite auf dem Paperless-Host aufgerufen.
    func loginWebViewLanded() async {
        guard let client else { return }
        await CookieBridge.syncFromWebView(host: client.host)
        do {
            try await finishConnecting(client)
        } catch ClientError.paperlessUnauthorized {
            loginHint = "Pangolin lässt dich durch. Jetzt noch bei Paperless anmelden."
        } catch {
            // Noch mitten im Login-Ablauf, einfach weiter warten.
        }
    }

    func signOut() async {
        await CookieBridge.clearAll()
        apiToken = ""
        profile = nil
        documents = []
        await thumbnails.clear()
        await connect()
    }

    func forgetServer() async {
        await CookieBridge.clearAll()
        apiToken = ""
        pangolinToken = ""
        pangolinTokenID = ""
        defaults.removeObject(forKey: "serverURL")
        serverURL = nil
        client = nil
        profile = nil
        documents = []
        await thumbnails.clear()
        phase = .unconfigured
    }

    // MARK: - Daten

    func loadMetadata() async {
        guard let client else { return }
        async let t = client.allNamed("tags")
        async let c = client.allNamed("correspondents")
        async let d = client.allNamed("document_types")
        tags = (try? await t) ?? []
        correspondents = (try? await c) ?? []
        documentTypes = (try? await d) ?? []
        tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        correspondentsByID = Dictionary(uniqueKeysWithValues: correspondents.map { ($0.id, $0) })
        typesByID = Dictionary(uniqueKeysWithValues: documentTypes.map { ($0.id, $0) })
    }

    func reload() async {
        loadGeneration += 1
        nextPage = 1
        documents = []
        totalCount = 0
        isLoadingPage = false
        await loadMore()
    }

    func loadMore() async {
        guard let client, let page = nextPage, !isLoadingPage else { return }
        isLoadingPage = true
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoadingPage = false } }
        do {
            let result = try await client.documents(page: page, filter: filter, search: search)
            guard generation == loadGeneration else { return }
            let known = Set(documents.map(\.id))
            documents.append(contentsOf: result.results.filter { !known.contains($0.id) })
            totalCount = result.count
            nextPage = result.next == nil ? nil : page + 1
        } catch ClientError.pangolinLoginRequired {
            guard generation == loadGeneration else { return }
            nextPage = page
            loginHint = "Die Pangolin-Session ist abgelaufen. Bitte neu anmelden."
            showLogin = true
        } catch {
            guard generation == loadGeneration else { return }
            if (error as? URLError)?.code == .cancelled { return }
            toast = error.localizedDescription
        }
    }

    func upload(_ urls: [URL]) async {
        guard let client else { return }
        var done = 0
        for url in urls {
            do {
                try await client.upload(fileURL: url)
                done += 1
            } catch ClientError.paperlessUnauthorized {
                toast = "Für Uploads brauche ich einen Paperless-API-Token (Einstellungen)."
                return
            } catch {
                toast = "\(url.lastPathComponent): \(error.localizedDescription)"
                return
            }
        }
        toast = done == 1 ? "1 Dokument an Paperless übergeben." : "\(done) Dokumente an Paperless übergeben."
    }

    // MARK: - Lookups

    func tag(_ id: Int) -> NamedItem? { tagsByID[id] }
    func correspondentName(_ id: Int?) -> String? { id.flatMap { correspondentsByID[$0]?.name } }
    func typeName(_ id: Int?) -> String? { id.flatMap { typesByID[$0]?.name } }

    var filterTitle: String {
        switch filter {
        case .all: "Alle Dokumente"
        case .inbox: "Eingang"
        case let .tag(id): tagsByID[id]?.name ?? "Tag"
        case let .correspondent(id): correspondentsByID[id]?.name ?? "Korrespondent"
        case let .documentType(id): typesByID[id]?.name ?? "Dokumenttyp"
        }
    }
}

actor ThumbnailCache {
    private var images: [Int: NSImage] = [:]
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]

    func image(for id: Int, client: PaperlessClient) async -> NSImage? {
        if let image = images[id] { return image }
        if let task = inFlight[id] { return await task.value }
        let task = Task { () -> NSImage? in
            guard let data = try? await client.thumbnail(id) else { return nil }
            return NSImage(data: data)
        }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        if let image { images[id] = image }
        return image
    }

    func clear() {
        images.removeAll()
    }
}

extension Color {
    init?(hex: String?) {
        guard var hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
