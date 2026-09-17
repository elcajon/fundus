import Foundation
import Testing
@testable import Fundus

@Suite("Paperless-Antworten lesen")
struct DecodingTests {
    @Test func documentV9() throws {
        let json = """
        {"id": 7, "title": "Rechnung", "correspondent": 3, "document_type": null, "tags": [1, 2],
         "created": "2026-09-12", "added": "2026-09-13T08:00:00+02:00", "modified": "2026-09-13T09:00:00+02:00",
         "content": "Text", "page_count": 2, "original_file_name": "scan.pdf",
         "__search_hit__": {"score": 0.8, "highlights": "a <span class=\\"match\\">b</span>", "rank": 1}}
        """
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        #expect(doc.id == 7)
        #expect(doc.documentType == nil)
        #expect(doc.tags == [1, 2])
        #expect(doc.pageCount == 2)
        #expect(doc.searchHit?.highlights?.contains("match") == true)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: try #require(doc.createdDate))
        #expect(components.year == 2026 && components.month == 9 && components.day == 12)
    }

    @Test("Ältere Versionen liefern created als Zeitstempel")
    func createdAsTimestamp() throws {
        let json = #"{"id": 1, "title": "x", "tags": [], "created": "2024-06-27T00:00:00+02:00"}"#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        #expect(doc.createdDate != nil)
    }

    @Test func tagWithHexColor() throws {
        let json = ##"{"id": 1, "name": "Steuer", "color": "#a6cee3", "text_color": "#000000", "is_inbox_tag": true, "document_count": 4}"##
        let tag = try JSONDecoder().decode(NamedItem.self, from: Data(json.utf8))
        #expect(tag.color == "#a6cee3")
        #expect(tag.isInboxTag)
        #expect(tag.documentCount == 4)
    }

    @Test("Alte API: color ist eine Zahl")
    func tagWithIndexColor() throws {
        let json = #"{"id": 1, "name": "Alt", "color": 3}"#
        let tag = try JSONDecoder().decode(NamedItem.self, from: Data(json.utf8))
        #expect(tag.color == nil)
        #expect(!tag.isInboxTag)
    }

    @Test(arguments: [#""related_document": 12"#, #""related_document": "12""#])
    func taskStatus(related: String) throws {
        let json = #"{"task_id": "abc", "status": "SUCCESS", "result": "ok", \#(related)}"#
        let task = try JSONDecoder().decode(TaskStatus.self, from: Data(json.utf8))
        #expect(task.state == .success)
        #expect(task.isFinished)
        #expect(task.relatedDocument == 12)
    }

    @Test(arguments: [
        #"[{"task_id": "abc", "status": "SUCCESS", "related_document": 5}]"#,
        #"{"count": 1, "next": null, "results": [{"task_id": "abc", "status": "SUCCESS", "related_document": 5}]}"#,
    ])
    func taskListShapes(json: String) throws {
        let list = try JSONDecoder().decode(TaskList.self, from: Data(json.utf8))
        #expect(list.tasks.first?.relatedDocument == 5)
    }

    @Test func pendingTask() throws {
        let json = #"{"task_id": "abc", "status": "STARTED", "related_document": null}"#
        let task = try JSONDecoder().decode(TaskStatus.self, from: Data(json.utf8))
        #expect(!task.isFinished)
        #expect(task.relatedDocument == nil)
    }

    @Test("Update sendet leere Werte als null")
    func updateEncodesNulls() throws {
        let doc = Document(id: 1, title: "T", correspondent: nil, documentType: nil, tags: [4], created: "2026-01-05",
                           added: nil, modified: nil, content: nil, pageCount: nil, originalFileName: nil, searchHit: nil)
        let data = try JSONEncoder().encode(DocumentUpdate(doc))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["created"] as? String == "2026-01-05")
        #expect(object["correspondent"] is NSNull)
        #expect(object["document_type"] is NSNull)
        #expect(object["tags"] as? [Int] == [4])
    }

    @Test func exportFileNameIsSafe() {
        let doc = Document(id: 1, title: "A/B", correspondent: nil, documentType: nil, tags: [], created: nil,
                           added: nil, modified: nil, content: nil, pageCount: nil, originalFileName: "x/y:z.pdf", searchHit: nil)
        #expect(doc.exportFileName == "x-y-z.pdf")
    }
}

@Suite("Suchfilter")
struct SearchTests {
    let parser = SearchParser(
        tags: [NamedItem(id: 1, name: "Steuer"), NamedItem(id: 2, name: "Haus und Garten"), NamedItem(id: 3, name: "Steuerberater")],
        correspondents: [NamedItem(id: 10, name: "Obi"), NamedItem(id: 11, name: "Amazon")],
        types: [NamedItem(id: 20, name: "Rechnung")]
    )

    @Test("Abgeschlossene Tokens werden erkannt")
    func completedTokens() {
        let result = parser.parse("#steuer @obi typ:rechnung hammer", final: false)
        #expect(result.tokens == [.tag(1), .correspondent(10), .documentType(20)])
        #expect(result.text == "hammer")
    }

