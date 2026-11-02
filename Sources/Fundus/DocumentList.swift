import SwiftUI

/// Finder-style list: one row per document, sortable columns and optional sections.
/// Paperless does the sorting, so the column headers sort the whole library, not just the loaded rows.
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("listColumns") private var columns = TableColumnCustomization<Document>()
    var focus: FocusState<ContentFocus?>.Binding

    var body: some View {
        ScrollViewReader { proxy in
            Table(of: Document.self, selection: selection, sortOrder: sortOrder, columnCustomization: $columns) {
                TableColumn("Titel", sortUsing: DocumentComparator(.title)) { doc in
                    TitleCell(model: model, document: doc)
                        .onAppear {
                            if doc.id == model.documents.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                }
                .width(min: 160, ideal: 320)
                .customizationID("title")
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Datum", sortUsing: DocumentComparator(.created)) { doc in
                    Text(doc.createdDate?.formatted(date: .numeric, time: .omitted) ?? "")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                .customizationID("created")

                TableColumn("Korrespondent", sortUsing: DocumentComparator(.correspondent)) { doc in
                    Text(model.correspondentName(doc.correspondent) ?? "")
                }
                .width(min: 80, ideal: 150)
                .customizationID("correspondent")

                TableColumn("Dokumenttyp", sortUsing: DocumentComparator(.documentType)) { doc in
                    Text(model.typeName(doc.documentType) ?? "")
                }
                .width(min: 80, ideal: 130)
                .customizationID("documentType")

                TableColumn("Tags") { doc in
                    TagsCell(model: model, document: doc)
                }
                .width(min: 80, ideal: 200)
                .customizationID("tags")

                TableColumn("Hinzugefügt", sortUsing: DocumentComparator(.added)) { doc in
                    Text(doc.addedDate?.formatted(date: .numeric, time: .omitted) ?? "")
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                .customizationID("added")
            } rows: {
                let query = model.query
                if query.grouping == .none {
                    ForEach(model.documents) { doc in row(doc) }
                } else {
                    ForEach(query.groups(model.documents)) { group in
                        Section {
                            ForEach(group.documents) { doc in row(doc) }
                        } header: {
                            Text(title(of: group, in: query.grouping))
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                if let id = model.focusedID.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first {
                    model.openReader(id)
                }
            }
            .focused(focus, equals: .list)
            // The table moves the selection with the arrow keys itself; these keys do what they do in the grid.
            .onKeyPress(.space) { open() }
            .onKeyPress(.return) { open() }
            .onKeyPress(.escape) {
                guard !model.selectedIDs.isEmpty else { return .ignored }
                model.select(nil)
                return .handled
            }
            .overlay { EmptyState() }
            .onChange(of: model.focusedID) { _, id in
                // Keep the focused row visible when it changes from outside, e.g. ←/→ while reading.
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func open() -> KeyPress.Result {
        guard model.focusedID != nil else { return .ignored }
        model.openReader()
        return .handled
    }

    private func row(_ doc: Document) -> some TableRowContent<Document> {
        TableRow(doc)
            .itemProvider { model.dragProvider(for: doc) }
    }

    @ViewBuilder private func menu(for ids: Set<Int>) -> some View {
        if ids.count == 1, let doc = model.document(ids.first) {
            DocumentMenu(model: model, document: doc)
        } else if !ids.isEmpty {
            Button("Teilen …") {
                model.selectedIDs = ids
                Task { await model.share() }
            }
            Button("Exportieren …") {
                model.selectedIDs = ids
                Task { await model.export() }
            }
        }
    }

    /// The table's selection is the model's. The focused document follows the last added row.
    private var selection: Binding<Set<Int>> {
        Binding {
            model.selectedIDs
        } set: { ids in
            let added = ids.subtracting(model.selectedIDs)
            model.selectedIDs = ids
            if added.count == 1 {
                model.focusedID = added.first
            } else if !(model.focusedID.map(ids.contains) ?? false) {
                model.focusedID = model.documents.first { ids.contains($0.id) }?.id
            }
        }
    }

    /// No sort while a full-text search is ordered by relevance: no header shows an arrow then.
    private var sortOrder: Binding<[DocumentComparator]> {
        Binding {
            model.currentSort.map { [DocumentComparator(sort: $0)] } ?? []
        } set: { order in
            model.currentSort = order.first?.sort
        }
    }

    private func title(of group: DocumentGroup, in grouping: DocumentGrouping) -> String {
        switch grouping {
        case .none:
            return ""
        case .correspondent:
            return model.correspondentName(group.key) ?? String(localized: "Ohne Korrespondent")
        case .documentType:
            return model.typeName(group.key) ?? String(localized: "Ohne Dokumenttyp")
        case .year:
            return group.key.map(String.init) ?? String(localized: "Ohne Datum")
        case .month:
            guard let key = group.key,
                  let date = Calendar.current.date(from: DateComponents(year: key / 100, month: key % 100)) else {
                return String(localized: "Ohne Datum")
            }
            return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

/// Group-by choice for the toolbar and the View menu. Menus get the model passed in: neither the
/// View menu nor a toolbar menu sees the window's environment.
struct GroupingPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("Gruppieren nach", selection: $model.grouping) {
            Text("Nicht gruppieren").tag(DocumentGrouping.none)
            Divider()
            Text("Korrespondent").tag(DocumentGrouping.correspondent)
            Text("Dokumenttyp").tag(DocumentGrouping.documentType)
            Text("Jahr").tag(DocumentGrouping.year)
            Text("Monat").tag(DocumentGrouping.month)
        }
    }
}

/// Sort field and direction for the View menu; the list also sorts by its column headers.
struct SortMenu: View {
    let model: AppModel

    var body: some View {
        Menu("Sortieren nach") {
            Picker("Sortieren nach", selection: field) {
                if model.currentSort == nil {
                    Text("Relevanz").tag(SortField?.none)
                }
                Text("Titel").tag(SortField?.some(.title))
                Text("Dokumentdatum").tag(SortField?.some(.created))
                Text("Hinzugefügt").tag(SortField?.some(.added))
                Text("Korrespondent").tag(SortField?.some(.correspondent))
                Text("Dokumenttyp").tag(SortField?.some(.documentType))
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Reihenfolge", selection: ascending) {
                Text("Aufsteigend").tag(true)
                Text("Absteigend").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(model.currentSort == nil)
        }
    }

    private var field: Binding<SortField?> {
        Binding {
            model.currentSort?.field
        } set: { field in
            model.currentSort = field.map { DocumentSort($0) }
        }
    }

    private var ascending: Binding<Bool> {
        Binding {
            model.currentSort?.ascending ?? false
        } set: { ascending in
            if let field = model.currentSort?.field { model.currentSort = DocumentSort(field, ascending: ascending) }
        }
    }
}

/// Which part of the window has the keyboard: the window itself (grid, reading mode) or the list.
enum ContentFocus: Hashable {
    case window
    case list
}

/// Column sort for `Table`. Paperless sorts the rows; `compare` only exists for the protocol.
struct DocumentComparator: SortComparator {
    var field: SortField
    var order: SortOrder

    init(_ field: SortField) {
        self.field = field
        order = field.ascendingByDefault ? .forward : .reverse
    }

    init(sort: DocumentSort) {
        field = sort.field
        order = sort.ascending ? .forward : .reverse
    }

    var sort: DocumentSort { DocumentSort(field, ascending: order == .forward) }

    func compare(_ a: Document, _ b: Document) -> ComparisonResult {
        let before = DocumentQuery.comparator([sort]) { _, _ in nil }
        return before(a, b) ? .orderedAscending : before(b, a) ? .orderedDescending : .orderedSame
    }
}

/// Table cells and menus get the model passed in: they are hosted outside the window's environment.
private struct TitleCell: View {
    let model: AppModel
    let document: Document
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.3), radius: 0.5, y: 0.5)
                } else {
                    Rectangle().fill(Color.primary.opacity(0.08))
                        .aspectRatio(1 / 1.414, contentMode: .fit)
                }
            }
            .frame(width: 16, height: 20)
            .overlay(alignment: .topTrailing) {
                if model.isInInbox(document) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                        .help("Im Eingang")
                }
            }
            Text(document.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .task(id: document.id) {
            image = await model.thumbnails.image(for: document.id, client: model.client)
        }
    }
}

private struct TagsCell: View {
    let model: AppModel
    let document: Document

    var body: some View {
        HStack(spacing: 4) {
            ForEach(document.tags.compactMap(model.tag)) { tag in
                Pill(text: tag.name, fill: Color(hex: tag.color), foreground: Color(hex: tag.textColor))
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .help(document.tags.compactMap { model.tag($0)?.name }.joined(separator: ", "))
    }
}
