import SwiftUI

/// Benutzerdefinierte Felder eines Dokuments: zugewiesene anzeigen, bearbeiten, entfernen und neue hinzufügen.
struct CustomFieldsSection: View {
    @Environment(AppModel.self) private var model
    let documentID: Int
    @Binding var fields: [CustomFieldInstance]?
    let editable: Bool

    var body: some View {
        if let current = fields {
            if !current.isEmpty || (editable && !model.customFields.isEmpty) {
                Section("Benutzerdefinierte Felder") {
                    ForEach(current.indices, id: \.self) { index in
                        if let definition = model.customField(current[index].field) {
                            CustomFieldRow(definition: definition, value: valueBinding(index), editable: editable) {
                                fields?.remove(at: index)
                            }
                        } else {
                            LabeledContent("Feld \(current[index].field)", value: current[index].value.string ?? "–")
                        }
                    }
                    if editable {
                        addMenu(assigned: Set(current.map(\.field)))
                    }
                }
            }
        } else if model.phase == .ready {
            Section("Benutzerdefinierte Felder") {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Felder werden geladen …").foregroundStyle(.secondary)
                }
            }
            .task(id: documentID) { await model.refreshDocument(documentID) }
        }
    }

    private func valueBinding(_ index: Int) -> Binding<FieldValue> {
        Binding(
            get: { fields.flatMap { $0.indices.contains(index) ? $0[index].value : nil } ?? .null },
            set: { newValue in
                guard fields?.indices.contains(index) == true else { return }
                fields?[index].value = newValue
            }
        )
    }

    private func addMenu(assigned: Set<Int>) -> some View {
        let available = model.customFields.filter { !assigned.contains($0.id) }
        return Menu("Feld hinzufügen") {
            ForEach(available) { definition in
                Button {
                    fields?.append(CustomFieldInstance(field: definition.id, value: .null))
                } label: {
                    Label(definition.name, systemImage: CustomFieldRow.symbol(for: definition.kind))
                }
            }
        }
        .disabled(available.isEmpty)
    }
}

private struct CustomFieldRow: View {
    @Environment(AppModel.self) private var model
    let definition: CustomFieldDefinition
    @Binding var value: FieldValue
    let editable: Bool
    let remove: () -> Void

    static func symbol(for kind: CustomFieldDefinition.Kind?) -> String {
        switch kind {
        case .string, .longtext: "textformat"
        case .url: "link"
        case .date: "calendar"
        case .boolean: "checkmark.square"
        case .integer, .float: "number"
        case .monetary: "eurosign"
        case .documentlink: "doc.on.doc"
        case .select: "list.bullet"
        case nil: "questionmark.square"
        }
    }

