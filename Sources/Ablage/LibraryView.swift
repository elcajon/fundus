import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var columns = 1
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            DocumentGrid(columns: $columns)
                .opacity(model.readerID == nil ? 1 : 0)
                .scaleEffect(model.readerID == nil ? 1 : 1.03)

            if let id = model.readerID {
                ReaderView(documentID: id)
                    .id(id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                            removal: .scale(scale: 0.96).combined(with: .opacity)))
            }

            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .overlay(Text("Loslassen, um zu importieren").font(.headline))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.12), value: model.readerID)
        .overlay(alignment: .top) { OfflineBanner() }
        .overlay(alignment: .bottom) { ToastView() }
        .inspector(isPresented: $model.showInspector) {
            DocumentInspector()
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .searchable(text: $model.search, tokens: $model.searchTokens, placement: .toolbar,
                    prompt: Text("Suchen, #Tag, @Absender, typ:Typ")) { token in
            Label(model.name(of: token), systemImage: model.symbol(of: token))
        }
        .searchFocus($searchFocused)
        .searchSuggestions { suggestions }
        .onSubmit(of: .search) {
            model.submitSearch()
            if model.search.isEmpty { return }
            if let first = model.documents.first { model.openReader(first.id) }
            gridFocused = true
        }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onChange(of: model.readerID) { gridFocused = true }
        .onCommand(#selector(NSResponder.selectAll(_:))) { model.selectAll() }
        .onKeyPress(.space) { toggleReader() }
        .onKeyPress(.return) { toggleReader() }
        .onKeyPress(.escape) {
            if model.readerID != nil { model.readerID = nil; return .handled }
            if !model.selectedIDs.isEmpty { model.select(nil); return .handled }
            return .ignored
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            if model.readerID != nil {
                // Im Lesemodus scrollt ↑/↓ die Seiten, ←/→ blättert durch die Dokumente.
                guard press.key == .leftArrow || press.key == .rightArrow else { return .ignored }
                model.step(press.key == .leftArrow ? -1 : 1)
                return .handled
            }
            switch press.key {
            case .leftArrow: model.step(-1)
            case .rightArrow: model.step(1)
            case .upArrow: model.step(-columns)
            default: model.step(columns)
            }
            return .handled
        }
        .task(id: model.query) {
            // Tipp-Pausen abwarten, damit nicht jede Taste eine Volltextsuche auslöst.
            try? await Task.sleep(for: .milliseconds(model.search.isEmpty ? 0 : 280))
            guard !Task.isCancelled else { return }
            switch model.phase {
            case .ready, .offline: await model.reload()
            default: break
            }
        }
    }

    private var readerDocument: Document? { model.document(model.readerID) }

    private var title: String {
        readerDocument?.title ?? "Fundus"
    }

    private var subtitle: String {
        if let doc = readerDocument {
            return doc.createdDate?.formatted(date: .long, time: .omitted) ?? ""
        }
        switch model.phase {
        case .connecting: return String(localized: "Verbinde …")
        case let .failed(message): return message
        default:
            if model.selectedIDs.count > 1 {
                return String(localized: "\(model.selectedIDs.count) von \(model.totalCount) ausgewählt")
            }
            if model.query.isFiltered {
                return String(localized: "\(model.totalCount) Treffer")
            }
            return model.totalCount == 1 ? String(localized: "1 Dokument") : String(localized: "\(model.totalCount) Dokumente")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.readerID != nil {
            ToolbarItem(placement: .navigation) {
                Button { model.readerID = nil } label: {
                    Label("Zurück", systemImage: "chevron.left")
                }
                .help("Zurück zur Übersicht (Esc)")
            }
        }
        if model.activeImportCount > 0 || model.failedImportCount > 0 {
            ToolbarItem(placement: .primaryAction) {
                ImportStatusButton()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.importFiles() } label: {
                Label("Importieren", systemImage: "plus")
            }
            .help("Importieren (⌘O)")
            .disabled(model.phase != .ready)
            Button { Task { await model.share() } } label: {
                Label("Teilen", systemImage: "square.and.arrow.up")
            }
            .help("Teilen (⇧⌘S)")
            .disabled(model.actionTargets.isEmpty)
            Button { Task { await model.export() } } label: {
                Label("Exportieren", systemImage: "square.and.arrow.down")
            }
            .help("Exportieren (⌘E)")
            .disabled(model.actionTargets.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showInspector.toggle() } label: {
                Label("Informationen", systemImage: "info.circle")
            }
            .help("Informationen (⌘I)")
        }
    }

    @ViewBuilder private var suggestions: some View {
        let tokens = model.tokenSuggestions
        if !tokens.isEmpty {
            ForEach(tokens) { token in
                Button {
                    model.addToken(token)
                } label: {
                    Label(model.name(of: token), systemImage: model.symbol(of: token))
                }
            }
        } else if !model.search.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(model.documents.prefix(6)) { doc in
                Button {
                    model.openReader(doc.id)
                    searchFocused = false
                    gridFocused = true
                } label: {
                    Label(doc.title, systemImage: "doc.text")
                }
            }
        } else if model.searchTokens.isEmpty {
            Section("Filter") {
                Button { model.toggleInbox() } label: {
                    Label("Eingang", systemImage: "tray")
                }
                Text("#Tag, @Korrespondent oder typ:Dokumenttyp eingeben")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleReader() -> KeyPress.Result {
        if model.readerID != nil {
            model.readerID = nil
        } else if model.focusedID != nil {
            model.openReader()
        } else {
            return .ignored
        }
        return .handled
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            await model.upload(urls)
        }
        return true
    }
}

private struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case let .offline(reason) = model.phase {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("Offline: lokale Kopie. \(reason)")
                    .lineLimit(1)
                Button("Erneut verbinden") { Task { await model.connect() } }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
            .padding(.top, 8)
        }
    }
}

