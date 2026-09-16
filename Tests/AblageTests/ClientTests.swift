import Foundation
import Testing
@testable import Ablage

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

@Suite("Push-Workflow")
struct PushWorkflowTests {
    @Test(arguments: [
        ("2.15.3", false), ("2.16.0", true), ("2.18.4", true), ("3.0.0", true), (nil, true), ("dev", true),
    ] as [(String?, Bool)])
    func templateSyntax(version: String?, jinja: Bool) {
        #expect(PaperlessClient.usesJinjaTemplates(version: version) == jinja)
    }

    @Test("Jinja-Body ist nach dem Rendern gültiges JSON")
    func jinjaBodyShape() throws {
        let hook = PaperlessClient.pushWebhook(server: URL(string: "https://ntfy.sh")!, topic: "t\"x",
                                               paperlessURL: URL(string: "https://p.example/")!, jinja: true)
        // Platzhalter so ersetzen, wie Paperless es mit `tojson` täte.
        let rendered = hook.body
            .replacingOccurrences(of: #"{{ (doc_title ~ ((" · " ~ correspondent) if correspondent else "")) | tojson }}"#,
                                  with: #""Rechnung \"A\" · Obi""#)
            .replacingOccurrences(of: "{{ doc_id }}", with: "42")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(object["topic"] as? String == "t\"x")
        #expect(object["message"] as? String == "Rechnung \"A\" · Obi")
        #expect(object["click"] as? String == "https://p.example/documents/42/details")
        #expect(hook.url == "https://ntfy.sh")
    }

    @Test("Alte Versionen senden Klartext an das Thema")
    func legacyBody() {
        let hook = PaperlessClient.pushWebhook(server: URL(string: "https://ntfy.sh")!, topic: "abc",
                                               paperlessURL: URL(string: "https://p.example/")!, jinja: false)
        #expect(hook.url == "https://ntfy.sh/abc")
        #expect(hook.body == "{doc_title}")
        #expect(hook.headers["Title"] == "Neues Dokument")
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
