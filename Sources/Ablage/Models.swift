import Foundation

struct Page<T: Decodable>: Decodable {
    let count: Int
    let next: String?
    let results: [T]
}

struct Document: Codable, Identifiable, Hashable {
    let id: Int
    var title: String
    var correspondent: Int?
    var documentType: Int?
    var tags: [Int]
    var created: String?
    let added: String?
    var modified: String?
    var content: String?
    let pageCount: Int?
    let originalFileName: String?
    var searchHit: SearchHit?

    enum CodingKeys: String, CodingKey {
        case id, title, correspondent, tags, created, added, modified, content
        case documentType = "document_type"
        case pageCount = "page_count"
        case originalFileName = "original_file_name"
        case searchHit = "__search_hit__"
    }

    /// Paperless liefert je nach API-Version "2026-09-08" oder einen vollen ISO-Zeitstempel.
    var createdDate: Date? { created.flatMap(Document.day(from:)) }
    var addedDate: Date? { added.flatMap(Document.day(from:)) }

    static func day(from string: String) -> Date? {
        dayFormatter.date(from: String(string.prefix(10)))
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Dateiname für Export, Teilen und Ziehen, ohne Pfadtrenner.
    var exportFileName: String {
        let name = originalFileName ?? "\(title).pdf"
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

struct SearchHit: Codable, Hashable {
    let score: Double?
    let highlights: String?
}

struct NamedItem: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let documentCount: Int?
    let color: String?
    let textColor: String?
    let isInboxTag: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case documentCount = "document_count"
        case textColor = "text_color"
        case isInboxTag = "is_inbox_tag"
    }

    init(id: Int, name: String, documentCount: Int? = nil, color: String? = nil,
         textColor: String? = nil, isInboxTag: Bool = false) {
        self.id = id
        self.name = name
        self.documentCount = documentCount
        self.color = color
        self.textColor = textColor
        self.isInboxTag = isInboxTag
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        documentCount = try? c.decode(Int.self, forKey: .documentCount)
        // Bei alten API-Versionen ist color ein Index statt eines Hex-Strings.
        color = try? c.decode(String.self, forKey: .color)
        textColor = try? c.decode(String.self, forKey: .textColor)
        isInboxTag = (try? c.decode(Bool.self, forKey: .isInboxTag)) ?? false
    }
}

struct Profile: Decodable {
    let email: String?
    let firstName: String?
    let lastName: String?
    let authToken: String?

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case authToken = "auth_token"
    }

    var displayName: String {
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (email ?? "") : name
    }
}

/// Änderungen an einem Dokument. Leere Werte werden bewusst als `null` gesendet, damit sich
/// Korrespondent und Typ auch entfernen lassen.
struct DocumentUpdate: Encodable, Equatable {
    var title: String
    var created: Date
    var correspondent: Int?
    var documentType: Int?
    var tags: [Int]

    init(_ doc: Document) {
        title = doc.title
        created = doc.createdDate ?? Date()
        correspondent = doc.correspondent
        documentType = doc.documentType
        tags = doc.tags
    }

    enum CodingKeys: String, CodingKey {
        case title, created, correspondent, tags
        case documentType = "document_type"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(Document.dayFormatter.string(from: created), forKey: .created)
        try c.encode(correspondent, forKey: .correspondent)
        try c.encode(documentType, forKey: .documentType)
        try c.encode(tags, forKey: .tags)
    }
}

/// Status eines Paperless-Hintergrundjobs (API-Version 9).
struct TaskStatus: Decodable {
    enum State: String {
        case pending = "PENDING", started = "STARTED", success = "SUCCESS", failure = "FAILURE", revoked = "REVOKED"
    }

    let taskID: String
    let status: String
    let result: String?
    let relatedDocument: Int?

    enum CodingKeys: String, CodingKey {
        case status, result
        case taskID = "task_id"
        case relatedDocument = "related_document"
    }

