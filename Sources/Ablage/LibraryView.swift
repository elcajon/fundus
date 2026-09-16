import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var gridFocused: Bool
    @State private var columns = 1
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .top) {
            DocumentGrid(columns: $columns)
                .opacity(model.readerID == nil ? 1 : 0)
                .scaleEffect(model.readerID == nil ? 1 : 1.03)

            if let id = model.readerID {
                ReaderView(documentID: id)
                    .id(id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                            removal: .scale(scale: 0.96).combined(with: .opacity)))
            }

            TopBar()

            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .overlay(Text("Loslassen, um zu importieren").font(.headline))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .animation(.spring(duration: 0.35, bounce: 0.12), value: model.readerID)
        .overlay(alignment: .bottom) { ToastView() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onChange(of: model.readerID) { gridFocused = true }
        .onKeyPress(.space) { toggleReader() }
        .onKeyPress(.return) { toggleReader() }
        .onKeyPress(.escape) {
            if model.readerID != nil { model.readerID = nil; return .handled }
            if model.selection != nil { model.selection = nil; return .handled }
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
        .task(id: model.search) {
            // Tipp-Pausen abwarten, damit nicht jede Taste eine Volltextsuche auslöst.
            try? await Task.sleep(for: .milliseconds(model.search.isEmpty ? 0 : 280))
            guard !Task.isCancelled, model.phase == .ready else { return }
            await model.reload()
        }
    }

    private func toggleReader() -> KeyPress.Result {
        if model.readerID != nil {
            model.readerID = nil
        } else if model.selection != nil {
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
                    .padding(.top, 70)
                    .padding(.bottom, 48)

                    if model.isLoadingPage && !model.documents.isEmpty {
                        ProgressView().controlSize(.small).padding(.bottom, 32)
                    }
                }
                .scrollContentBackground(.hidden)
                .background {
                    // Klick ins Leere hebt die Auswahl auf.
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.selection = nil }
                }
                .overlay { EmptyState() }
                .onChange(of: model.selection) { _, id in
                    guard let id, model.readerID == nil else { return }
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id) }
                }
                .onChange(of: count, initial: true) { _, new in columns = new }
                .onChange(of: model.search) { proxy.scrollTo("top", anchor: .top) }
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
                        .buttonStyle(.bordered)
                        .clipShape(Capsule())
                } else if !model.search.isEmpty {
                    Text("Nichts gefunden für „\(model.search)“").foregroundStyle(.secondary)
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

    private var isSelected: Bool { model.selection == document.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageStack(document: document, box: CGSize(width: width, height: width * 1.9), isSelected: isSelected)
                .onTapGesture {
                    // Doppelklick über den Klickzähler erkennen, damit die Auswahl ohne Verzögerung reagiert.
                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                        model.openReader(document.id)
                    } else {
                        model.selection = document.id
                    }
                }
                .contextMenu {
                    Button("Lesen") { model.openReader(document.id) }
                    Button("Teilen …") { model.selection = document.id; Task { await model.share() } }
                    Button("Exportieren …") { model.selection = document.id; Task { await model.export() } }
                    Divider()
                    if let url = model.client?.webURL(for: document.id) {
                        Button("In Paperless öffnen") { NSWorkspace.shared.open(url) }
                    }
                }

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
                    pills
                        .padding(.top, 1)
                }
                .padding(.top, 12)
            }
        }
        .frame(width: width, alignment: .leading)
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
            }
            .contentShape(Rectangle())
        }
        .frame(width: box.width, height: box.height, alignment: .bottomLeading)
        .animation(.smooth(duration: 0.2), value: isSelected)
        .task(id: document.id) {
            guard let client = model.client else { return }
            image = await model.thumbnails.image(for: document.id, client: client)
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

// MARK: - Obere Leiste

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            WindowDragArea()

            if let doc = model.document(model.readerID) {
                VStack(spacing: 1) {
                    Text(doc.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let date = doc.createdDate {
                        Text(date, format: .dateTime.day(.twoDigits).month(.twoDigits).year())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 420)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                Spacer()
                if model.phase == .ready {
                    SearchControl()
                    HStack(spacing: 0) {
                        BarButton(symbol: "plus", help: "Importieren") { model.importFiles() }
                        BarButton(symbol: "square.and.arrow.up", help: "Teilen") { Task { await model.share() } }
                            .disabled(model.actionTarget == nil)
                        BarButton(symbol: "square.and.arrow.down", help: "Exportieren") { Task { await model.export() } }
                            .disabled(model.actionTarget == nil)
                    }
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.trailing, 14)
        }
        .frame(height: 52)
        .background(alignment: .top) {
            // Weicher Übergang, damit Seiten beim Scrollen unter der Leiste verschwinden.
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .windowBackgroundColor).opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .allowsHitTesting(false)
        }
    }
}

struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .help(help)
    }
}

struct SearchControl: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        Group {
            if expanded {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Suchen", text: $model.search)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit {
                            if let first = model.documents.first { model.openReader(first.id) }
                            focused = false
                        }
                        .onExitCommand { close() }
                    if !model.search.isEmpty {
                        Button { model.search = ""; focused = true } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .frame(width: 270, height: 36)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .background(.regularMaterial, in: Capsule())
                .overlay(alignment: .topLeading) { suggestions }
                .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
            } else {
                Button { open() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Suchen (⌘F)")
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: expanded)
        .onChange(of: model.searchFocusRequest) { open() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && model.search.isEmpty { expanded = false }
        }
    }

    @ViewBuilder private var suggestions: some View {
        if focused, !model.search.isEmpty, !model.documents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.documents.prefix(6)) { doc in
                    Button {
                        model.openReader(doc.id)
                        focused = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(doc.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SuggestionStyle())
                }
            }
            .padding(5)
            .frame(width: 270, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .offset(y: 42)
        }
    }

    private func open() {
        expanded = true
        focused = true
    }

    private func close() {
        model.search = ""
        focused = false
        expanded = false
    }
}

private struct SuggestionStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.toast {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { model.toast = nil }
                }
        }
    }
}