    @Test("Ein angefangenes Wort bleibt beim Tippen stehen")
    func pendingWordStays() {
        let result = parser.parse("rechnung #ste", final: false)
        #expect(result.tokens.isEmpty)
        #expect(result.text == "rechnung #ste")
    }

    @Test("Exakter Name schlägt längere Präfix-Treffer")
    func exactBeatsPrefix() {
        #expect(parser.resolve("steuer", kind: .tag)?.id == 1)
        // "Ste" ist mehrdeutig (Steuer, Steuerberater).
        #expect(parser.resolve("ste", kind: .tag) == nil)
        #expect(parser.resolve("steuerb", kind: .tag)?.id == 3)
    }

    @Test("Namen mit Leerzeichen in Anführungszeichen")
    func quotedNames() {
        let result = parser.parse(#"#"Haus und Garten" zaun"#, final: true)
        #expect(result.tokens == [.tag(2)])
        #expect(result.text == "zaun")
    }

    @Test("Unbekannte Namen bleiben Freitext")
    func unknownStaysText() {
        let result = parser.parse("#gibtsnicht ", final: false)
        #expect(result.tokens.isEmpty)
        #expect(result.text == "#gibtsnicht ")
    }

    @Test func suggestions() {
        #expect(parser.suggestions(for: "rechnung @am") == [.correspondent(11)])
        #expect(parser.suggestions(for: "#").count == 3)
        #expect(parser.suggestions(for: "rechnung").isEmpty)
    }

    @Test func removingTrailingWord() {
        #expect(SearchParser.removingTrailingPrefixWord("hammer #ste") == "hammer")
        #expect(SearchParser.removingTrailingPrefixWord("hammer") == "hammer")
    }

    @Test("Filter werden zu Query-Parametern")
    func queryItems() {
        let query = DocumentQuery(text: "  zaun ", tokens: [.inbox, .tag(1), .tag(2), .correspondent(10)], sort: .added)
        let items = Dictionary(query.queryItems(page: 2, pageSize: 60).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { a, _ in a })
        #expect(items["query"] == "zaun")
        #expect(items["ordering"] == nil)
        #expect(items["is_in_inbox"] == "true")
        #expect(items["tags__id__all"] == "1,2")
        #expect(items["correspondent__id__in"] == "10")
        #expect(items["page"] == "2")
    }

    @Test("Ohne Text wird sortiert")
    func sortWithoutText() {
        let items = DocumentQuery(sort: .added).queryItems(page: 1, pageSize: 10)
        #expect(items.contains(URLQueryItem(name: "ordering", value: "-added")))
        #expect(!items.contains { $0.name == "query" })
    }

    @Test("Offline-Filter")
    func localMatching() {
        let doc = Document(id: 1, title: "Obi Hammer", correspondent: 10, documentType: 20, tags: [1, 99],
                           created: nil, added: nil, modified: nil, content: "Bohrhammer SDS plus",
                           pageCount: nil, originalFileName: nil, searchHit: nil)
        #expect(DocumentQuery(text: "sds hammer").matches(doc, inboxTags: []))
        #expect(!DocumentQuery(text: "zaun").matches(doc, inboxTags: []))
        #expect(DocumentQuery(tokens: [.inbox]).matches(doc, inboxTags: [99]))
        #expect(!DocumentQuery(tokens: [.inbox]).matches(doc, inboxTags: [5]))
        #expect(DocumentQuery(tokens: [.correspondent(10), .correspondent(11)]).matches(doc, inboxTags: []))
        #expect(!DocumentQuery(tokens: [.documentType(21)]).matches(doc, inboxTags: []))
    }
}

@Suite("Treffer-Markierung")
struct HighlightTests {
    @Test func segments() {
        let parts = HighlightParser.segments(#"Die <span class="match">Rechnung</span> vom <span class="match">Mai</span>"#)
        #expect(parts == [
            .init(text: "Die ", isMatch: false),
            .init(text: "Rechnung", isMatch: true),
            .init(text: " vom ", isMatch: false),
            .init(text: "Mai", isMatch: true),
        ])
    }

