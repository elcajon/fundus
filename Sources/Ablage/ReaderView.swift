import PDFKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let document: Document?

    var body: some View {
        if let document {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(document.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        field("Absender", model.correspondentName(document.correspondent))
                        field("Typ", model.typeName(document.documentType))
                        field("Datum", document.createdDate?.formatted(date: .long, time: .omitted))
                        field("Seiten", document.pageCount.map(String.init))
                        field("Datei", document.originalFileName)
                        field("ID", "#\(document.id)")
                    }
                    .font(.callout)

                    if !document.tags.isEmpty {
                        FlowTags(ids: document.tags)
                    }

                    HStack {
                        Button("Lesen") { openWindow(value: document.id) }
                            .buttonStyle(.borderedProminent)
                        if let url = model.client?.webURL(for: document.id) {
                            Button("In Paperless") { NSWorkspace.shared.open(url) }
                        }
                    }

                    if let content = document.content, !content.isEmpty {
                        Divider()
                        Text(content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Kein Dokument ausgewählt", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Doppelklick oder Leertaste öffnet es zum Lesen."))
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct FlowTags: View {
    @Environment(AppModel.self) private var model
    let ids: [Int]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ids.compactMap(model.tag).prefix(6)) { tag in
                Text(tag.name)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((Color(hex: tag.color) ?? .secondary).opacity(0.25), in: Capsule())
            }
        }
    }
}

struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let documentID: Int
    @State private var document: Document?
    @State private var pdf: PDFDocument?
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        Group {
            if let pdf {
                PDFKitView(document: pdf)
            } else if let image {
                ScrollView { Image(nsImage: image).resizable().scaledToFit().padding() }
            } else if let error {
                ContentUnavailableView("Konnte nicht geladen werden", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(document?.title ?? "Dokument")
        .toolbar {
            if let url = model.client?.webURL(for: documentID) {
                ToolbarItem {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("In Paperless öffnen", systemImage: "safari")
                    }
                }
            }
            ToolbarItem {
                Button { Task { await saveOriginal() } } label: {
                    Label("Original sichern", systemImage: "square.and.arrow.down")
                }
            }
        }
        .task(id: documentID) { await load() }
    }

    private func load() async {
        guard let client = model.client else { error = "Keine Verbindung."; return }
        do {
            async let meta = client.document(documentID)
            let data = try await client.preview(documentID)
            if let pdf = PDFDocument(data: data) {
                self.pdf = pdf
            } else if let image = NSImage(data: data) {
                self.image = image
            } else {
                error = "Unbekanntes Vorschauformat."
            }
            document = try? await meta
        } catch ClientError.pangolinLoginRequired {
            model.loginHint = "Die Pangolin-Session ist abgelaufen. Bitte neu anmelden."
            model.showLogin = true
            error = "Anmeldung bei Pangolin erforderlich."
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func saveOriginal() async {
        guard let client = model.client else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document?.originalFileName ?? "\(document?.title ?? "Dokument").pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let data = try await client.download(documentID, original: true)
            try data.write(to: target)
        } catch {
            model.toast = error.localizedDescription
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