struct ImportStatusButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button { model.showImports.toggle() } label: {
            if model.activeImportCount > 0 {
                Label {
                    Text(model.activeImportCount == 1 ? LocalizedStringKey("1 Import") : LocalizedStringKey("\(model.activeImportCount) Importe"))
                } icon: {
                    ProgressView().controlSize(.small)
                }
            } else {
                Label("\(model.failedImportCount) fehlgeschlagen", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .help("Importe anzeigen")
        .popover(isPresented: $model.showImports, arrowEdge: .bottom) {
            ImportsView()
                .frame(width: 380, height: 320)
        }
    }
}

// MARK: - Raster

struct DocumentGrid: View {
    @Environment(AppModel.self) private var model
    @Binding var columns: Int

    private let padding: CGFloat = 38

    var body: some View {
        GeometryReader { geo in
            let spacing = 42 * min(model.zoom, 1.2)
            let target = 290 * model.zoom
            let usable = geo.size.width - padding * 2
            let count = max(1, Int((usable + spacing) / (target + spacing)))
            let cell = (usable - spacing * CGFloat(count - 1)) / CGFloat(count)

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing, alignment: .topLeading),
                                             count: count),
                              alignment: .leading, spacing: 46) {
                        ForEach(model.documents) { doc in
                            DocumentTile(document: doc, width: cell)
                                .id(doc.id)
                                .onAppear {
                                    if doc.id == model.documents.last?.id {
                                        Task { await model.loadMore() }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.top, 20)
                    .padding(.bottom, 48)

                    if model.isLoadingPage && !model.documents.isEmpty {
                        ProgressView().controlSize(.small).padding(.bottom, 32)
                    }
                }
                .scrollContentBackground(.hidden)
                .softTopScrollEdge()
                .background {
                    // Klick ins Leere hebt die Auswahl auf.
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.select(nil) }
                }
                .overlay { EmptyState() }
                .onChange(of: model.focusedID) { _, id in
                    guard let id, model.readerID == nil else { return }
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id) }
                }
                .onChange(of: count, initial: true) { _, new in columns = new }
                .onChange(of: model.query) { proxy.scrollTo("top", anchor: .top) }
            }
        }
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.documents.isEmpty {
            VStack(spacing: 12) {
                if model.isLoadingPage || model.phase == .connecting {
                    ProgressView()
                } else if case let .failed(message) = model.phase {
                    Text(message).foregroundStyle(.secondary)
                    Button("Erneut verbinden") { Task { await model.connect() } }
                        .glassButtonStyle()
                } else if model.searchTokens == [.inbox] && model.search.isEmpty {
                    Label("Eingang ist leer", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if model.query.isFiltered {
                    Text("Keine Treffer").foregroundStyle(.secondary)
                } else {
                    Text("Noch keine Dokumente").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

struct DocumentTile: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showInfo") private var showInfo = true
    @AppStorage("showType") private var showType = false
    @AppStorage("showCorrespondent") private var showCorrespondent = true
    @AppStorage("showTags") private var showTags = true

    let document: Document
    let width: CGFloat

    private var isSelected: Bool { model.selectedIDs.contains(document.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageStack(document: document, box: CGSize(width: width, height: width * 1.9), isSelected: isSelected)
                .onTapGesture {
                    // Doppelklick über den Klickzähler erkennen, damit die Auswahl ohne Verzögerung reagiert.
                    let event = NSApp.currentEvent
                    if (event?.clickCount ?? 1) >= 2 {
                        model.openReader(document.id)
                    } else {
                        model.click(document.id, modifiers: event?.modifierFlags ?? [])
                    }
                }
                .onDrag { model.dragProvider(for: document) }
                .contextMenu { contextMenu }

            if showInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let date = document.createdDate {
                        Text(date, format: .dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let highlight = document.searchHit?.highlights, !highlight.isEmpty {
                        Text(highlightText(highlight))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    pills
                        .padding(.top, 1)
                }
                .padding(.top, 12)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(document.id) }
        .accessibilityAction(named: Text("Lesen")) { model.openReader(document.id) }
    }

    private var accessibilityText: String {
        var parts = [document.title]
        if let name = model.correspondentName(document.correspondent) { parts.append(name) }
        if let date = document.createdDate { parts.append(date.formatted(date: .long, time: .omitted)) }
        let tags = document.tags.compactMap { model.tag($0)?.name }
        if !tags.isEmpty { parts.append(String(localized: "Tags: \(tags.joined(separator: ", "))")) }
        if model.isInInbox(document) { parts.append(String(localized: "im Eingang")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Lesen") { model.openReader(document.id) }
        Button("Informationen") {
            model.select(document.id)
            model.showInspector = true
        }
        Divider()
        Button("Teilen …") {
            if !isSelected { model.select(document.id) }
            Task { await model.share() }
        }
        Button("Exportieren …") {
            if !isSelected { model.select(document.id) }
            Task { await model.export() }
        }
        if model.isInInbox(document) && model.canEdit {
            Divider()
            Button("Als erledigt markieren") { Task { await model.markDone(document.id) } }
        }
        Divider()
        if let url = model.client?.webURL(for: document.id) {
            Button("In Paperless öffnen") { NSWorkspace.shared.open(url) }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    private func highlightText(_ html: String) -> AttributedString {
        HighlightParser.segments(html).reduce(into: AttributedString()) { result, segment in
            var part = AttributedString(segment.text)
            if segment.isMatch {
                part.foregroundColor = .primary
                part.font = .system(size: 11, weight: .semibold)
            }
            result += part
        }
    }

    @ViewBuilder private var pills: some View {
        let tags = showTags ? document.tags.compactMap(model.tag) : []
        let correspondent = showCorrespondent ? model.correspondentName(document.correspondent) : nil
        let type = showType ? model.typeName(document.documentType) : nil
        if correspondent != nil || type != nil || !tags.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if correspondent != nil || type != nil {
                    FlowLayout(spacing: 5) {
                        if let correspondent { Pill(text: correspondent) }
                        if let type { Pill(text: type) }
                    }
                }
                if !tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(tags) { tag in
                            Pill(text: tag.name, fill: Color(hex: tag.color), foreground: Color(hex: tag.textColor))
                        }
                    }
                }
            }
        }
    }
}

/// Die Seite in ihrem echten Seitenverhältnis, unten links in ihrer Zelle ausgerichtet.
/// Mehrseitige Dokumente bekommen angedeutete Blätter dahinter.
struct PageStack: View {
    @Environment(AppModel.self) private var model
    let document: Document
    let box: CGSize
    let isSelected: Bool
    @State private var image: NSImage?
    private var inInbox: Bool { model.isInInbox(document) }

    private var pageSize: CGSize {
        let ratio = image.map { $0.size.height / max($0.size.width, 1) } ?? 1.414
        let width = min(box.width - 8, (box.height - 8) / ratio)
        return CGSize(width: width, height: width * ratio)
    }

    var body: some View {
        let size = pageSize
        let extra = image == nil ? 0 : min(max((document.pageCount ?? 1) - 1, 0), 2)
        ZStack(alignment: .bottomLeading) {
            Color.clear
            ZStack(alignment: .bottomLeading) {
                ForEach((0..<extra).reversed(), id: \.self) { i in
                    let offset = CGFloat(i + 1) * 4
                    Rectangle()
                        .fill(Color(white: 0.93 - Double(i) * 0.06))
                        .frame(width: size.width, height: size.height)
                        .offset(x: offset, y: -offset)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                page
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .shadow(color: .black.opacity(image == nil ? 0 : 0.35), radius: 3, y: 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .padding(-5)
                            .opacity(isSelected ? 1 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if inInbox {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                .offset(x: 4, y: -4)
                                .help("Im Eingang")
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .frame(width: box.width, height: box.height, alignment: .bottomLeading)
        .animation(.smooth(duration: 0.2), value: isSelected)
        .task(id: document.id) {
            image = await model.thumbnails.image(for: document.id, client: model.client)
        }
    }

    @ViewBuilder private var page: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Rectangle().fill(Color.primary.opacity(0.06))
        }
    }
}

struct Pill: View {
    let text: String
    var fill: Color? = nil
    var foreground: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground ?? (fill == nil ? Color.primary.opacity(0.85) : .white))
            .background(fill ?? Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Einfacher Zeilenumbruch-Layout für die Pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        var points: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), points, sizes)
    }
}

// MARK: - Meldungen

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.toast {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassCapsule()
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { model.toast = nil }
                }
        }
    }
}
