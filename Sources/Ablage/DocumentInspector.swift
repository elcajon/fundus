import SwiftUI

/// Metadaten des fokussierten Dokuments ansehen und bearbeiten. Im Eingang mit „Erledigt“.
struct DocumentInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedIDs.count > 1 && model.readerID == nil {
            ContentUnavailableView {
                Label("\(model.selectedIDs.count) Dokumente ausgewählt", systemImage: "doc.on.doc")
            } description: {
                Text("Teilen, Exportieren oder Ziehen wirkt auf alle ausgewählten Dokumente.")
            }
        } else if let doc = model.focusedDocument {
            DocumentEditor(document: doc)
                .id(doc.id)
        } else {
            ContentUnavailableView("Kein Dokument ausgewählt", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Doppelklick oder Leertaste öffnet es zum Lesen."))
        }
    }
}

private struct DocumentEditor: View {
    @Environment(AppModel.self) private var model
    let document: Document
    @State private var draft: DocumentUpdate
    @State private var isSaving = false
    @State private var tagFilter = ""

    init(document: Document) {
        self.document = document
        _draft = State(initialValue: DocumentUpdate(document))
    }

    private var isDirty: Bool { draft != DocumentUpdate(document) }
    private var editable: Bool { model.canEdit && !isSaving }

    var body: some View {
        Form {
            if model.isInInbox(document) {
                Section {
                    Button {
                        save(done: true)
                    } label: {
                        Label("Erledigt und weiter", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!editable)
                } footer: {
                    Text("Speichert die Änderungen und entfernt die Eingangs-Tags (⌘↩).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Dokument") {
                TextField("Titel", text: $draft.title, axis: .vertical)
                    .lineLimit(1...4)
                    .frame(minWidth: 0)
                DatePicker("Datum", selection: $draft.created, displayedComponents: .date)
                Picker("Korrespondent", selection: $draft.correspondent) {
                    Text("Keiner").tag(Int?.none)
                    Divider()
                    ForEach(model.correspondents) { item in
                        Text(item.name).tag(Int?.some(item.id))
                    }
                }
                Picker("Dokumenttyp", selection: $draft.documentType) {
                    Text("Keiner").tag(Int?.none)
                    Divider()
                    ForEach(model.documentTypes) { item in
                        Text(item.name).tag(Int?.some(item.id))
                    }
                }
            }
            .disabled(!editable)

            Section("Tags") {
                if !draft.tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(draft.tags, id: \.self) { id in
                            let tag = model.tag(id)
                            Button {
                                draft.tags.removeAll { $0 == id }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(tag?.name ?? "#\(id)")
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                            }
                            .buttonStyle(PillButtonStyle(fill: Color(hex: tag?.color), foreground: Color(hex: tag?.textColor)))
                            .help("Tag entfernen")
                            .accessibilityLabel(Text("Tag \(tag?.name ?? String(id)) entfernen"))
                        }
                    }
                }
                Menu("Tag hinzufügen") {
                    ForEach(model.tags.filter { !draft.tags.contains($0.id) }) { tag in
                        Button(tag.name) { draft.tags.append(tag.id) }
                    }
                }
            }
            .disabled(!editable)

            Section {
                HStack {
                    Button("Zurücksetzen") { draft = DocumentUpdate(document) }
                        .disabled(!isDirty || isSaving)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("Sichern") { save(done: false) }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty || !editable)
                }
            } footer: {
                if !model.canEdit {
                    Text(model.phase == .ready
                         ? LocalizedStringKey("Zum Bearbeiten wird ein Paperless-API-Token benötigt (Einstellungen → Verbindung).")
                         : LocalizedStringKey("Offline kann nichts geändert werden."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Details") {
                if let added = document.addedDate {
                    detail("Hinzugefügt", added.formatted(date: .abbreviated, time: .omitted))
                }
                if let pages = document.pageCount {
                    detail("Seiten", pages.formatted())
                }
                if let file = document.originalFileName {
                    detail("Datei", file)
                }
                detail("ID", "#\(document.id)")
                if let url = model.client?.webURL(for: document.id) {
                    Link("In Paperless öffnen", destination: url)
                }
            }

            if let content = document.content, !content.isEmpty {
                Section("Text") {
                    Text(content)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Werte kürzen statt die Spalte zu verbreitern.
    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
                .textSelection(.enabled)
        }
    }

    private func save(done: Bool) {
        isSaving = true
        Task {
            if done {
                await model.markDone(document.id, with: draft)
            } else {
                await model.save(document.id, draft)
            }
            isSaving = false
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var fill: Color?
    var foreground: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground ?? (fill == nil ? Color.primary.opacity(0.85) : .white))
            .background(fill ?? Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Liste der laufenden und abgeschlossenen Importe mit den Meldungen von Paperless.
struct ImportsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.imports.isEmpty {
                ContentUnavailableView("Keine Importe", systemImage: "tray",
                                       description: Text("Dateien aufs Fenster ziehen oder ⌘O."))
            } else {
                List(model.imports) { job in
                    HStack(alignment: .top, spacing: 10) {
                        icon(for: job.state)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.fileName).lineLimit(1)
                            Text(detail(for: job.state))
                                .font(.caption)
                                .foregroundStyle(job.isFailed ? .orange : .secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if case let .done(id?) = job.state {
                            Button("Öffnen") {
                                model.showImports = false
                                Task { await model.open(documentID: id) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Abgeschlossene entfernen") { model.clearFinishedImports() }
                    .disabled(!model.imports.contains { !$0.isActive })
            }
            .padding(10)
        }
    }

    @ViewBuilder private func icon(for state: AppModel.ImportJob.State) -> some View {
        switch state {
        case .uploading, .processing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func detail(for state: AppModel.ImportJob.State) -> String {
        switch state {
        case .uploading: String(localized: "Wird hochgeladen …")
        case .processing: String(localized: "Paperless verarbeitet das Dokument …")
        case .done: String(localized: "Importiert")
        case let .failed(message): message
        }
    }
}

/// Menü in der Menüleiste: neue Dokumente und schnelle Aktionen, auch ohne offenes Fenster.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.recentNew.isEmpty {
            Text("Keine neuen Dokumente")
        } else {
            Section("Neu") {
                ForEach(model.recentNew) { doc in
                    Button(doc.title) { Task { await model.open(documentID: doc.id) } }
                }
            }
        }
        Divider()
        Button("Ablage öffnen") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Eingang anzeigen") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
            if !model.searchTokens.contains(.inbox) { model.toggleInbox() }
        }
        Button("Importieren …") {
            NSApp.activate(ignoringOtherApps: true)
            model.importFiles()
        }
        .disabled(model.phase != .ready)
        Button("Jetzt nach neuen Dokumenten sehen") {
            Task { await model.watcher.check() }
        }
        .disabled(model.phase != .ready)
        Divider()
        SettingsLink { Text("Einstellungen …") }
        Button("Ablage beenden") { NSApp.terminate(nil) }
    }
}
