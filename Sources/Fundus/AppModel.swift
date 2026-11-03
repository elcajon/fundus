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
        /// Server unreachable, the app shows the local copy.
        case offline(String)
        case failed(String)
    }

    var phase: Phase = .unconfigured
    var showLogin = false {
        didSet { if showLogin { Task { await thumbnails.setBlocked(true) } } }
    }
    var loginHint = String(localized: "Melde dich an. Das Fenster schließt sich, sobald Paperless erreichbar ist.")

    var serverURL: URL?
    var profile: Profile?

    var tags: [NamedItem] = []
    var correspondents: [NamedItem] = []
    var documentTypes: [NamedItem] = []
    private var tagsByID: [Int: NamedItem] = [:]
    private var correspondentsByID: [Int: NamedItem] = [:]
    private var typesByID: [Int: NamedItem] = [:]
    var customFields: [CustomFieldDefinition] = []
    private var customFieldsByID: [Int: CustomFieldDefinition] = [:]

    // MARK: View

    var selectedIDs: Set<Int> = []
    /// The last clicked document: target for reading mode, arrow keys and range selection.
    var focusedID: Int?
    var readerID: Int?
    var showInspector = false
    var searchFocusRequest = 0
    var zoom: Double = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1 {
        didSet { defaults.set(zoom, forKey: "zoom") }
    }
    var layout: LibraryLayout = LibraryLayout(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .grid {
        didSet { defaults.set(layout.rawValue, forKey: "layout") }
    }
    /// The sort without search text. The list reloads through `query`.
    var sort: DocumentSort = DocumentSort(SortField(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .created,
                                          ascending: UserDefaults.standard.object(forKey: "sortAscending") as? Bool) {
        didSet {
            defaults.set(sort.field.rawValue, forKey: "sort")
            defaults.set(sort.ascending, forKey: "sortAscending")
        }
    }
    /// The sort while searching text. `nil` keeps Paperless' relevance order, so ↩ in the search
    /// field opens the best hit. It is reset when the search is cleared.
    var searchSort: DocumentSort?
    /// Sections of the list view; the grid is never grouped.
    var grouping: DocumentGrouping = DocumentGrouping(rawValue: UserDefaults.standard.string(forKey: "grouping") ?? "") ?? .none {
        didSet { defaults.set(grouping.rawValue, forKey: "grouping") }
    }

    /// Free text in the search field. Completed `#tag`/`@name`/`typ:x` words become tokens.
    var search = "" {
        didSet {
            guard !isNormalizingSearch, search != oldValue else { return }
            normalizeSearch(final: false)
            if !isSearchingText { searchSort = nil }
        }
    }
    var searchTokens: [SearchToken] = []
    @ObservationIgnored private var isNormalizingSearch = false

    private var isSearchingText: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var query: DocumentQuery {
        DocumentQuery(text: search, tokens: searchTokens, sort: isSearchingText ? searchSort : sort,
                      grouping: layout == .list ? grouping : .none)
    }

    /// The sort shown in the list's column headers and the View menu; `nil` is relevance.
    var currentSort: DocumentSort? {
        get { query.effectiveSort }
        set {
            if isSearchingText {
                searchSort = newValue
            } else if let newValue {
                sort = newValue
            }
        }
    }

    /// Correspondent and type names for sorting and section headers.
    func name(_ field: SortField, _ id: Int?) -> String? {
        field == .correspondent ? correspondentName(id) : typeName(id)
    }

    var documents: [Document] = []
    var totalCount = 0
    var isLoadingPage = false
    var toast: String?
    private var nextPage: Int? = 1
    private var loadGeneration = 0

    // MARK: Background

    var imports: [ImportJob] = []
    var activeImportCount: Int { imports.filter(\.isActive).count }
    var showImports = false
    /// Newest documents reported by the watcher, for the menu bar menu.
    var recentNew: [Document] = []
    var isSyncing = false
    var lastSync: Date?
    /// Documents this app imported itself: don't report them as “new” as well.
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

    // MARK: - Settings

    // Read keychain values only once: otherwise every access can trigger a password prompt.
    @ObservationIgnored private var secretCache: [String: String] = [:]

    private func secret(_ account: String) -> String {
        if let cached = secretCache[account] { return cached }
        let value = Keychain.token(for: account) ?? ""
        secretCache[account] = value
        return value
    }

    /// Reads the secrets ahead of time, off the main thread. That way a keychain prompt doesn't
    /// block the window, and later accesses come from the cache.
    private func preloadSecrets() async {
        guard let serverURL else { return }
        let accounts = [serverURL.absoluteString].filter { secretCache[$0] == nil }
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

    // MARK: - Connection

    func connect() async {
        guard let serverURL else { phase = .unconfigured; return }
        phase = .connecting
        await preloadSecrets()
        let client = PaperlessClient(baseURL: serverURL, token: apiToken)
        self.client = client
        let store = self.store?.root.lastPathComponent == client.host ? self.store! : LibraryStore(host: client.host)
        self.store = store
        await thumbnails.attach(store)
        await CookieBridge.syncFromWebView(host: client.host)

        do {
            try await finishConnecting(client)
        } catch ClientError.pangolinLoginRequired {
            loginHint = String(localized: "Der Zugang verlangt eine Anmeldung. Das Fenster schließt sich, sobald Paperless erreichbar ist.")
            showLogin = true
            await showOffline(String(localized: "Anmeldung erforderlich."))
        } catch ClientError.paperlessUnauthorized {
            loginHint = String(localized: "Jetzt noch bei Paperless anmelden.")
            showLogin = true
            await showOffline(String(localized: "Paperless hat die Anmeldung abgelehnt."))
        } catch {
            Log.app.error("Verbindung fehlgeschlagen: \(String(describing: error), privacy: .public)")
            await showOffline(error.localizedDescription)
        }
    }

    /// Shows the local copy if there is one, otherwise the error.
    private func showOffline(_ reason: String) async {
        guard let store, !(await store.isEmpty) else {
            phase = .failed(reason)
            return
        }
        let snapshot = await store.current()
        applyMetadata(tags: snapshot.tags, correspondents: snapshot.correspondents, types: snapshot.types)
        applyCustomFields(snapshot.customFields ?? [])
        phase = .offline(reason)
        await reload()
    }

    private func finishConnecting(_ client: PaperlessClient) async throws {
        let profile = try await client.profile()
        self.profile = profile
        // After the SSO login Paperless knows us by session cookie. If the user already has an
        // API token, we adopt it; then uploads work too, without the CSRF dance.
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

    /// Called by the login web view for every finished page load on the Paperless host.
    func loginWebViewLanded() async {
        guard let client else { return }
        await CookieBridge.syncFromWebView(host: client.host)
        do {
            try await finishConnecting(client)
        } catch ClientError.paperlessUnauthorized {
            loginHint = String(localized: "Jetzt noch bei Paperless anmelden.")
        } catch {
            // Still in the middle of the login flow, just keep waiting.
        }
    }

    /// Sign-in with user name and password: fetches the API token from Paperless.
    func signIn(username: String, password: String) async -> Bool {
        guard let client else { return false }
        do {
            apiToken = try await client.obtainToken(username: username, password: password)
            client.token = apiToken
            await connect()
            return true
        } catch {
            Log.app.error("Anmeldung fehlgeschlagen: \(String(describing: error), privacy: .public)")
            toast = String(localized: "Anmeldung fehlgeschlagen: \(error.localizedDescription)")
            return false
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

    // MARK: - Data

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
        // Separate request: without permission for fields, tags should still work.
        do {
            let fields = try await client.customFields()
            applyCustomFields(fields)
            await store?.setCustomFields(fields)
        } catch {
            Log.network.error("Benutzerdefinierte Felder nicht geladen: \(String(describing: error), privacy: .public)")
        }
    }

    private func applyCustomFields(_ fields: [CustomFieldDefinition]) {
        customFields = fields.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        customFieldsByID = Dictionary(fields.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func customField(_ id: Int) -> CustomFieldDefinition? { customFieldsByID[id] }

    /// Reloads a document in full, e.g. when the list did not include fields.
    @discardableResult
    func refreshDocument(_ id: Int) async -> Document? {
        guard let client, phase == .ready, let fresh = try? await client.document(id) else { return nil }
        var doc = fresh
        doc.searchHit = document(id)?.searchHit
        if let index = documents.firstIndex(where: { $0.id == id }) { documents[index] = doc }
        await store?.upsert([doc], lastModified: nil)
        return doc
    }

    /// Paperless workflows (“document updated”) can still change fields, tags or assignments
    /// after saving. Reload shortly afterwards so the view is right.
    private func checkWorkflowChanges(after saved: Document) async {
        try? await Task.sleep(for: .seconds(2))
        guard let fresh = await refreshDocument(saved.id), fresh.modified != saved.modified else { return }
        if DocumentUpdate(fresh) != DocumentUpdate(saved) {
            Log.app.info("Dokument \(saved.id) wurde nach dem Sichern von Paperless geändert")
            toast = String(localized: "Ein Paperless-Workflow hat „\(fresh.title)“ nach dem Sichern geändert.")
        }
    }

    /// Titles of linked documents, from the grid or the local copy.
    func titles(for ids: [Int]) async -> [Int: String] {
        var result: [Int: String] = [:]
        let stored = await store?.current().documents ?? [:]
        for id in ids {
            result[id] = document(id)?.title ?? stored[id]?.title
        }
        return result
    }

    /// Quick Search: local copy with the same filters as the search field (#tag, @sender, typ:).
    /// Matches in the title come first.
    func quickSearch(_ input: String, limit: Int = QuickSearchController.maxRows * 3) async -> [Document] {
        guard let store else { return [] }
        let (text, tokens) = parser.parse(input, final: true)
        let found = await store.documents(matching: DocumentQuery(text: text, tokens: tokens))
        let words = text.lowercased().split(separator: " ")
        let inTitle = found.filter { doc in
            let title = doc.title.lowercased()
            return words.allSatisfy { title.contains($0) }
        }
        let ids = Set(inTitle.map(\.id))
        return Array((inTitle + found.filter { !ids.contains($0.id) }).prefix(limit))
    }

    /// Search documents to link (local copy, so typing doesn't cause requests).
    func linkCandidates(matching text: String, excluding: Set<Int>) async -> [Document] {
        guard let store, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let found = await store.documents(matching: DocumentQuery(text: text))
        return Array(found.filter { !excluding.contains($0.id) }.prefix(20))
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
        let reading = document(readerID)
        loadGeneration += 1
        nextPage = 1
        documents = []
        totalCount = 0
        isLoadingPage = false
        await loadMore()
        // The document being read stays, even if it isn't on the first page.
        if let reading, document(reading.id) == nil { documents.insert(reading, at: 0) }
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
            let query = query
            documents = query.arranged(documents + result.results.filter { !known.contains($0.id) }, names: name)
            totalCount = result.count
            nextPage = result.next == nil ? nil : page + 1
        } catch ClientError.pangolinLoginRequired {
            guard generation == loadGeneration else { return }
            nextPage = page
            loginHint = String(localized: "Die Sitzung ist abgelaufen. Bitte neu anmelden.")
            showLogin = true
        } catch {
            guard generation == loadGeneration else { return }
            if (error as? URLError)?.code == .cancelled { return }
            if error is URLError {
                // Network gone: switch to the local copy.
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

    // MARK: - Sync (offline copy and Spotlight)

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
            // The first time (or after changes to the index format) report everything, otherwise only changes.
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

    /// Loads missing thumbnails one after another, so the offline grid and Spotlight have them.
    /// Stops as soon as Pangolin asks for a sign-in (no volleys of 401s).
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

    // MARK: - Search

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

    // MARK: - Selection

    func document(_ id: Int?) -> Document? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    /// Click on a document, with ⌘ to add and ⇧ for ranges.
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

    /// What share, export & co. act on: in reading mode the open document, otherwise the selection.
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

    // MARK: - Editing

    /// Saves changes and replaces the document in the list and the local copy.
    @discardableResult
    func save(_ id: Int, _ update: DocumentUpdate) async -> Bool {
        guard let client else { return false }
        do {
            var saved = try await client.update(id, update)
            if let old = document(id) {
                // The response contains the full text; the grid only needs the existing one.
                saved.searchHit = old.searchHit
            }
            replace(saved)
            await store?.upsert([saved], lastModified: nil)
            if let store { await SpotlightIndexer.index([saved], names: spotlightNames, store: store) }
            Task { await checkWorkflowChanges(after: saved) }
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
        // If it no longer matches the filter (e.g. inbox done), it drops out of the list.
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

    /// Removes the inbox tags and jumps to the next document.
    func markDone(_ id: Int, with update: DocumentUpdate? = nil) async {
        guard let doc = document(id) else { return }
        var change = update ?? DocumentUpdate(doc)
        change.tags.removeAll { inboxTagIDs.contains($0) }
        let stillListed = !searchTokens.contains(.inbox)
        if await save(id, change), stillListed {
            step(1)
        }
    }

    // MARK: - Imports

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
        // Don't re-import our own files (dragged out of the window).
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
            toast = String(localized: "\(failed) von \(files.count) Importen fehlgeschlagen. Details unter Fundus → Importe.")
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
            // Wait for processing: OCR can take a while, we give up after 15 minutes.
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

    // MARK: - Share, export, drag

    /// Downloads the original into the temp folder so share, export and drag have real files.
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

    /// Provides the original while dragging only once it is dropped somewhere.
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

    // MARK: - New documents

    /// Insert new documents at the front without reloading the grid.
    func insertNewDocuments(_ docs: [Document]) {
        // Only where new documents belong at the very top: newest first, without groups.
        guard !query.isFiltered, query.grouping == .none, let sort = query.effectiveSort,
              sort.field == .created || sort.field == .added, !sort.ascending else { return }
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

    /// Brings the main window to the front, also in menu bar mode without a Dock icon.
    func showMainWindow() {
        AppSettings.showInDock()
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction?()
    }

    /// Opens a document even if it isn't in the loaded grid yet.
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
        // ablage://document/123 or fundus://document/123
        guard url.scheme == "ablage" || url.scheme == "fundus", url.host() == "document",
              let id = Int(url.lastPathComponent) else { return }
        Task { await open(documentID: id) }
    }

    // MARK: - Lookups

    func tag(_ id: Int) -> NamedItem? { tagsByID[id] }
    func correspondentName(_ id: Int?) -> String? { id.flatMap { correspondentsByID[$0]?.name } }
    func typeName(_ id: Int?) -> String? { id.flatMap { typesByID[$0]?.name } }
}

/// Thumbnails: memory cache with an upper limit, backed by the copy on disk.
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
        // While Pangolin asks for a sign-in, don't cause volleys of 401s: CrowdSec evaluates
        // series of 4xx responses and otherwise blocks our own IP.
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
