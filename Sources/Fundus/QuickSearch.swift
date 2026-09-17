import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Schnellsuche als schwebendes Fenster über allen Apps (wie „Quick Access“ bei 1Password).
/// Sucht in der lokalen Kopie und öffnet den Treffer im Fundus-Fenster.
@MainActor
final class QuickSearchController {
    static let shared = QuickSearchController()
    nonisolated static let enabledKey = "quickSearchHotKey"

    /// Konnte der Kurzbefehl nicht angemeldet werden, hat ihn eine andere App belegt.
    private(set) var registrationFailed = false

    private var panel: QuickSearchPanel?
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private let state = QuickSearchState()

    /// Kurzbefehl neu anmelden, z. B. nach einer Änderung in den Einstellungen.
    func applySetting() {
        hotKey?.unregister()
        hotKey = nil
        registrationFailed = false
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let shortcut = Shortcut.current
        hotKey = GlobalHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.toggle()
        }
        registrationFailed = hotKey == nil
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        state.reset()
        resize(rows: 0)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // Fokus erst setzen, wenn das Panel Schlüsselfenster ist.
        DispatchQueue.main.async { self.state.focusRequest += 1 }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func open(_ id: Int) {
        close()
        Task { await AppModel.shared.open(documentID: id) }
    }

    private func makePanel() -> QuickSearchPanel {
        let panel = QuickSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(rows: 0)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: QuickSearchView(
            state: state,
            onResults: { [weak self] count in self?.resize(rows: count) },
            onOpen: { [weak self] id in self?.open(id) },
            onClose: { [weak self] in self?.close() }
        ).environment(AppModel.shared))
        // Die Größe bestimmt der Controller, nicht die ideale Größe der SwiftUI-Ansicht.
        host.sizingOptions = []
        panel.contentView = host
        // Esc schließt, auch wenn das Textfeld die Taste sonst für sich behält.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
            guard event.keyCode == UInt16(kVK_Escape), let panel, panel.isKeyWindow else { return event }
            panel.orderOut(nil)
            return nil
        }
        // Ein Klick daneben schließt die Suche.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        return panel
    }

    nonisolated static let width: CGFloat = 640
    nonisolated static let maxRows = 8
    nonisolated static let rowHeight: CGFloat = 58

    nonisolated static func height(rows: Int) -> CGFloat {
        56 + (rows > 0 ? CGFloat(min(rows, maxRows)) * rowHeight + 12 : 0)
    }

    /// Höhe an die Trefferzahl anpassen, die Oberkante bleibt stehen.
    private func resize(rows: Int) {
        guard let panel else { return }
        let height = Self.height(rows: rows)
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Auf dem Bildschirm mit der Maus, im oberen Drittel.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let top = visible.maxY - visible.height * 0.22
        panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - Self.width / 2, y: top))
    }
}

/// Ein systemweiter Kurzbefehl, wie ihn der Nutzer in den Einstellungen aufnimmt.
struct Shortcut: Equatable {
    /// Virtueller Tastencode (`kVK_…`).
    var keyCode: Int
    /// Carbon-Flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var modifiers: Int

    static let standard = Shortcut(keyCode: kVK_ANSI_A, modifiers: cmdKey | shiftKey)
    static let keyCodeKey = "quickSearchKeyCode"
    static let modifiersKey = "quickSearchModifiers"

