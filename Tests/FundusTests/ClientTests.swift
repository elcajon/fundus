import Foundation
import Testing
@testable import Fundus

@Suite("Antworten einordnen")
struct ResponseKindTests {
    let host = "paperless.example.com"
    let api = URL(string: "https://paperless.example.com/api/documents/")!
    let json = "application/json; version=9"

    func classify(_ status: Int, type: String = "application/json", location: String? = nil,
                  accept: String? = "application/json; version=9") -> ResponseKind {
        ResponseKind.classify(status: status, contentType: type, location: location,
                              requestURL: api, host: host, accept: accept)
    }

    @Test func okIsOk() {
        #expect(classify(200) == .ok)
    }

    @Test("badger antwortet mit text/plain 401")
    func badgerUnauthorized() {
        #expect(classify(401, type: "text/plain; charset=utf-8") == .pangolinLogin)
    }

    @Test("Paperless antwortet mit JSON 401/403")
    func paperlessUnauthorized() {
        #expect(classify(401) == .paperlessUnauthorized)
        #expect(classify(403) == .paperlessUnauthorized)
    }

    @Test("Redirect zur Pangolin-Anmeldung")
    func pangolinRedirect() {
        let location = "https://proxy.example.com/auth/resource/abc?redirect=https%3A%2F%2Fpaperless.example.com%2F"
        #expect(classify(302, location: location) == .pangolinLogin)
    }

    @Test("Relativer Redirect bleibt bei Paperless")
    func relativeRedirect() {
        #expect(classify(301, location: "/api/documents/?page=1") == .failure(301))
    }

    @Test("Redirect auf fremden Host gilt als Anmeldung")
    func foreignRedirect() {
        #expect(classify(302, location: "https://sso.example.com/login") == .pangolinLogin)
    }

    @Test("406 wird einmal mit */* wiederholt")
    func notAcceptable() {
        #expect(classify(406, accept: "application/json; version=9") == .retryWithAnyAccept)
        #expect(classify(406, accept: "*/*") == .failure(406))
    }

    @Test("HTML statt JSON ist eine Anmeldeseite")
    func htmlInsteadOfJSON() {
        #expect(classify(200, type: "text/html; charset=utf-8") == .pangolinLogin)
        // Binärabrufe mit */* dürfen HTML nicht als Fehler werten.
        #expect(classify(200, type: "text/html", accept: "*/*") == .ok)
    }

    @Test func serverError() {
        #expect(classify(500) == .failure(500))
    }
}

@Suite("URLs")
struct URLTests {
    @Test("Plus in Zeitstempeln wird kodiert")
    func plusIsEncoded() {
        let url = PaperlessClient.url(base: URL(string: "https://p.example/")!, path: "api/documents/",
                                      query: [.init(name: "modified__gt", value: "2026-09-16T22:43:00+02:00"),
                                              .init(name: "query", value: "a b")])
        #expect(url.absoluteString == "https://p.example/api/documents/?modified__gt=2026-09-16T22:43:00%2B02:00&query=a%20b")
    }
}

@Suite("Fehlermeldungen")
struct ClientErrorTests {
    @Test func detailField() {
        #expect(ClientError.shortDetail(#"{"detail": "Nicht gefunden."}"#) == "Nicht gefunden.")
    }

    @Test func fieldErrors() {
        #expect(ClientError.shortDetail(#"{"title": ["Darf nicht leer sein."]}"#) == "title: Darf nicht leer sein.")
    }

    @Test func plainText() {
        #expect(ClientError.shortDetail("Bad Gateway") == "Bad Gateway")
    }
}

@Suite("Mehrteiliger Upload")
struct MultipartTests {
    @Test func bodyContainsFileAndBoundary() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Scan \"1\".pdf")
        try Data("%PDF-1.7 Inhalt".utf8).write(to: file)
        let body = dir.appending(path: "body")

        try PaperlessClient.writeMultipartBody(to: body, file: file, boundary: "XYZ")
        let text = try String(contentsOf: body, encoding: .utf8)
        #expect(text.hasPrefix("--XYZ\r\n"))
        #expect(text.contains(#"filename="Scan '1'.pdf""#))
        #expect(text.contains("%PDF-1.7 Inhalt"))
        #expect(text.hasSuffix("\r\n--XYZ--\r\n"))
    }
}

@Suite("Kurzbefehl")
struct ShortcutTests {
    @Test("Zeichen in der Reihenfolge der Menüs")
    func label() {
        // kVK_Space = 49; cmdKey = 256, shiftKey = 512, optionKey = 2048, controlKey = 4096
        #expect(Shortcut(keyCode: 49, modifiers: 512 | 256).label == "⇧⌘␣")
        #expect(Shortcut(keyCode: 49, modifiers: 4096 | 2048 | 512 | 256).label == "⌃⌥⇧⌘␣")
    }

    @Test("Standard ist ⇧⌘A")
    func standard() {
        #expect(Shortcut.standard.label == "⇧⌘A")
    }
}
