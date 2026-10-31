import Foundation

struct Page<T: Decodable>: Decodable {
    let count: Int
    let next: String?
    let results: [T]
}

/// Depending on the Paperless version, `/api/tasks/` is a plain list or paginated.
struct TaskList: Decodable {
    let tasks: [TaskStatus]

    init(from decoder: Decoder) throws {
        if let list = try? [TaskStatus](from: decoder) {
            tasks = list
        } else {
            tasks = try Page<TaskStatus>(from: decoder).results
        }
    }
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
    /// `nil` if the response didn't include the fields (e.g. lists with `fields=`).
    var customFields: [CustomFieldInstance]?

    enum CodingKeys: String, CodingKey {
        case id, title, correspondent, tags, created, added, modified, content
        case customFields = "custom_fields"
        case documentType = "document_type"
        case pageCount = "page_count"
        case originalFileName = "original_file_name"
        case searchHit = "__search_hit__"
    }

    /// Depending on the API version, Paperless returns "2026-09-08" or a full ISO timestamp.
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

    /// File name for export, share and drag, without path separators.
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
        // In old API versions color is an index instead of a hex string.
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

// MARK: - Custom fields

/// Value of a custom field, as Paperless returns it in JSON.
enum FieldValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case ids([Int])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([Int].self) { self = .ids(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .int(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .ids(v): try c.encode(v)
        }
    }

    var isNull: Bool { self == .null }

    var string: String? {
        switch self {
        case let .string(v): v
        case let .int(v): String(v)
        case let .double(v): String(v)
        default: nil
        }
    }
}

struct CustomFieldInstance: Codable, Hashable {
    var field: Int
    var value: FieldValue
}

struct CustomFieldDefinition: Codable, Identifiable, Hashable {
    enum Kind: String {
        case string, url, date, boolean, integer, float, monetary, documentlink, select, longtext
    }

    struct Option: Codable, Hashable {
        let id: FieldValue
        let label: String
    }

    let id: Int
    let name: String
    let dataType: String
    let options: [Option]
    let defaultCurrency: String?

    var kind: Kind? { Kind(rawValue: dataType) }

    enum CodingKeys: String, CodingKey {
        case id, name
        case dataType = "data_type"
        case extraData = "extra_data"
    }

    private struct Extra: Codable {
        var selectOptions: [Option]?
        var defaultCurrency: String?

        enum CodingKeys: String, CodingKey {
            case selectOptions = "select_options"
            case defaultCurrency = "default_currency"
        }

        init(selectOptions: [Option]?, defaultCurrency: String?) {
            self.selectOptions = selectOptions
            self.defaultCurrency = defaultCurrency
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultCurrency = try? c.decodeIfPresent(String.self, forKey: .defaultCurrency)
            if let options = try? c.decodeIfPresent([Option].self, forKey: .selectOptions) {
                selectOptions = options
            } else if let labels = try? c.decodeIfPresent([String?].self, forKey: .selectOptions) {
                // Before Paperless 2.14: a list of names, the value is the index.
                selectOptions = labels.enumerated().map { Option(id: .int($0.offset), label: $0.element ?? "") }
            }
        }
    }

    init(id: Int, name: String, kind: Kind, options: [Option] = [], defaultCurrency: String? = nil) {
        self.id = id
        self.name = name
        dataType = kind.rawValue
        self.options = options
        self.defaultCurrency = defaultCurrency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        dataType = try c.decode(String.self, forKey: .dataType)
        let extra = try? c.decodeIfPresent(Extra.self, forKey: .extraData)
        options = extra?.selectOptions ?? []
        defaultCurrency = extra?.defaultCurrency.flatMap { $0.isEmpty ? nil : $0 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(dataType, forKey: .dataType)
        try c.encode(Extra(selectOptions: options, defaultCurrency: defaultCurrency), forKey: .extraData)
    }

    func label(for option: FieldValue) -> String? {
        options.first { $0.id == option }?.label
    }
}

/// Paperless stores amounts as "EUR12.50" (older values also as a plain number).
enum Monetary {
    static func parse(_ value: FieldValue) -> (currency: String?, amount: Decimal?) {
        switch value {
        case let .int(v): return (nil, Decimal(v))
        case let .double(v): return (nil, Decimal(string: String(v)))
        case let .string(text):
            let letters = text.prefix { $0.isLetter }
            let currency = letters.count == 3 ? String(letters) : nil
            let number = text.dropFirst(letters.count)
            return (currency, number.isEmpty ? nil : Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")))
        default: return (nil, nil)
        }
    }

    static func value(currency: String, amount: Decimal?) -> FieldValue {
        guard let amount else { return .null }
        var rounded = Decimal()
        var input = amount
        NSDecimalRound(&rounded, &input, 2, .plain)
        let number = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                            NSDecimalNumber(decimal: rounded).doubleValue)
        return .string(currency.uppercased() + number)
    }
}

/// Changes to a document. Empty values are deliberately sent as `null` so that
/// correspondent and type can be removed too.
struct DocumentUpdate: Encodable, Equatable {
    var title: String
    var created: Date
    var correspondent: Int?
    var documentType: Int?
    var tags: [Int]
    /// `nil` as long as the document's fields aren't known: then don't change them.
    var customFields: [CustomFieldInstance]?
    private let originalCustomFields: [CustomFieldInstance]?