    static var current: Shortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else { return standard }
        return Shortcut(keyCode: defaults.integer(forKey: keyCodeKey), modifiers: defaults.integer(forKey: modifiersKey))
    }

    func save() {
        UserDefaults.standard.set(keyCode, forKey: Self.keyCodeKey)
        UserDefaults.standard.set(modifiers, forKey: Self.modifiersKey)
    }

    /// Aus einem Tastendruck, wenn er mindestens eine Befehlstaste enthält.
    init?(event: NSEvent) {
        var carbon = 0
        if event.modifierFlags.contains(.command) { carbon |= cmdKey }
        if event.modifierFlags.contains(.shift) { carbon |= shiftKey }
        if event.modifierFlags.contains(.option) { carbon |= optionKey }
        if event.modifierFlags.contains(.control) { carbon |= controlKey }
        // Ohne ⌘, ⌥ oder ⌃ würde der Kurzbefehl normales Tippen abfangen.
        guard carbon & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: carbon)
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var label: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// Name der Taste, so wie ihn Menüs zeigen.
    static func keyName(_ keyCode: Int) -> String {
        if let special = specialKeys[keyCode] { return special }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Nimmt einen Tastendruck auf und speichert ihn als Kurzbefehl.
struct ShortcutRecorder: View {
    @State private var shortcut = Shortcut.current
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording.toggle()
        } label: {
            Group {
                if recording { Text("Taste drücken …") } else { Text(verbatim: shortcut.label) }
            }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 70)
        }
        .help("Kurzbefehl ändern")
        .accessibilityLabel(Text("Kurzbefehl für die Schnellsuche"))
        .accessibilityValue(Text(shortcut.label))
        .onChange(of: recording) { _, active in
            if active { start() } else { stop() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                recording = false
                return nil
            }
            guard let new = Shortcut(event: event) else { return nil }
            shortcut = new
            new.save()
            recording = false
            QuickSearchController.shared.applySetting()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor @Observable
final class QuickSearchState {
    var text = ""
    var results: [Document] = []
    var selection: Int?
    var focusRequest = 0
    /// Mausposition beim Öffnen: Ein ruhender Zeiger über der Liste soll die Auswahl nicht verschieben.
    @ObservationIgnored var mouseOrigin: NSPoint = .zero

    func reset() {
        mouseOrigin = NSEvent.mouseLocation
        text = ""
        results = []
        selection = nil
    }
}

private struct QuickSearchView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: QuickSearchState
    let onResults: (Int) -> Void
    let onOpen: (Int) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Fundus durchsuchen", text: $state.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                    .onSubmit(openSelection)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .accessibilityLabel(Text("Fundus durchsuchen"))
                if !state.text.isEmpty {
                    Button { state.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Suche leeren")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if !state.results.isEmpty {
                Divider().padding(.horizontal, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(state.results.enumerated()), id: \.element.id) { index, doc in
                                QuickSearchRow(document: doc, selected: state.selection == index)
                                    .id(doc.id)
                                    .onTapGesture { onOpen(doc.id) }
                                    .onHover { inside in
                                        guard inside, NSEvent.mouseLocation != state.mouseOrigin else { return }
                                        state.selection = index
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: state.selection) { _, index in
                        guard let index, state.results.indices.contains(index) else { return }
                        proxy.scrollTo(state.results[index].id)
                    }
                }
            }
        }
        .frame(width: QuickSearchController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 22)
        .ignoresSafeArea()
        .onChange(of: state.focusRequest) {
            focused = false
            DispatchQueue.main.async { focused = true }
        }
        .task(id: state.text) {
            let text = state.text
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                apply([])
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            apply(await model.quickSearch(text))
        }
    }

    private func apply(_ results: [Document]) {
        state.results = results
        state.selection = results.isEmpty ? nil : 0
        onResults(results.count)
    }

    private func move(_ delta: Int) {
        guard !state.results.isEmpty else { return }
        let current = state.selection ?? -1
        state.selection = min(max(current + delta, 0), state.results.count - 1)
    }

    private func openSelection() {
        guard let index = state.selection, state.results.indices.contains(index) else { return }
        onOpen(state.results[index].id)
    }
}

private struct QuickSearchRow: View {
    @Environment(AppModel.self) private var model
    let document: Document
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: QuickSearchController.rowHeight - 2)
        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: document.id) {
            thumbnail = await model.thumbnails.image(for: document.id, client: model.client)
        }
    }

    private var subtitle: String {
        [model.correspondentName(document.correspondent),
         document.createdDate?.formatted(date: .abbreviated, time: .omitted)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
