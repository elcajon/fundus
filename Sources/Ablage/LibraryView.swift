import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Document.ID?
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        } detail: {
            ZStack {
                grid
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .background(Color.accentColor.opacity(0.06))
                        .overlay(Label("An Paperless übergeben", systemImage: "tray.and.arrow.down").font(.title3))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
            .navigationTitle(model.filterTitle)
            .navigationSubtitle(subtitle)
            .searchable(text: $model.search, placement: .toolbar, prompt: "Titel, Absender, Volltext …")
            .task(id: SearchKey(filter: model.filter, search: model.search)) {
                // Tipp-Pausen abwarten, damit nicht jede Taste eine Volltextsuche auslöst.
                if !model.search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled, model.phase == .ready else { return }
                selection = nil
                await model.reload()
            }
            .toolbar {
                ToolbarItem {
                    Button { showInspector.toggle() } label: {
                        Label("Informationen", systemImage: "sidebar.trailing")
                    }
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(document: selectedDocument)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        .overlay(alignment: .bottom) { toast }
    }

    private var subtitle: String {
        switch model.phase {
        case .connecting: "Verbinde …"
        case let .failed(msg): msg
        default: model.totalCount == 1 ? "1 Dokument" : "\(model.totalCount) Dokumente"
        }
    }

    private var selectedDocument: Document? {
        model.documents.first { $0.id == selection }
    }

    @ViewBuilder private var grid: some View {
        if model.documents.isEmpty {
            ContentUnavailableView {
                if model.isLoadingPage || model.phase == .connecting {
                    ProgressView()
                } else if case .failed = model.phase {
                    Label("Keine Verbindung", systemImage: "lock.shield")
                } else if !model.search.isEmpty {
                    Label("Nichts gefunden", systemImage: "magnifyingglass")
                } else {
                    Label("Keine Dokumente", systemImage: "doc")
                }
            } actions: {
                if case .failed = model.phase {
                    Button("Erneut verbinden") { Task { await model.connect() } }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 22)], spacing: 26) {
                    ForEach(model.documents) { doc in
                        DocumentCard(document: doc, isSelected: selection == doc.id)
                            .onTapGesture(count: 2) { openWindow(value: doc.id) }
                            .onTapGesture { selection = doc.id }
                            .contextMenu { contextMenu(for: doc) }
                            .onAppear {
                                if doc.id == model.documents.last?.id {
                                    Task { await model.loadMore() }
                                }
                            }
                    }
                }
                .padding(24)
                if model.isLoadingPage {
                    ProgressView().padding(.bottom, 24)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard let selection else { return .ignored }
                openWindow(value: selection)
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                moveSelection(by: press.key == .leftArrow ? -1 : 1)
                return .handled
            }
        }
    }

    @ViewBuilder private func contextMenu(for doc: Document) -> some View {
        Button("Öffnen") { openWindow(value: doc.id) }
        if let url = model.client?.webURL(for: doc.id) {
            Button("In Paperless öffnen") { NSWorkspace.shared.open(url) }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    private func moveSelection(by delta: Int) {
        let docs = model.documents
        guard !docs.isEmpty else { return }
        let index = docs.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : docs.count)
        let next = min(max(index + delta, 0), docs.count - 1)
        selection = docs[next].id
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                    urls.append(fileURL)
                }
            }
            await model.upload(urls)
        }
        return true
    }

    @ViewBuilder private var toast: some View {
        if let text = model.toast {
            Text(text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { model.toast = nil }
                }
        }
    }
}

private struct SearchKey: Equatable {
    let filter: SidebarItem
    let search: String
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.filter }, set: { model.filter = $0 ?? .all })) {
            Section {
                Label("Alle Dokumente", systemImage: "doc.on.doc").tag(SidebarItem.all)
                Label("Eingang", systemImage: "tray").tag(SidebarItem.inbox)
            }
            if !model.correspondents.isEmpty {
                Section("Korrespondenten") {
                    ForEach(model.correspondents.filter { ($0.documentCount ?? 1) > 0 }) { item in
                        row(item, icon: "person.crop.square").tag(SidebarItem.correspondent(item.id))
                    }
                }
            }
            if !model.documentTypes.isEmpty {
                Section("Typen") {
                    ForEach(model.documentTypes.filter { ($0.documentCount ?? 1) > 0 }) { item in
                        row(item, icon: "doc.text").tag(SidebarItem.documentType(item.id))
                    }
                }
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags.filter { ($0.documentCount ?? 1) > 0 }) { item in
                        HStack {
                            Circle().fill(Color(hex: item.color) ?? .secondary).frame(width: 9, height: 9)
                            Text(item.name)
                            Spacer()
                            count(item)
                        }
                        .tag(SidebarItem.tag(item.id))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let profile = model.profile {
                HStack {
                    Image(systemName: "person.circle")
                    Text(profile.displayName).lineLimit(1)
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
            }
        }
    }

    private func row(_ item: NamedItem, icon: String) -> some View {
        HStack {
            Label(item.name, systemImage: icon)
            Spacer()
            count(item)
        }
    }

    @ViewBuilder private func count(_ item: NamedItem) -> some View {
        if let n = item.documentCount {
            Text("\(n)").foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

struct DocumentCard: View {
    @Environment(AppModel.self) private var model
    let document: Document
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(Color(nsColor: .textBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, minHeight: 0, alignment: .top)
                } else {
                    Image(systemName: "doc")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                }
            }
            .aspectRatio(1 / 1.414, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.18), radius: isSelected ? 10 : 4, y: isSelected ? 5 : 2)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    .padding(-4)
            )
            .scaleEffect(isSelected ? 1.02 : 1)
            .animation(.spring(duration: 0.25), value: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let highlight = document.searchHit?.highlights, !highlight.isEmpty {
                    Text(highlightText(highlight))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: document.id) {
            guard let client = model.client else { return }
            image = await model.thumbnails.image(for: document.id, client: client)
        }
    }

    private var caption: String {
        let date = document.createdDate?.formatted(date: .abbreviated, time: .omitted)
        return [model.correspondentName(document.correspondent), date].compactMap { $0 }.joined(separator: " · ")
    }

    /// Paperless markiert Treffer mit <span class="match">…</span>.
    private func highlightText(_ html: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(html)
        while let open = rest.range(of: "<span class=\"match\">") {
            result += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "</span>") else { break }
            var hit = AttributedString(String(rest[..<close.lowerBound]))
            hit.foregroundColor = .primary
            hit.font = .caption2.bold()
            result += hit
            rest = rest[close.upperBound...]
        }
        result += AttributedString(String(rest))
        return result
    }
}
