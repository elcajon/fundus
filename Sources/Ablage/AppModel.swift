import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

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
    var showLogin = false {
        didSet { if showLogin { Task { await thumbnails.setBlocked(true) } } }
    }
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
    var selection: Int?
    var searchFocusRequest = 0
    /// Dokument, das gerade im Lesemodus offen ist.
    var readerID: Int?
    var zoom: Double = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1 {
        didSet { defaults.set(zoom, forKey: "zoom") }
    }
    var search = ""
    var documents: [Document] = []
    var totalCount = 0
    var isLoadingPage = false
    var toast: String?
    private var nextPage: Int? = 1
    private var loadGeneration = 0

    private(set) var client: PaperlessClient?
    let thumbnails = ThumbnailCache()
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private(set) lazy var watcher = NewDocumentWatcher(model: self)

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
        await thumbnails.setBlocked(false)
        phase = .ready
        await loadMetadata()
        await reload()
        watcher.start()
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
        watcher.stop()
        await CookieBridge.clearAll()
        apiToken = ""
        profile = nil
        documents = []
        await thumbnails.clear()
        await connect()
    }

    func forgetServer() async {
        watcher.stop()
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
        if let selection, document(selection) == nil { self.selection = nil }
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

    // MARK: - Aktionen

    func document(_ id: Int?) -> Document? {
        documents.first { $0.id == id }
    }

    var actionTarget: Document? { document(readerID ?? selection) }

    func openReader(_ id: Int? = nil) {
        guard let id = id ?? selection else { return }
        selection = id
        readerID = id
    }

    func step(_ delta: Int) {
        guard !documents.isEmpty else { return }
        let current = readerID ?? selection
        let index = documents.firstIndex { $0.id == current } ?? (delta > 0 ? -1 : documents.count)
        let next = documents[min(max(index + delta, 0), documents.count - 1)].id
        selection = next
        if readerID != nil { readerID = next }
        if index + delta >= documents.count - 8 { Task { await loadMore() } }
    }

    func zoomIn() { zoom = min(zoom * 1.2, 2.2) }
    func zoomOut() { zoom = max(zoom / 1.2, 0.5) }
    func resetView() { zoom = 1; search = ""; readerID = nil }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .plainText, .rtf, .item]
        panel.prompt = "Importieren"
        guard panel.runModal() == .OK else { return }
        Task { await upload(panel.urls) }
    }

    /// Lädt das Original in einen temporären Ordner, damit Teilen und Export echte Dateien haben.
    private func fetchOriginal(_ doc: Document) async -> URL? {
        guard let client else { return nil }
        do {
            let data = try await client.download(doc.id, original: true)
            let dir = FileManager.default.temporaryDirectory.appending(path: "Ablage-\(doc.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = doc.originalFileName ?? "\(doc.title).pdf"
            let url = dir.appending(path: name.replacingOccurrences(of: "/", with: "-"))
            try data.write(to: url)
            return url
        } catch {
            toast = error.localizedDescription
            return nil
        }
    }

    func share() async {
        guard let doc = actionTarget, let url = await fetchOriginal(doc),
              let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = NSRect(x: view.bounds.maxX - 90, y: view.bounds.maxY - 44, width: 30, height: 30)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func export() async {
        guard let doc = actionTarget else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.originalFileName ?? "\(doc.title).pdf"
        guard panel.runModal() == .OK, let target = panel.url,
              let source = await fetchOriginal(doc) else { return }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Vom Watcher gemeldete neue Dokumente vorne einsortieren, ohne das Raster neu zu laden.
    func insertNewDocuments(_ docs: [Document]) {
        guard search.isEmpty, filter == .all else { return }
        let known = Set(documents.map(\.id))
        let fresh = docs.filter { !known.contains($0.id) }.sorted { $0.id > $1.id }
        guard !fresh.isEmpty else { return }
        withAnimation(.smooth) { documents.insert(contentsOf: fresh, at: 0) }
        totalCount += fresh.count
    }

    /// Öffnet ein Dokument auch dann, wenn es noch nicht im geladenen Raster steckt.
    func openFromNotification(_ id: Int) async {
        if document(id) == nil, let client, let doc = try? await client.document(id) {
            insertNewDocuments([doc])
        }
        openReader(id)
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

    private var blocked = false

    func setBlocked(_ value: Bool) { blocked = value }

    func image(for id: Int, client: PaperlessClient) async -> NSImage? {
        if let image = images[id] { return image }
        // Solange Pangolin eine Anmeldung verlangt, keine 401-Salven erzeugen: CrowdSec wertet
        // 4xx-Serien aus und sperrt sonst die eigene IP.
        guard !blocked else { return nil }
        if let task = inFlight[id] { return await task.value }
        let task = Task { () -> NSImage? in
            do {
                return NSImage(data: try await client.thumbnail(id))
            } catch ClientError.pangolinLoginRequired {
                self.setBlocked(true)
                return nil
            } catch {
                return nil
            }
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