    var body: some View {
        HStack(alignment: definition.kind == .longtext || definition.kind == .documentlink ? .top : .center) {
            control
                .disabled(!editable)
            if editable {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Feld entfernen")
                .accessibilityLabel(Text("Feld \(definition.name) entfernen"))
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch definition.kind {
        case .string:
            TextField(definition.name, text: text, prompt: Text("Leer"))
        case .url:
            HStack {
                TextField(definition.name, text: text, prompt: Text("https://…"))
                if let string = value.string, let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square") }
                        .help(string)
                }
            }
        case .longtext:
            VStack(alignment: .leading, spacing: 4) {
                Text(definition.name)
                TextField(definition.name, text: text, prompt: Text("Leer"), axis: .vertical)
                    .lineLimit(2...8)
                    .labelsHidden()
            }
        case .integer:
            TextField(definition.name, value: integer, format: .number.grouping(.never), prompt: Text("Leer"))
        case .float:
            TextField(definition.name, value: double, format: .number, prompt: Text("Leer"))
        case .monetary:
            MonetaryField(definition: definition, value: $value)
        case .boolean:
            Toggle(definition.name, isOn: bool)
        case .date:
            DateField(name: definition.name, value: $value)
        case .select:
            Picker(definition.name, selection: $value) {
                Text("Keine Auswahl").tag(FieldValue.null)
                Divider()
                ForEach(definition.options, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
        case .documentlink:
            DocumentLinksField(name: definition.name, value: $value, editable: editable)
        case nil:
            LabeledContent(definition.name, value: value.string ?? "–")
        }
    }

    private var text: Binding<String> {
        Binding(get: { value.string ?? "" }, set: { value = $0.isEmpty ? .null : .string($0) })
    }

    private var integer: Binding<Int?> {
        Binding(
            get: {
                switch value {
                case let .int(v): v
                case let .double(v): Int(v)
                case let .string(s): Int(s)
                default: nil
                }
            },
            set: { value = $0.map(FieldValue.int) ?? .null }
        )
    }

    private var double: Binding<Double?> {
        Binding(
            get: {
                switch value {
                case let .double(v): v
                case let .int(v): Double(v)
                case let .string(s): Double(s)
                default: nil
                }
            },
            set: { value = $0.map(FieldValue.double) ?? .null }
        )
    }

    private var bool: Binding<Bool> {
        Binding(get: { value == .bool(true) }, set: { value = .bool($0) })
    }
}

private struct DateField: View {
    let name: String
    @Binding var value: FieldValue

    var body: some View {
        if let string = value.string, let date = Document.day(from: string) {
            DatePicker(name, selection: Binding(
                get: { date },
                set: { value = .string(Document.dayFormatter.string(from: $0)) }
            ), displayedComponents: .date)
        } else {
            LabeledContent(name) {
                Button("Datum setzen") { value = .string(Document.dayFormatter.string(from: Date())) }
            }
        }
    }
}

private struct MonetaryField: View {
    let definition: CustomFieldDefinition
    @Binding var value: FieldValue

    private static let common = ["EUR", "USD", "GBP", "CHF"]

    private var parsed: (currency: String?, amount: Decimal?) { Monetary.parse(value) }
    private var currency: String {
        parsed.currency ?? definition.defaultCurrency ?? Locale.current.currency?.identifier ?? "EUR"
    }

    var body: some View {
        LabeledContent(definition.name) {
            HStack(spacing: 6) {
                TextField(definition.name, value: Binding(
                    get: { parsed.amount },
                    set: { value = Monetary.value(currency: currency, amount: $0) }
                ), format: .number.precision(.fractionLength(2)), prompt: Text("0,00"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                Picker("Währung", selection: Binding(
                    get: { currency },
                    set: { value = Monetary.value(currency: $0, amount: parsed.amount) }
                )) {
                    ForEach(Array(Set(Self.common + [currency])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct DocumentLinksField: View {
    @Environment(AppModel.self) private var model
    let name: String
    @Binding var value: FieldValue
    let editable: Bool
    @State private var titles: [Int: String] = [:]
    @State private var showPicker = false

    private var ids: [Int] {
        if case let .ids(list) = value { return list }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 4) {
                    Button(titles[id] ?? "#\(id)") {
                        Task { await model.open(documentID: id) }
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Dokument öffnen")
                    Spacer(minLength: 0)
                    if editable {
                        Button {
                            let remaining = ids.filter { $0 != id }
                            value = remaining.isEmpty ? .null : .ids(remaining)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Verknüpfung entfernen")
                    }
                }
            }
            if editable {
                Button("Dokument verknüpfen …") { showPicker = true }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showPicker, arrowEdge: .leading) {
                        LinkPicker(excluding: Set(ids)) { doc in
                            titles[doc.id] = doc.title
                            value = .ids(ids + [doc.id])
                            showPicker = false
                        }
                        .environment(model)
                    }
            }
        }
        .task(id: ids) { titles.merge(await model.titles(for: ids)) { _, new in new } }
    }
}

private struct LinkPicker: View {
    @Environment(AppModel.self) private var model
    let excluding: Set<Int>
    let choose: (Document) -> Void
    @State private var search = ""
    @State private var results: [Document] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Titel oder Text suchen", text: $search)
                .textFieldStyle(.roundedBorder)
            if results.isEmpty {
                Text(search.isEmpty ? LocalizedStringKey("Suche in der lokalen Kopie.") : LocalizedStringKey("Keine Treffer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(results) { doc in
                    Button {
                        choose(doc)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(doc.title).lineLimit(1)
                            if let date = doc.createdDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 240)
            }
        }
        .padding(12)
        .frame(width: 320)
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            results = await model.linkCandidates(matching: search, excluding: excluding)
        }
    }
}
