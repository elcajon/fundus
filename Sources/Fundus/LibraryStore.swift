import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Local copy of the library: metadata and text of all documents, thumbnails and previews
/// opened before. Basis for offline mode and Spotlight.
///
/// Lives per server under `~/Library/Caches/de.max-venz.ablage/<host>/`. It is a cache and may
/// be deleted at any time; the app then reloads everything.
actor LibraryStore {
    struct Snapshot: Codable {
        var documents: [Int: Document] = [:]
        var tags: [NamedItem] = []
        var correspondents: [NamedItem] = []
        var types: [NamedItem] = []
        var customFields: [CustomFieldDefinition]?
        /// Timestamp of the last successful sync (server time from `modified`).
        var lastModified: String?
        var lastFullSync: Date?
    }

    let root: URL
    private var snapshot = Snapshot()
    private var loaded = false

    /// How many opened previews stay available offline.
    private let previewLimit = 150
    /// Limit the text per document so the copy and the Spotlight index stay manageable.
    static let contentLimit = 50_000

    init(host: String, baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "de.max-venz.ablage")
        root = base.appending(path: host, directoryHint: .isDirectory)
        for sub in ["thumbs", "previews"] {
            try? FileManager.default.createDirectory(at: root.appending(path: sub), withIntermediateDirectories: true)
        }
    }

    private var snapshotURL: URL { root.appending(path: "library.json") }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: snapshotURL) else { return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            Log.sync.error("Lokale Bibliothek unlesbar, beginne neu: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            Log.sync.error("Lokale Bibliothek nicht gespeichert: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Library

    func current() -> Snapshot {
        ensureLoaded()
        return snapshot
    }

    var isEmpty: Bool {
        ensureLoaded()
        return snapshot.documents.isEmpty
    }

    func setMetadata(tags: [NamedItem], correspondents: [NamedItem], types: [NamedItem]) {
        ensureLoaded()
        snapshot.tags = tags
        snapshot.correspondents = correspondents
        snapshot.types = types
        save()
    }

    func setCustomFields(_ fields: [CustomFieldDefinition]) {
        ensureLoaded()
        snapshot.customFields = fields
        save()
    }

    /// Takes over changed documents. Returns the stored versions.
    @discardableResult
    func upsert(_ docs: [Document], lastModified: String?) -> [Document] {
        ensureLoaded()
        var stored: [Document] = []
        for var doc in docs {
            doc.searchHit = nil
            if let content = doc.content, content.count > Self.contentLimit {
                doc.content = String(content.prefix(Self.contentLimit))
            }
            // List responses truncate the text; don't overwrite a full text.
            if let old = snapshot.documents[doc.id], let oldContent = old.content,
               (doc.content?.count ?? 0) < oldContent.count, doc.modified == old.modified {
                doc.content = oldContent
            }
            if doc.customFields == nil, let old = snapshot.documents[doc.id] {
                doc.customFields = old.customFields
            }
            snapshot.documents[doc.id] = doc
            stored.append(doc)
        }
        if let lastModified, lastModified > (snapshot.lastModified ?? "") {
            snapshot.lastModified = lastModified
        }
        save()
        return stored
    }

    /// Removes documents that no longer exist on the server. Returns the removed IDs.
    func retainOnly(_ ids: Set<Int>) -> [Int] {
        ensureLoaded()
        let gone = snapshot.documents.keys.filter { !ids.contains($0) }
        for id in gone {
            snapshot.documents[id] = nil
            try? FileManager.default.removeItem(at: thumbURL(id))
            try? FileManager.default.removeItem(at: previewURL(id))
        }
        snapshot.lastFullSync = Date()
        save()
        return gone
    }

    func documents(matching query: DocumentQuery) -> [Document] {
        ensureLoaded()
        let inbox = Set(snapshot.tags.filter(\.isInboxTag).map(\.id))
        let correspondents = Dictionary(snapshot.correspondents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let types = Dictionary(snapshot.types.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let matches = snapshot.documents.values.filter { query.matches($0, inboxTags: inbox) }
        return query.sorted(Array(matches)) { field, id in
            id.flatMap { field == .correspondent ? correspondents[$0] : types[$0] }
        }
    }

    func clear() {
        snapshot = Snapshot()
        loaded = true
        try? FileManager.default.removeItem(at: root)
        for sub in ["thumbs", "previews"] {
            try? FileManager.default.createDirectory(at: root.appending(path: sub), withIntermediateDirectories: true)
        }
    }

    // MARK: Files

    nonisolated func thumbURL(_ id: Int) -> URL { root.appending(path: "thumbs/\(id)") }
    nonisolated func previewURL(_ id: Int) -> URL { root.appending(path: "previews/\(id)") }

    nonisolated func thumbnail(_ id: Int) -> Data? { try? Data(contentsOf: thumbURL(id)) }

    nonisolated func storeThumbnail(_ data: Data, for id: Int) {
        try? data.write(to: thumbURL(id), options: .atomic)
    }

    nonisolated func preview(_ id: Int) -> Data? {
        let url = previewURL(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Remember the access time so the oldest ones go first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path())
        return data
    }

    func storePreview(_ data: Data, for id: Int) {
        try? data.write(to: previewURL(id), options: .atomic)
        trimPreviews()
    }

    private func trimPreviews() {
        let dir = root.appending(path: "previews")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys),
              files.count > previewLimit else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - previewLimit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func diskUsage() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Reports documents to Spotlight. A hit opens Fundus via `ablage://document/<id>`.
enum SpotlightIndexer {
    static let domain = "de.max-venz.ablage.documents"
    static let enabledKey = "spotlightEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func identifier(_ id: Int) -> String { "document-\(id)" }

    static func documentID(from identifier: String) -> Int? {
        guard identifier.hasPrefix("document-") else { return nil }
        return Int(identifier.dropFirst("document-".count))
    }

    struct Names: Sendable {
        let tags: [Int: String]
        let correspondents: [Int: String]
        let types: [Int: String]
    }

    static func index(_ docs: [Document], names: Names, store: LibraryStore) async {
        guard isEnabled, !docs.isEmpty else { return }
        let items = docs.map { doc -> CSSearchableItem in
            let type = UTType(filenameExtension: (doc.originalFileName as NSString?)?.pathExtension ?? "") ?? .pdf
            let attributes = CSSearchableItemAttributeSet(contentType: type)
            attributes.title = doc.title
            attributes.displayName = doc.title
            let correspondent = doc.correspondent.flatMap { names.correspondents[$0] }
            attributes.contentDescription = [correspondent, doc.documentType.flatMap { names.types[$0] }]
                .compactMap { $0 }.joined(separator: " · ")
            attributes.textContent = doc.content
            attributes.keywords = doc.tags.compactMap { names.tags[$0] }
            attributes.contentCreationDate = doc.createdDate
            attributes.addedDate = doc.addedDate
            attributes.authorNames = correspondent.map { [$0] }
            attributes.thumbnailURL = FileManager.default.fileExists(atPath: store.thumbURL(doc.id).path())
                ? store.thumbURL(doc.id) : nil
            attributes.contentURL = URL(string: "ablage://document/\(doc.id)")
            let item = CSSearchableItem(uniqueIdentifier: identifier(doc.id), domainIdentifier: domain,
                                        attributeSet: attributes)
            item.expirationDate = .distantFuture
            return item
        }
        for chunk in stride(from: 0, to: items.count, by: 200).map({ Array(items[$0..<min($0 + 200, items.count)]) }) {
            do {
                try await CSSearchableIndex.default().indexSearchableItems(chunk)
            } catch {
                Log.sync.error("Spotlight-Index fehlgeschlagen: \(String(describing: error), privacy: .public)")
                return
            }
        }
        Log.sync.info("Spotlight: \(items.count) Dokumente gemeldet")
    }

    /// Number of reported documents, read directly from the Spotlight index.
    static func count() async -> Int? {
        await withCheckedContinuation { continuation in
            let context = CSSearchQueryContext()
            context.fetchAttributes = []
            let query = CSSearchQuery(queryString: #"title == "*""#, queryContext: context)
            var found = 0
            query.foundItemsHandler = { found += $0.count }
            query.completionHandler = { error in
                if let error { Log.sync.error("Spotlight-Abfrage fehlgeschlagen: \(String(describing: error), privacy: .public)") }
                continuation.resume(returning: error == nil ? found : nil)
            }
            query.start()
        }
    }

    static func remove(_ ids: [Int]) async {
        guard !ids.isEmpty else { return }
        try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map(identifier))
    }

    static func removeAll() async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }
}
