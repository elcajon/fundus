import Foundation

struct Page<T: Decodable>: Decodable {
    let count: Int
    let next: String?
    let results: [T]
}

struct Document: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let correspondent: Int?
    let documentType: Int?
    let tags: [Int]
    let created: String?
    let added: String?
    let content: String?
    let pageCount: Int?
    let originalFileName: String?
    let searchHit: SearchHit?

    enum CodingKeys: String, CodingKey {
        case id, title, correspondent, tags, created, added, content
        case documentType = "document_type"
        case pageCount = "page_count"
        case originalFileName = "original_file_name"
        case searchHit = "__search_hit__"
    }

    /// Paperless liefert je nach API-Version "2026-09-08" oder einen vollen ISO-Zeitstempel.
    var createdDate: Date? {
        guard let created else { return nil }
        let day = String(created.prefix(10))
        return Document.dayFormatter.date(from: day)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct SearchHit: Decodable, Hashable {
    let score: Double?
    let highlights: String?
}

struct NamedItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let documentCount: Int?
    let color: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case documentCount = "document_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        documentCount = try? c.decode(Int.self, forKey: .documentCount)
        // Bei alten API-Versionen ist color ein Index statt eines Hex-Strings.
        color = try? c.decode(String.self, forKey: .color)
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

enum SidebarItem: Hashable {
    case all
    case inbox
    case tag(Int)
    case correspondent(Int)
    case documentType(Int)
}