    @Test func plain() {
        #expect(HighlightParser.segments("nichts") == [.init(text: "nichts", isMatch: false)])
    }
}

@Suite("Spotlight-Kennungen")
struct SpotlightTests {
    @Test func roundTrip() {
        #expect(SpotlightIndexer.documentID(from: SpotlightIndexer.identifier(123)) == 123)
        #expect(SpotlightIndexer.documentID(from: "etwas") == nil)
    }
}

@Suite("Lokale Kopie")
struct LibraryStoreTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "FundusTests-\(UUID().uuidString)")

    func doc(_ id: Int, content: String?, modified: String) -> Document {
        Document(id: id, title: "D\(id)", correspondent: nil, documentType: nil, tags: [], created: "2026-01-0\(id)",
                 added: nil, modified: modified, content: content, pageCount: nil, originalFileName: nil, searchHit: nil)
    }

    @Test func upsertKeepsFullTextAndTracksModified() async {
        let store = LibraryStore(host: "test", baseDirectory: base)
        defer { try? FileManager.default.removeItem(at: base) }
        await store.upsert([doc(1, content: "vollständiger langer Text", modified: "2026-01-01")], lastModified: "2026-01-01")
        // Gekürzte Listenantwort mit gleichem Stand überschreibt den vollen Text nicht.
        await store.upsert([doc(1, content: "voll…", modified: "2026-01-01")], lastModified: nil)
        let snapshot = await store.current()
        #expect(snapshot.documents[1]?.content == "vollständiger langer Text")
        #expect(snapshot.lastModified == "2026-01-01")
    }

    @Test func retainRemovesDeleted() async {
        let store = LibraryStore(host: "test", baseDirectory: base)
        defer { try? FileManager.default.removeItem(at: base) }
        await store.upsert([doc(1, content: nil, modified: "a"), doc(2, content: nil, modified: "a")], lastModified: "a")
        let removed = await store.retainOnly([2])
        #expect(removed == [1])
        let results = await store.documents(matching: DocumentQuery())
        #expect(results.map(\.id) == [2])
    }
}

@Suite("Benutzerdefinierte Felder")
struct CustomFieldTests {
    func decodeObject(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func documentWithFields() throws {
        let json = #"""
        {"id": 1, "title": "x", "tags": [], "custom_fields": [
          {"field": 1, "value": "EUR12.50"}, {"field": 2, "value": true}, {"field": 3, "value": 7},
          {"field": 4, "value": 1.5}, {"field": 5, "value": [3, 4]}, {"field": 6, "value": null}]}
        """#
        let doc = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        #expect(doc.customFields?.map(\.value) == [.string("EUR12.50"), .bool(true), .int(7), .double(1.5), .ids([3, 4]), .null])
    }

    @Test("Liste ohne Felder bleibt nil")
    func documentWithoutFields() throws {
        let doc = try JSONDecoder().decode(Document.self, from: Data(#"{"id": 1, "title": "x", "tags": []}"#.utf8))
        #expect(doc.customFields == nil)
    }

    @Test func selectOptionsModern() throws {
        let json = #"{"id": 2, "name": "Status", "data_type": "select", "extra_data": {"select_options": [{"id": "aB3", "label": "Offen"}], "default_currency": null}}"#
        let field = try JSONDecoder().decode(CustomFieldDefinition.self, from: Data(json.utf8))
        #expect(field.kind == .select)
        #expect(field.label(for: .string("aB3")) == "Offen")
    }

    @Test("Vor 2.14: Optionen als Namen, Wert ist der Index")
    func selectOptionsLegacy() throws {
        let json = #"{"id": 2, "name": "Status", "data_type": "select", "extra_data": {"select_options": ["Offen", "Bezahlt"]}}"#
        let field = try JSONDecoder().decode(CustomFieldDefinition.self, from: Data(json.utf8))
        #expect(field.label(for: .int(1)) == "Bezahlt")
        // Round-Trip über die lokale Kopie.
        let again = try JSONDecoder().decode(CustomFieldDefinition.self, from: JSONEncoder().encode(field))
        #expect(again == field)
    }

    @Test func monetary() {
        let parsed = Monetary.parse(.string("EUR12.50"))
        #expect(parsed.currency == "EUR")
        #expect(parsed.amount == Decimal(string: "12.5"))
        #expect(Monetary.parse(.double(3.5)).currency == nil)
        #expect(Monetary.value(currency: "usd", amount: Decimal(string: "1234.5")) == .string("USD1234.50"))
        #expect(Monetary.value(currency: "EUR", amount: nil) == .null)
    }

    @Test("Felder werden nur bei Änderungen gesendet")
    func updateSendsFieldsOnlyWhenChanged() throws {
        var doc = Document(id: 1, title: "T", correspondent: nil, documentType: nil, tags: [], created: "2026-01-05",
                           added: nil, modified: nil, content: nil, pageCount: nil, originalFileName: nil, searchHit: nil)
        #expect(try decodeObject(DocumentUpdate(doc))["custom_fields"] == nil)

        doc.customFields = [CustomFieldInstance(field: 1, value: .int(3))]
        var update = DocumentUpdate(doc)
        #expect(try decodeObject(update)["custom_fields"] == nil)

        update.customFields?.append(CustomFieldInstance(field: 2, value: .null))
        let sent = try #require(try decodeObject(update)["custom_fields"] as? [[String: Any]])
        #expect(sent.count == 2)
        #expect(sent[1]["value"] is NSNull)

        // Nach dem Sichern gilt der neue Stand als unverändert.
        var saved = doc
        saved.customFields = update.customFields
        #expect(update == DocumentUpdate(saved))

        // Unbekannte Felder (nil) nie überschreiben.
        doc.customFields = nil
        var blind = DocumentUpdate(doc)
        blind.customFields = [CustomFieldInstance(field: 9, value: .int(1))]
        #expect(try decodeObject(blind)["custom_fields"] == nil)
    }
}