    init(taskID: String, status: String, result: String?, relatedDocument: Int?) {
        self.taskID = taskID
        self.status = status
        self.result = result
        self.relatedDocument = relatedDocument
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(String.self, forKey: .taskID)
        status = try c.decode(String.self, forKey: .status)
        result = try? c.decode(String.self, forKey: .result)
        // Je nach Version eine Zahl oder ein String.
        if let int = try? c.decode(Int.self, forKey: .relatedDocument) {
            relatedDocument = int
        } else if let string = try? c.decode(String.self, forKey: .relatedDocument) {
            relatedDocument = Int(string)
        } else {
            relatedDocument = nil
        }
    }

    var state: State { State(rawValue: status.uppercased()) ?? .pending }
    var isFinished: Bool { [.success, .failure, .revoked].contains(state) }
}

// MARK: - Suche

enum SearchToken: Hashable, Identifiable, Codable {
    case inbox
    case tag(Int)
    case correspondent(Int)
    case documentType(Int)

    var id: Self { self }
}

enum DocumentSort: String, CaseIterable, Identifiable {
    case created
    case added

    var id: Self { self }
    var ordering: String { "-" + rawValue }
}

/// Alles, was die Dokumentliste bestimmt. Rein und ohne Netzwerk, damit es sich testen lässt.
struct DocumentQuery: Equatable {
    var text: String = ""
    var tokens: [SearchToken] = []
    var sort: DocumentSort = .created

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isFiltered: Bool { !trimmedText.isEmpty || !tokens.isEmpty }

    func queryItems(page: Int, pageSize: Int) -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "page_size", value: String(pageSize)),
            .init(name: "truncate_content", value: "true"),
        ]
        if trimmedText.isEmpty {
            items.append(.init(name: "ordering", value: sort.ordering))
        } else {
            // Volltextsuche über den Index von Paperless, sortiert nach Relevanz.
            items.append(.init(name: "query", value: trimmedText))
        }
        var tagIDs: [Int] = []
        var correspondentIDs: [Int] = []
        var typeIDs: [Int] = []
        for token in tokens {
            switch token {
            case .inbox: items.append(.init(name: "is_in_inbox", value: "true"))
            case let .tag(id): tagIDs.append(id)
            case let .correspondent(id): correspondentIDs.append(id)
            case let .documentType(id): typeIDs.append(id)
            }
        }
        if !tagIDs.isEmpty {
            items.append(.init(name: "tags__id__all", value: tagIDs.map(String.init).joined(separator: ",")))
        }
        if !correspondentIDs.isEmpty {
            items.append(.init(name: "correspondent__id__in", value: correspondentIDs.map(String.init).joined(separator: ",")))
        }
        if !typeIDs.isEmpty {
            items.append(.init(name: "document_type__id__in", value: typeIDs.map(String.init).joined(separator: ",")))
        }
        return items
    }

    /// Filtert lokal gespeicherte Dokumente, wenn der Server nicht erreichbar ist.
    func matches(_ doc: Document, inboxTags: Set<Int>) -> Bool {
        var correspondentIDs: [Int] = []
        var typeIDs: [Int] = []
        for token in tokens {
            switch token {
            case .inbox: if inboxTags.isDisjoint(with: doc.tags) { return false }
            case let .tag(id): if !doc.tags.contains(id) { return false }
            case let .correspondent(id): correspondentIDs.append(id)
            case let .documentType(id): typeIDs.append(id)
            }
        }
        if !correspondentIDs.isEmpty, !correspondentIDs.contains(doc.correspondent ?? -1) { return false }
        if !typeIDs.isEmpty, !typeIDs.contains(doc.documentType ?? -1) { return false }
        let words = trimmedText.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = doc.title + " " + (doc.content ?? "")
        return words.allSatisfy { haystack.localizedStandardContains($0) }
    }
}

/// Wandelt Eingaben wie `#Steuer`, `@Obi` oder `typ:Rechnung` in Such-Tokens um.
/// Namen mit Leerzeichen gehen in Anführungszeichen: `#"Haus und Garten"`.
struct SearchParser {
    let tags: [NamedItem]
    let correspondents: [NamedItem]
    let types: [NamedItem]

