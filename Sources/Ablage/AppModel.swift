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
        /// Server nicht erreichbar, die App zeigt die lokale Kopie.
        case offline(String)
        case failed(String)
    }

    var phase: Phase = .unconfigured
    var showLogin = false {
        didSet { if showLogin { Task { await thumbnails.setBlocked(true) } } }
    }
    var loginHint = String(localized: "Melde dich über Pangolin an. Das Fenster schließt sich, sobald Paperless erreichbar ist.")

    var serverURL: URL?
    var profile: Profile?

    var tags: [NamedItem] = []
    var correspondents: [NamedItem] = []
    var documentTypes: [NamedItem] = []
    private var tagsByID: [Int: NamedItem] = [:]
    private var correspondentsByID: [Int: NamedItem] = [:]
    private var typesByID: [Int: NamedItem] = [:]

    // MARK: Ansicht

    var selectedIDs: Set<Int> = []
    /// Das zuletzt angeklickte Dokument: Ziel für Lesemodus, Pfeiltasten und Bereichsauswahl.
    var focusedID: Int?
    var readerID: Int?
    var showInspector = false
    var searchFocusRequest = 0
    var zoom: Double = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1 {
        didSet { defaults.set(zoom, forKey: "zoom") }
    }
    var sort: DocumentSort = DocumentSort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .created {
        didSet {
            defaults.set(sort.rawValue, forKey: "sort")
            Task { await reload() }
        }
    }

    /// Freitext im Suchfeld. Abgeschlossene `#tag`/`@name`/`typ:x`-Wörter werden zu Tokens.
    var search = "" {
        didSet {
            guard !isNormalizingSearch, search != oldValue else { return }
            normalizeSearch(final: false)
        }
    }
    var searchTokens: [SearchToken] = []
    @ObservationIgnored private var isNormalizingSearch = false

    var query: DocumentQuery { DocumentQuery(text: search, tokens: searchTokens, sort: sort) }

    var documents: [Document] = []
    var totalCount = 0
    var isLoadingPage = false
    var toast: String?
    private var nextPage: Int? = 1
    private var loadGeneration = 0

    // MARK: Hintergrund

    var imports: [ImportJob] = []
    var activeImportCount: Int { imports.filter(\.isActive).count }
    var showImports = false
    /// Neueste vom Watcher gemeldete Dokumente, für das Menüleisten-Menü.
    var recentNew: [Document] = []
    var isSyncing = false
    var lastSync: Date?
    /// Dokumente, die diese App selbst importiert hat: nicht zusätzlich als „neu“ melden.
    @ObservationIgnored var ownImports: Set<Int> = []

    private(set) var client: PaperlessClient?
    private(set) var store: LibraryStore?
    let thumbnails = ThumbnailCache()
    @ObservationIgnored private var openWindowAction: (() -> Void)?
    @ObservationIgnored private(set) lazy var watcher = NewDocumentWatcher(model: self)
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard

    static let shared = AppModel()

    private init() {
        if let stored = defaults.string(forKey: "serverURL"), let url = URL(string: stored) {
            serverURL = url
            Task { await connect() }
        }
    }

    // MARK: - Einstellungen

    // Schlüsselbund-Werte nur einmal lesen: jeder Zugriff kann sonst eine Passwortabfrage auslösen.
    @ObservationIgnored private var secretCache: [String: String] = [:]

    private func secret(_ account: String) -> String {
        if let cached = secretCache[account] { return cached }
        let value = Keychain.token(for: account) ?? ""
        secretCache[account] = value
        return value
    }

    /// Liest die Geheimnisse abseits des Hauptthreads vor. Eine Schlüsselbund-Abfrage blockiert so
    /// nicht das Fenster, und die späteren Zugriffe kommen aus dem Cache.
    private func preloadSecrets() async {
        guard let serverURL else { return }
        let accounts = [serverURL.absoluteString, "pangolin@" + serverURL.absoluteString]
            .filter { secretCache[$0] == nil }
        guard !accounts.isEmpty else { return }
        let values = await Task.detached(priority: .userInitiated) {
            accounts.map { Keychain.token(for: $0) ?? "" }
        }.value
        for (account, value) in zip(accounts, values) { secretCache[account] = value }
    }

    private func setSecret(_ value: String, _ account: String) {
        guard secretCache[account] != value else { return }
        secretCache[account] = value
        Keychain.setToken(value, for: account)
    }

    var apiToken: String {
        get { serverURL.map { secret($0.absoluteString) } ?? "" }
        set {
            guard let serverURL else { return }
            setSecret(newValue, serverURL.absoluteString)
            client?.token = newValue
        }
    }

    var pangolinTokenID: String {
        get { defaults.string(forKey: "pangolinTokenID") ?? "" }
        set { defaults.set(newValue, forKey: "pangolinTokenID"); client?.pangolinTokenID = newValue }
    }

    var pangolinToken: String {
        get { serverURL.map { secret("pangolin@" + $0.absoluteString) } ?? "" }
        set {
            guard let serverURL else { return }
            setSecret(newValue, "pangolin@" + serverURL.absoluteString)
            client?.pangolinToken = newValue
        }
    }

    var canEdit: Bool { client?.hasToken == true && phase == .ready }

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
            phase = .failed(String(localized: "Das sieht nicht nach einer Server-Adresse aus."))
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
        await preloadSecrets()
        let client = PaperlessClient(baseURL: serverURL, token: apiToken)
        client.pangolinTokenID = pangolinTokenID
        client.pangolinToken = pangolinToken
        self.client = client
        let store = self.store?.root.lastPathComponent == client.host ? self.store! : LibraryStore(host: client.host)
        self.store = store
        await thumbnails.attach(store)
        await CookieBridge.syncFromWebView(host: client.host)

        do {
            try await finishConnecting(client)
        } catch ClientError.pangolinLoginRequired {
            loginHint = String(localized: "Pangolin verlangt eine Anmeldung. Das Fenster schließt sich, sobald Paperless erreichbar ist.")
            showLogin = true
            await showOffline(String(localized: "Anmeldung bei Pangolin erforderlich."))
        } catch ClientError.paperlessUnauthorized {
            loginHint = String(localized: "Pangolin lässt dich durch. Jetzt noch bei Paperless anmelden.")
            showLogin = true
            await showOffline(String(localized: "Paperless hat die Anmeldung abgelehnt."))
        } catch {
            Log.app.error("Verbindung fehlgeschlagen: \(String(describing: error), privacy: .public)")
            await showOffline(error.localizedDescription)
        }
    }

    /// Zeigt die lokale Kopie, falls vorhanden, sonst den Fehler.
    private func showOffline(_ reason: String) async {
        guard let store, !(await store.isEmpty) else {
            phase = .failed(reason)
            return
        }
        let snapshot = await store.current()
        applyMetadata(tags: snapshot.tags, correspondents: snapshot.correspondents, types: snapshot.types)
        phase = .offline(reason)
        await reload()
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
        startSync()
    }

    /// Wird vom Login-WebView bei jeder fertig geladenen Seite auf dem Paperless-Host aufgerufen.
    func loginWebViewLanded() async {
        guard let client else { return }
        await CookieBridge.syncFromWebView(host: client.host)
        do {
            try await finishConnecting(client)
        } catch ClientError.paperlessUnauthorized {
            loginHint = String(localized: "Pangolin lässt dich durch. Jetzt noch bei Paperless anmelden.")
        } catch {
            // Noch mitten im Login-Ablauf, einfach weiter warten.
        }
    }

    func signOut() async {
        watcher.stop()
        syncTask?.cancel()
        await CookieBridge.clearAll()
        apiToken = ""
        profile = nil
        documents = []
        await thumbnails.clear()
        await connect()
    }

    func forgetServer() async {
        watcher.stop()
        syncTask?.cancel()
        await CookieBridge.clearAll()
        apiToken = ""
        pangolinToken = ""
        pangolinTokenID = ""
        defaults.removeObject(forKey: "serverURL")
        await store?.clear()
        await SpotlightIndexer.removeAll()
        serverURL = nil
        client = nil
        store = nil
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
        do {
            let (tags, correspondents, types) = try await (t, c, d)
            applyMetadata(tags: tags, correspondents: correspondents, types: types)
            await store?.setMetadata(tags: tags, correspondents: correspondents, types: types)
        } catch {
            Log.network.error("Tags/Korrespondenten/Typen nicht geladen: \(String(describing: error), privacy: .public)")
            toast = String(localized: "Tags und Korrespondenten konnten nicht geladen werden: \(error.localizedDescription)")
        }
    }

    private func applyMetadata(tags: [NamedItem], correspondents: [NamedItem], types: [NamedItem]) {
        self.tags = tags
        self.correspondents = correspondents
        self.documentTypes = types
        tagsByID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        correspondentsByID = Dictionary(correspondents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        typesByID = Dictionary(types.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func reload() async {
        loadGeneration += 1
        nextPage = 1
        documents = []
        totalCount = 0
        isLoadingPage = false
        await loadMore()
        selectedIDs = selectedIDs.filter { document($0) != nil }
        if let focusedID, document(focusedID) == nil { self.focusedID = nil }
    }

    func loadMore() async {
        if case .offline = phase {
            await loadFromStore()
            return
        }
        guard let client, let page = nextPage, !isLoadingPage, phase == .ready else { return }
        isLoadingPage = true
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoadingPage = false } }
        do {
            let result = try await client.documents(query, page: page)
            guard generation == loadGeneration else { return }
            let known = Set(documents.map(\.id))
            documents.append(contentsOf: result.results.filter { !known.contains($0.id) })
            totalCount = result.count
            nextPage = result.next == nil ? nil : page + 1
        } catch ClientError.pangolinLoginRequired {
            guard generation == loadGeneration else { return }
            nextPage = page
            loginHint = String(localized: "Die Pangolin-Session ist abgelaufen. Bitte neu anmelden.")
            showLogin = true
        } catch {
            guard generation == loadGeneration else { return }
            if (error as? URLError)?.code == .cancelled { return }
            if error is URLError {
                // Netz weg: auf die lokale Kopie umschalten.
                await showOffline(error.localizedDescription)
                return
            }
            toast = error.localizedDescription
        }
    }

    private func loadFromStore() async {
        guard let store, nextPage != nil else { return }
        let docs = await store.documents(matching: query)
        documents = docs
        totalCount = docs.count
        nextPage = nil
    }

    // MARK: - Abgleich (Offline-Kopie und Spotlight)

    func startSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncLibrary()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func syncLibrary(forceFull: Bool = false) async {
        guard let client, let store, phase == .ready, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let snapshot = await store.current()
        let full = forceFull || snapshot.lastModified == nil
            || (snapshot.lastFullSync.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true)
        let since = full ? nil : snapshot.lastModified
        do {
            var page = 1
            var changed: [Document] = []
            while true {
                let result = try await client.libraryPage(page: page, modifiedAfter: since)
                let newest = result.results.compactMap(\.modified).max()
                changed += await store.upsert(result.results, lastModified: newest)
                guard result.next != nil else { break }
                page += 1
            }
            var removed: [Int] = []
            if full {
                let ids = try await client.allDocumentIDs()
                if !ids.isEmpty { removed = await store.retainOnly(Set(ids)) }
            }
            // Beim ersten Mal (oder nach Änderungen am Index-Format) alles melden, sonst nur Änderungen.
            let reindexAll = SpotlightIndexer.isEnabled && defaults.integer(forKey: Self.spotlightVersionKey) < Self.spotlightVersion
            if reindexAll { await SpotlightIndexer.removeAll() }
            let toIndex = reindexAll ? Array(await store.current().documents.values) : changed
            await SpotlightIndexer.index(toIndex, names: spotlightNames, store: store)
            if reindexAll { defaults.set(Self.spotlightVersion, forKey: Self.spotlightVersionKey) }
            await SpotlightIndexer.remove(removed)
            lastSync = Date()
            Log.sync.info("Abgleich: \(changed.count) geändert, \(removed.count) entfernt, voll: \(full)")
            await fetchMissingThumbnails()
        } catch {
            Log.sync.error("Abgleich fehlgeschlagen: \(String(describing: error), privacy: .public)")
        }
    }

    private static let spotlightVersionKey = "spotlightIndexVersion"
    private static let spotlightVersion = 2

    /// Lädt fehlende Vorschaubilder nacheinander nach, damit Offline-Raster und Spotlight sie haben.
    /// Bricht ab, sobald Pangolin eine Anmeldung verlangt (keine 401-Salven).
    private func fetchMissingThumbnails() async {
        guard let client, let store else { return }
        let missing = await store.current().documents.keys.sorted(by: >)
            .filter { !FileManager.default.fileExists(atPath: store.thumbURL($0).path()) }
        guard !missing.isEmpty else { return }
        var fetched: [Int] = []
        for id in missing {
            guard phase == .ready, !Task.isCancelled else { break }
            do {
                store.storeThumbnail(try await client.thumbnail(id), for: id)
                fetched.append(id)
                if fetched.count % 100 == 0 { await indexThumbnails(fetched.suffix(100)) }
            } catch ClientError.pangolinLoginRequired {
                break
            } catch {
                Log.sync.error("Vorschaubild \(id) fehlt: \(String(describing: error), privacy: .public)")
            }
        }
        await indexThumbnails(fetched.suffix(fetched.count % 100))
        Log.sync.info("Vorschaubilder: \(fetched.count) von \(missing.count) nachgeladen")
    }

    private func indexThumbnails(_ ids: ArraySlice<Int>) async {
        guard let store, !ids.isEmpty else { return }
        let docs = await store.current().documents
        await SpotlightIndexer.index(ids.compactMap { docs[$0] }, names: spotlightNames, store: store)
    }

    var spotlightNames: SpotlightIndexer.Names {
        .init(tags: tagsByID.mapValues(\.name),
              correspondents: correspondentsByID.mapValues(\.name),
              types: typesByID.mapValues(\.name))
    }

    func setSpotlight(enabled: Bool) async {
        defaults.set(enabled, forKey: SpotlightIndexer.enabledKey)
        guard let store else { return }
        if enabled {
            let docs = Array(await store.current().documents.values)
            await SpotlightIndexer.index(docs, names: spotlightNames, store: store)
        } else {
            await SpotlightIndexer.removeAll()
        }
    }

    func clearOfflineCopy() async {
        await store?.clear()
        await SpotlightIndexer.removeAll()
        await thumbnails.clear()
        Task { await syncLibrary(forceFull: true) }
    }

    // MARK: - Suche

    var parser: SearchParser {
        SearchParser(tags: tags, correspondents: correspondents, types: documentTypes)
    }

    private func normalizeSearch(final: Bool) {
        let (text, found) = parser.parse(search, final: final)
        guard !found.isEmpty else { return }
        isNormalizingSearch = true
        search = text
        isNormalizingSearch = false
        for token in found where !searchTokens.contains(token) { searchTokens.append(token) }
    }

    func submitSearch() {
        normalizeSearch(final: true)
    }

    func addToken(_ token: SearchToken) {
        isNormalizingSearch = true
        search = SearchParser.removingTrailingPrefixWord(search)
        isNormalizingSearch = false
        if !searchTokens.contains(token) { searchTokens.append(token) }
    }

    func toggleInbox() {
        if let index = searchTokens.firstIndex(of: .inbox) {
            searchTokens.remove(at: index)
        } else {
            searchTokens.insert(.inbox, at: 0)
        }
    }

    var tokenSuggestions: [SearchToken] { parser.suggestions(for: search) }

    func name(of token: SearchToken) -> String {
        switch token {
        case .inbox: String(localized: "Eingang")
        case let .tag(id): tagsByID[id]?.name ?? "#\(id)"
        case let .correspondent(id): correspondentsByID[id]?.name ?? "@\(id)"
        case let .documentType(id): typesByID[id]?.name ?? "\(id)"
        }
    }

    func symbol(of token: SearchToken) -> String {
        switch token {
        case .inbox: "tray"
        case .tag: "tag"
        case .correspondent: "person"
        case .documentType: "doc.text"
        }
    }

    // MARK: - Auswahl

    func document(_ id: Int?) -> Document? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    /// Klick auf ein Dokument, mit ⌘ zum Hinzufügen und ⇧ für Bereiche.
    func click(_ id: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if focusedID == id { focusedID = selectedIDs.first }
            } else {
                selectedIDs.insert(id)
                focusedID = id
            }
        } else if modifiers.contains(.shift), let anchor = focusedID,
                  let from = documents.firstIndex(where: { $0.id == anchor }),
                  let to = documents.firstIndex(where: { $0.id == id }) {
            let range = min(from, to)...max(from, to)
            selectedIDs.formUnion(documents[range].map(\.id))
        } else {
            select(id)
        }
    }

    func select(_ id: Int?) {
        selectedIDs = id.map { [$0] } ?? []
        focusedID = id
    }

    func selectAll() {
        selectedIDs = Set(documents.map(\.id))
        if focusedID == nil { focusedID = documents.first?.id }
    }

    /// Worauf Teilen, Export & Co. wirken: im Lesemodus das offene Dokument, sonst die Auswahl.
    var actionTargets: [Document] {
        if let reader = document(readerID) { return [reader] }
        return documents.filter { selectedIDs.contains($0.id) }
    }

    var focusedDocument: Document? { document(readerID ?? focusedID) }

    func openReader(_ id: Int? = nil) {
        guard let id = id ?? focusedID else { return }
        select(id)
        readerID = id
    }

    func step(_ delta: Int) {
        guard !documents.isEmpty else { return }
        let current = readerID ?? focusedID
        let index = documents.firstIndex { $0.id == current } ?? (delta > 0 ? -1 : documents.count)
        let next = documents[min(max(index + delta, 0), documents.count - 1)].id
        select(next)
        if readerID != nil { readerID = next }
        if index + delta >= documents.count - 8 { Task { await loadMore() } }
    }

    func zoomIn() { zoom = min(zoom * 1.2, 2.2) }
    func zoomOut() { zoom = max(zoom / 1.2, 0.5) }
    func resetView() {
        zoom = 1
        search = ""
        searchTokens = []
        readerID = nil
    }

    // MARK: - Bearbeiten

    /// Speichert Änderungen und ersetzt das Dokument in Liste und lokaler Kopie.
    @discardableResult
    func save(_ id: Int, _ update: DocumentUpdate) async -> Bool {
        guard let client else { return false }
        do {
            var saved = try await client.update(id, update)
            if let old = document(id) {
                // Die Antwort enthält den vollen Text; für das Raster genügt der bisherige.
                saved.searchHit = old.searchHit
            }
            replace(saved)
            await store?.upsert([saved], lastModified: nil)
            if let store { await SpotlightIndexer.index([saved], names: spotlightNames, store: store) }
            return true
        } catch {
            Log.app.error("Speichern von \(id) fehlgeschlagen: \(String(describing: error), privacy: .public)")
            toast = error.localizedDescription
            return false
        }
    }

    private func replace(_ doc: Document) {
        guard let index = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        documents[index] = doc
        // Passt es nicht mehr zum Filter (z. B. Eingang erledigt), fällt es aus der Liste.
        if searchTokens.contains(.inbox), inboxTagIDs.isDisjoint(with: doc.tags) {
            let wasReader = readerID == doc.id
            let next = documents.indices.contains(index + 1) ? documents[index + 1].id
                : (index > 0 ? documents[index - 1].id : nil)
            documents.remove(at: index)
            totalCount = max(totalCount - 1, 0)
            select(next)
            if wasReader { readerID = next }
        }
    }

    var inboxTagIDs: Set<Int> { Set(tags.filter(\.isInboxTag).map(\.id)) }

    func isInInbox(_ doc: Document) -> Bool { !inboxTagIDs.isDisjoint(with: doc.tags) }

    /// Entfernt die Eingangs-Tags und springt zum nächsten Dokument.
    func markDone(_ id: Int, with update: DocumentUpdate? = nil) async {
        guard let doc = document(id) else { return }
        var change = update ?? DocumentUpdate(doc)
        change.tags.removeAll { inboxTagIDs.contains($0) }
        let stillListed = !searchTokens.contains(.inbox)
        if await save(id, change), stillListed {
            step(1)
        }
    }

    // MARK: - Importe

    struct ImportJob: Identifiable {
        enum State: Equatable {
            case uploading
            case processing
            case done(documentID: Int?)
            case failed(String)
        }

        let id = UUID()
        let fileName: String
        let started = Date()
        var taskID: String?
        var state: State = .uploading

        var isActive: Bool { state == .uploading || state == .processing }
        var isFailed: Bool { if case .failed = state { true } else { false } }
    }

    var failedImportCount: Int { imports.filter(\.isFailed).count }

    func upload(_ urls: [URL]) async {
        // Eigene Dateien (aus dem Fenster gezogen) nicht wieder importieren.
        let files = urls.filter { !TempFiles.contains($0) }
        guard let client, !files.isEmpty else { return }
        guard client.hasToken else {
            toast = ClientError.tokenRequired.localizedDescription
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for url in files {
                let job = ImportJob(fileName: url.lastPathComponent)
                imports.insert(job, at: 0)
                group.addTask { await self.runImport(job.id, url: url, client: client) }
            }
        }
        let failed = imports.prefix(files.count).filter(\.isFailed).count
        if failed > 0 {
            toast = String(localized: "\(failed) von \(files.count) Importen fehlgeschlagen. Details unter Ablage → Importe.")
        } else {
            toast = files.count == 1
                ? String(localized: "Dokument importiert.")
                : String(localized: "\(files.count) Dokumente importiert.")
        }
    }

    private func updateJob(_ id: UUID, _ change: (inout ImportJob) -> Void) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        change(&imports[index])
    }

    private func runImport(_ jobID: UUID, url: URL, client: PaperlessClient) async {
        do {
            let taskID = try await client.upload(fileURL: url)
            updateJob(jobID) { $0.taskID = taskID; $0.state = .processing }
            Log.imports.info("\(url.lastPathComponent, privacy: .public) hochgeladen, Task \(taskID, privacy: .public)")
            // Verarbeitung abwarten: OCR kann dauern, nach 15 Minuten geben wir auf.
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                try await Task.sleep(for: .seconds(3))
                guard let status = try await client.task(taskID), status.isFinished else { continue }
                if status.state == .success {
                    if let docID = status.relatedDocument {
                        ownImports.insert(docID)
                        if let doc = try? await client.document(docID) { insertNewDocuments([doc]) }
                    }
                    updateJob(jobID) { $0.state = .done(documentID: status.relatedDocument) }
                } else {
                    let message = status.result ?? String(localized: "Paperless hat den Import abgelehnt.")
                    Log.imports.error("\(url.lastPathComponent, privacy: .public): \(message, privacy: .public)")
                    updateJob(jobID) { $0.state = .failed(message) }
                }
                return
            }
            updateJob(jobID) { $0.state = .failed(String(localized: "Keine Rückmeldung von Paperless nach 15 Minuten.")) }
        } catch {
            Log.imports.error("\(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            updateJob(jobID) { $0.state = .failed(error.localizedDescription) }
        }
    }

    func clearFinishedImports() {
        imports.removeAll { !$0.isActive }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .image, .plainText, .rtf, .item]
        panel.prompt = String(localized: "Importieren")
        guard panel.runModal() == .OK else { return }
        Task { await upload(panel.urls) }
    }

    // MARK: - Teilen, Export, Ziehen

    /// Lädt das Original in den Temp-Ordner, damit Teilen, Export und Ziehen echte Dateien haben.
    func originalFile(_ doc: Document) async throws -> URL {
        guard let client else { throw ClientError.notConfigured }
        let dir = TempFiles.directory.appending(path: "doc-\(doc.id)", directoryHint: .isDirectory)
        let url = dir.appending(path: doc.exportFileName)
        if FileManager.default.fileExists(atPath: url.path()) { return url }
        let data = try await client.download(doc.id, original: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func originalFiles(_ docs: [Document]) async -> [URL] {
        var urls: [URL] = []
        for doc in docs {
            do {
                urls.append(try await originalFile(doc))
            } catch {
                toast = String(localized: "\(doc.title): \(error.localizedDescription)")
            }
        }
        return urls
    }

    func share() async {
        let urls = await originalFiles(actionTargets)
        guard !urls.isEmpty, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = NSRect(x: view.bounds.maxX - 330, y: view.bounds.maxY - 8, width: 30, height: 8)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func export() async {
        let docs = actionTargets
        guard !docs.isEmpty else { return }
        if docs.count == 1, let doc = docs.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = doc.exportFileName
            guard panel.runModal() == .OK, let target = panel.url else { return }
            guard let source = await originalFiles([doc]).first else { return }
            copy(source, to: target)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "\(docs.count) Dokumente exportieren")
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            for source in await originalFiles(docs) {
                copy(source, to: uniqueURL(folder.appending(path: source.lastPathComponent)))
            }
            toast = String(localized: "\(docs.count) Dokumente exportiert.")
        }
    }

    private func copy(_ source: URL, to target: URL) {
        do {
            if FileManager.default.fileExists(atPath: target.path()) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            toast = error.localizedDescription
        }
    }

    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path()) {
            candidate = url.deletingLastPathComponent().appending(path: "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }

    /// Stellt das Original beim Ziehen erst bereit, wenn es irgendwo abgelegt wird.
    func dragProvider(for doc: Document) -> NSItemProvider {
        let provider = NSItemProvider()
        let ext = (doc.exportFileName as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .pdf
        provider.suggestedName = (doc.exportFileName as NSString).deletingPathExtension
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await self.originalFile(doc)
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    // MARK: - Neue Dokumente

    /// Neue Dokumente vorne einsortieren, ohne das Raster neu zu laden.
    func insertNewDocuments(_ docs: [Document]) {
        guard !query.isFiltered, sort == .created || sort == .added else { return }
        let known = Set(documents.map(\.id))
        let fresh = docs.filter { !known.contains($0.id) }.sorted { $0.id > $1.id }
        guard !fresh.isEmpty else { return }
        withAnimation(.smooth) { documents.insert(contentsOf: fresh, at: 0) }
        totalCount += fresh.count
        Task { await store?.upsert(fresh, lastModified: nil) }
    }

    func noteNewDocuments(_ docs: [Document]) {
        recentNew = Array((docs.sorted { $0.id > $1.id } + recentNew).prefix(8))
    }

    func registerWindowOpener(_ action: @escaping () -> Void) {
        if openWindowAction == nil { openWindowAction = action }
    }

    /// Holt das Hauptfenster nach vorne, auch im Menüleisten-Betrieb ohne Dock-Symbol.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction?()
    }

    /// Öffnet ein Dokument auch dann, wenn es noch nicht im geladenen Raster steckt.
    func open(documentID id: Int) async {
        showMainWindow()
        if document(id) == nil {
            if let client, phase == .ready, let doc = try? await client.document(id) {
                documents.insert(doc, at: 0)
            } else if let store, let doc = await store.current().documents[id] {
                documents.insert(doc, at: 0)
            }
        }
        guard document(id) != nil else {
            toast = String(localized: "Dokument \(id) nicht gefunden.")
            return
        }
        openReader(id)
    }

    func handle(url: URL) {
        // ablage://document/123
        guard url.scheme == "ablage", url.host() == "document",
              let id = Int(url.lastPathComponent) else { return }
        Task { await open(documentID: id) }
    }

    // MARK: - Push aufs iPhone

    static let pushWorkflowName = "Ablage: Push bei neuem Dokument"

    func setupPush(server: URL, topic: String) async -> Bool {
        guard let client else { return false }
        do {
            try await client.upsertPushWorkflow(name: Self.pushWorkflowName, server: server, topic: topic)
            toast = String(localized: "Push-Workflow in Paperless eingerichtet.")
            return true
        } catch {
            toast = error.localizedDescription
            return false
        }
    }

    func disablePush() async {
        do {
            try await client?.setWorkflowEnabled(name: Self.pushWorkflowName, enabled: false)
            toast = String(localized: "Push-Workflow deaktiviert.")
        } catch {
            toast = error.localizedDescription
        }
    }

    // MARK: - Lookups

    func tag(_ id: Int) -> NamedItem? { tagsByID[id] }
    func correspondentName(_ id: Int?) -> String? { id.flatMap { correspondentsByID[$0]?.name } }
    func typeName(_ id: Int?) -> String? { id.flatMap { typesByID[$0]?.name } }
}

/// Vorschaubilder: Speicher-Cache mit Obergrenze, darunter die Kopie auf der Platte.
actor ThumbnailCache {
    private let memory: NSCache<NSNumber, NSImage> = {
        let cache = NSCache<NSNumber, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private var inFlight: [Int: Task<NSImage?, Never>] = [:]
    private var blocked = false
    private var store: LibraryStore?

    func attach(_ store: LibraryStore) { self.store = store }
    func setBlocked(_ value: Bool) { blocked = value }

    func image(for id: Int, client: PaperlessClient?) async -> NSImage? {
        if let image = memory.object(forKey: id as NSNumber) { return image }
        if let data = store?.thumbnail(id), let image = NSImage(data: data) {
            memory.setObject(image, forKey: id as NSNumber)
            return image
        }
        // Solange Pangolin eine Anmeldung verlangt, keine 401-Salven erzeugen: CrowdSec wertet
        // 4xx-Serien aus und sperrt sonst die eigene IP.
        guard !blocked, let client else { return nil }
        if let task = inFlight[id] { return await task.value }
        let store = self.store
        let task = Task { () -> NSImage? in
            do {
                let data = try await client.thumbnail(id)
                store?.storeThumbnail(data, for: id)
                return NSImage(data: data)
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
        if let image { memory.setObject(image, forKey: id as NSNumber) }
        return image
    }

    func clear() {
        memory.removeAllObjects()
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
