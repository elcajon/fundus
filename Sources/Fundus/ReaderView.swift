import PDFKit
import SwiftUI

/// Lesemodus im Hauptfenster: das Dokument in voller Größe, Titel und Datum in der Leiste.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let documentID: Int
    @State private var pdf: PDFDocument?
    @State private var image: NSImage?
    @State private var placeholder: NSImage?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.readerID = nil }

            if let pdf {
                PDFKitView(document: pdf)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .padding(EdgeInsets(top: 24, leading: 40, bottom: 28, trailing: 40))
            } else if let error {
                VStack(spacing: 10) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Zurück") { model.readerID = nil }
                }
            } else if let placeholder {
                // Das Vorschaubild steht schon da, bis das PDF geladen ist.
                Image(nsImage: placeholder)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 0.6)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .padding(EdgeInsets(top: 24, leading: 40, bottom: 28, trailing: 40))
                    .overlay(alignment: .bottom) { ProgressView().controlSize(.small).padding(.bottom, 48) }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: documentID) { await load() }
    }

    private func load() async {
        placeholder = await model.thumbnails.image(for: documentID, client: model.client)
        let store = model.store
        // Schon einmal geöffnet: sofort aus der lokalen Kopie zeigen.
        if let cached = store?.preview(documentID), show(cached) {
            return
        }
        guard let client = model.client, model.phase == .ready else {
            error = String(localized: "Offline, und dieses Dokument wurde noch nicht geöffnet.")
            return
        }
        do {
            let data = try await client.preview(documentID)
            if show(data) {
                await store?.storePreview(data, for: documentID)
            } else {
                error = String(localized: "Diese Vorschau kann ich nicht anzeigen.")
            }
        } catch ClientError.pangolinLoginRequired {
            model.loginHint = String(localized: "Die Pangolin-Session ist abgelaufen. Bitte neu anmelden.")
            model.showLogin = true
            error = String(localized: "Anmeldung bei Pangolin erforderlich.")
        } catch {
            Log.network.error("Vorschau \(documentID) nicht geladen: \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func show(_ data: Data) -> Bool {
        if let doc = PDFDocument(data: data) {
            pdf = doc
            return true
        }
        if let img = NSImage(data: data) {
            image = img
            return true
        }
        return false
    }
}

/// Passt die Seite ganz ins Fenster ein, bis der Nutzer selbst zoomt.
private final class FitPDFView: PDFView {
    private var userZoomed = false

    override func layout() {
        super.layout()
        fitIfNeeded()
    }

    override func magnify(with event: NSEvent) {
        userZoomed = true
        super.magnify(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { userZoomed = true }
        super.scrollWheel(with: event)
    }

    func fitIfNeeded() {
        guard !userZoomed, let page = document?.page(at: 0) else { return }
        let bounds = page.bounds(for: displayBox)
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let available = CGSize(width: self.bounds.width - 60, height: self.bounds.height - 48)
        guard pageSize.width > 0, pageSize.height > 0, available.width > 0, available.height > 0 else { return }
        let scale = min(available.width / pageSize.width, available.height / pageSize.height)
        if abs(scaleFactor - scale) > 0.001 { scaleFactor = scale }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = FitPDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 24, bottom: 24, right: 24)
        view.backgroundColor = .windowBackgroundColor
        view.document = document
        view.fitIfNeeded()
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
