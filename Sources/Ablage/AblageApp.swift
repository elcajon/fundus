import AppKit
import CoreSpotlight
import ServiceManagement
import SwiftUI

@main
struct AblageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(AppSettings.menuBarKey) private var showMenuBar = true

    var body: some Scene {
        // Ein einziges Hauptfenster: openWindow holt es nach vorne statt ein zweites zu öffnen.
        Window("Ablage", id: "library") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 480)
                // Links (ablage://) und Spotlight-Treffer nimmt der AppDelegate entgegen.
                .onAppear { appDelegate.model = model }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 860)
        .commands { AblageCommands(model: model) }

        MenuBarExtra("Ablage", systemImage: "doc.on.doc", isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AblageCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Importieren …") { model.importFiles() }
                .keyboardShortcut("o")
                .disabled(model.phase != .ready)
            Button("Importe anzeigen") { model.showImports = true }
                .disabled(model.imports.isEmpty)
            Divider()
            Button("Teilen …") { Task { await model.share() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.actionTargets.isEmpty)
            Button("Exportieren …") { Task { await model.export() } }
                .keyboardShortcut("e")
                .disabled(model.actionTargets.isEmpty)
        }
        CommandMenu("Dokument") {
            Button("Lesen") { model.openReader() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.focusedID == nil || model.readerID != nil)
            Button("Zurück zur Übersicht") { model.readerID = nil }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.readerID == nil)
            Divider()
            Button("Informationen") { model.showInspector.toggle() }
                .keyboardShortcut("i")
            Button("Als erledigt markieren") {
                if let id = model.focusedDocument?.id { Task { await model.markDone(id) } }
            }
            .disabled(!(model.focusedDocument.map(model.isInInbox) ?? false) || !model.canEdit)
            Divider()
            Button("In Paperless öffnen") {
                if let id = model.focusedDocument?.id, let url = model.client?.webURL(for: id) {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model.focusedDocument == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Dokumente durchsuchen") { model.searchFocusRequest += 1 }
                .keyboardShortcut("f")
            Button(model.searchTokens.contains(.inbox) ? LocalizedStringKey("Eingang ausblenden") : LocalizedStringKey("Eingang anzeigen")) {
                model.toggleInbox()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Picker("Sortieren nach", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                Text("Dokumentdatum").tag(DocumentSort.created)
                Text("Hinzugefügt").tag(DocumentSort.added)
            }
            Divider()
            Button("Größere Dokumente") { withAnimation(.smooth) { model.zoomIn() } }
                .keyboardShortcut("+")
            Button("Kleinere Dokumente") { withAnimation(.smooth) { model.zoomOut() } }
                .keyboardShortcut("-")
            Button("Ansicht zurücksetzen") { withAnimation(.smooth) { model.resetView() } }
                .keyboardShortcut("0")
            Divider()
            Button("Dokumente neu laden") { Task { await model.reload() } }
                .keyboardShortcut("r")
                .disabled(model.phase != .ready)
            Divider()
        }
    }
}

enum AppSettings {
    static let menuBarKey = "showMenuBar"
    static let hideDockKey = "hideDockIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarKey: true,
            hideDockKey: false,
            SpotlightIndexer.enabledKey: true,
        ])
        NewDocumentWatcher.registerDefaults()
    }

    /// Ohne Dock-Symbol läuft Ablage wie ein Menüleisten-Programm; Fenster gehen trotzdem auf.
    static func applyDockPolicy() {
        let hide = UserDefaults.standard.bool(forKey: hideDockKey) && UserDefaults.standard.bool(forKey: menuBarKey)
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
    }

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            // Links, die vor dem ersten Fenster kamen, jetzt öffnen.
            guard let model, !pendingURLs.isEmpty else { return }
            for url in pendingURLs { model.handle(url: url) }
            pendingURLs = []
        }
    }
    private var pendingURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        TempFiles.cleanUp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyDockPolicy()
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply(UserDefaults.standard.string(forKey: Appearance.key))
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempFiles.cleanUp()
    }

    /// Mit aktiven Mitteilungen oder Menüleisten-Symbol läuft die App ohne Fenster weiter.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: NewDocumentWatcher.enabledKey) && !defaults.bool(forKey: AppSettings.menuBarKey)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { pendingURLs += urls; return }
        for url in urls { model.handle(url: url) }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = SpotlightIndexer.documentID(from: identifier) else { return false }
        Task { @MainActor in await self.model?.open(documentID: id) }
        return true
    }
}

enum Appearance {
    static let key = "appearance"

    static func apply(_ value: String?) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .unconfigured:
                OnboardingView()
            default:
                LibraryView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Damit Mitteilungen, Spotlight und Menüleiste das Fenster öffnen können, wenn es zu ist.
            model.openMainWindow = { openWindow(id: "library") }
        }
        .sheet(isPresented: $model.showLogin) {
            PangolinLoginSheet()
                .environment(model)
        }
    }
}