    static let typePrefix = "typ:"

    enum Kind { case tag, correspondent, type }

    /// Erkennt ein Präfix am Anfang eines Worts.
    static func kind(of word: Substring) -> (Kind, Substring)? {
        if word.hasPrefix("#") { return (.tag, word.dropFirst()) }
        if word.hasPrefix("@") { return (.correspondent, word.dropFirst()) }
        if word.lowercased().hasPrefix(typePrefix) { return (.type, word.dropFirst(typePrefix.count)) }
        return nil
    }

    func items(for kind: Kind) -> [NamedItem] {
        switch kind {
        case .tag: tags
        case .correspondent: correspondents
        case .type: types
        }
    }

    func token(_ kind: Kind, id: Int) -> SearchToken {
        switch kind {
        case .tag: .tag(id)
        case .correspondent: .correspondent(id)
        case .type: .documentType(id)
        }
    }

    /// Exakter Treffer (ohne Groß-/Kleinschreibung), sonst ein eindeutiger Präfix-Treffer.
    func resolve(_ name: String, kind: Kind) -> NamedItem? {
        let candidates = items(for: kind)
        if let exact = candidates.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return exact
        }
        let prefixed = candidates.filter { $0.name.range(of: name, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Nur abgeschlossene Tokens (gefolgt von Leerzeichen oder `final`) werden umgewandelt,
    /// damit beim Tippen nichts vorschnell verschwindet.
    func parse(_ text: String, final: Bool) -> (text: String, tokens: [SearchToken]) {
        var tokens: [SearchToken] = []
        var rest: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            // Ein Wort, ggf. mit Anführungszeichen nach dem Präfix.
            var end = index
            var inQuotes = false
            while end < text.endIndex {
                let ch = text[end]
                if ch == "\"" { inQuotes.toggle() }
                if ch.isWhitespace && !inQuotes { break }
                end = text.index(after: end)
            }
            let word = text[index..<end]
            let complete = end < text.endIndex || final
            if complete, let (kind, rawName) = Self.kind(of: word) {
                let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !name.isEmpty, let item = resolve(name, kind: kind) {
                    let token = token(kind, id: item.id)
                    if !tokens.contains(token) { tokens.append(token) }
                    index = end
                    continue
                }
            }
            rest.append(String(word))
            index = end
        }
        var remaining = rest.joined(separator: " ")
        // Ein Leerzeichen am Ende erhalten, damit man nach einem Wort weitertippen kann.
        if !final, text.last?.isWhitespace == true, !remaining.isEmpty { remaining += " " }
        return (remaining, tokens)
    }

    /// Vorschläge für ein gerade getipptes Präfix-Wort am Ende des Textes.
    func suggestions(for text: String, limit: Int = 8) -> [SearchToken] {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last,
              let (kind, rawName) = Self.kind(of: last) else { return [] }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let matches = items(for: kind).filter {
            name.isEmpty || $0.name.localizedStandardContains(name)
        }
        return matches.prefix(limit).map { token(kind, id: $0.id) }
    }

    /// Entfernt das angefangene Präfix-Wort am Ende, nachdem ein Vorschlag übernommen wurde.
    static func removingTrailingPrefixWord(_ text: String) -> String {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false)
        if let last = parts.last, kind(of: last) != nil { parts.removeLast() }
        return parts.joined(separator: " ")
    }
}

/// Wandelt die Treffer-Markierung von Paperless (`<span class="match">…</span>`) in Abschnitte um.
enum HighlightParser {
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    static func segments(_ html: String) -> [Segment] {
        var result: [Segment] = []
        var rest = Substring(html)
        while let open = rest.range(of: "<span class=\"match\">") {
            if open.lowerBound > rest.startIndex {
                result.append(Segment(text: String(rest[..<open.lowerBound]), isMatch: false))
            }
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "</span>") else { break }
            result.append(Segment(text: String(rest[..<close.lowerBound]), isMatch: true))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { result.append(Segment(text: String(rest), isMatch: false)) }
        return result
    }
}