    init(_ doc: Document) {
        title = doc.title
        created = doc.createdDate ?? Date()
        correspondent = doc.correspondent
        documentType = doc.documentType
        tags = doc.tags
        customFields = doc.customFields
        originalCustomFields = doc.customFields
    }

    enum CodingKeys: String, CodingKey {
        case title, created, correspondent, tags
        case documentType = "document_type"
        case customFields = "custom_fields"
    }

    /// Compares only the editable values, not the original state.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.created == rhs.created && lhs.correspondent == rhs.correspondent
            && lhs.documentType == rhs.documentType && lhs.tags == rhs.tags && lhs.customFields == rhs.customFields
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(Document.dayFormatter.string(from: created), forKey: .created)
        try c.encode(correspondent, forKey: .correspondent)
        try c.encode(documentType, forKey: .documentType)
        try c.encode(tags, forKey: .tags)
        // Paperless replaces the whole list; only send it if something changed.
        if let customFields, originalCustomFields != nil, customFields != originalCustomFields {
            try c.encode(customFields, forKey: .customFields)
        }
    }
}

/// Status of a Paperless background task (API version 9).
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
        // A number or a string, depending on the version.
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

// MARK: - Search

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

/// Everything that determines the document list. Pure and without networking, so it can be tested.
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
            // Full-text search over Paperless' index, sorted by relevance.
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

    /// Filters locally stored documents when the server is unreachable.
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

/// Turns input like `#Steuer`, `@Obi` or `typ:Rechnung` into search tokens.
/// Names with spaces go in quotes: `#"Haus und Garten"`.
struct SearchParser {
    let tags: [NamedItem]
    let correspondents: [NamedItem]
    let types: [NamedItem]

    static let typePrefix = "typ:"

    enum Kind { case tag, correspondent, type }

    /// Detects a prefix at the start of a word.
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

    /// Exact match (case-insensitive), otherwise a unique prefix match.
    func resolve(_ name: String, kind: Kind) -> NamedItem? {
        let candidates = items(for: kind)
        if let exact = candidates.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return exact
        }
        let prefixed = candidates.filter { $0.name.range(of: name, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// Only completed tokens (followed by a space or `final`) are converted,
    /// so nothing disappears prematurely while typing.
    func parse(_ text: String, final: Bool) -> (text: String, tokens: [SearchToken]) {
        var tokens: [SearchToken] = []
        var rest: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            // One word, possibly with quotes after the prefix.
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
        // Keep a trailing space so you can keep typing after a word.
        if !final, text.last?.isWhitespace == true, !remaining.isEmpty { remaining += " " }
        return (remaining, tokens)
    }

    /// Suggestions for a prefix word currently being typed at the end of the text.
    func suggestions(for text: String, limit: Int = 8) -> [SearchToken] {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last,
              let (kind, rawName) = Self.kind(of: last) else { return [] }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let matches = items(for: kind).filter {
            name.isEmpty || $0.name.localizedStandardContains(name)
        }
        return matches.prefix(limit).map { token(kind, id: $0.id) }
    }

    /// Removes the started prefix word at the end after a suggestion was accepted.
    static func removingTrailingPrefixWord(_ text: String) -> String {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false)
        if let last = parts.last, kind(of: last) != nil { parts.removeLast() }
        return parts.joined(separator: " ")
    }
}

/// Turns Paperless' match highlighting (`<span class="match">…</span>`) into segments.
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
