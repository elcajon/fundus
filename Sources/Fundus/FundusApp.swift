import AppKit
import CoreSpotlight
import ServiceManagement
import SwiftUI

@main
struct FundusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @AppStorage(AppSettings.menuBarKey) private var showMenuBar = true

    var body: some Scene {
        // A single main window: openWindow brings it to the front instead of opening a second one.
        Window("Fundus", id: "library") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 860)
        // In menu bar mode the window doesn't open at launch.
        .defaultLaunchBehavior(AppSettings.startsInMenuBar ? .suppressed : .automatic)
        .commands { FundusCommands(model: model) }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct FundusCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appTermination) {
            Button("Fundus vollständig beenden") { AppSettings.quit() }
        }
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
            Divider()
            Toggle("Als Galerie", isOn: Binding(get: { model.layout == .grid }, set: { if $0 { model.layout = .grid } }))
                .keyboardShortcut("1")
            Toggle("Als Liste", isOn: Binding(get: { model.layout == .list }, set: { if $0 { model.layout = .list } }))
                .keyboardShortcut("2")
            SortMenu(model: model)
            GroupingPicker(model: model)
                .disabled(model.layout != .list)
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

/// Menu bar icon. It is always there and therefore provides the action to open the main
/// window, even without an open window.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let icon = Appearance.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "doc.text")
            }
        }
        .onAppear { model.registerWindowOpener { openWindow(id: "library") } }
    }
}

enum AppSettings {
    static let menuBarKey = "showMenuBar"
    static let hideDockKey = "hideDockIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarKey: true,
            hideDockKey: true,
            QuickSearchController.enabledKey: true,
            SpotlightIndexer.enabledKey: true,
        ])
        NewDocumentWatcher.registerDefaults()
    }

    /// Menu bar only: no Dock icon, the window opens from the menu bar icon.
    static var menuBarOnly: Bool {
        UserDefaults.standard.bool(forKey: hideDockKey) && UserDefaults.standard.bool(forKey: menuBarKey)
    }

    /// Started by the login item: silently, without a window and Dock icon.
    static let launchedSilently = CommandLine.arguments.contains("--silent")

    /// Launch without a window, provided a server is already set up.
    static var startsInMenuBar: Bool {
        registerDefaults()
        return (menuBarOnly || launchedSilently) && UserDefaults.standard.string(forKey: "serverURL") != nil
    }

    @MainActor static func applyLaunchPolicy() {
        NSApp.setActivationPolicy(menuBarOnly || startsInMenuBar ? .accessory : .regular)
    }

    /// With a menu bar icon, ⌘Q doesn't quit the app but retreats it into the menu bar.
    static var keepsRunningInMenuBar: Bool {
        UserDefaults.standard.bool(forKey: menuBarKey)
    }

    @MainActor static func applyDockPolicy() {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }

    /// Show the Dock icon as soon as a window opens (except in menu-bar-only mode).
    @MainActor static func showInDock() {
        applyDockPolicy()
    }

    /// Close windows and hide the Dock icon; the app keeps running in the menu bar.
    @MainActor static func retreatToMenuBar() {
        for window in NSApp.windows where window.isVisible && window.canBecomeMain && !(window is NSPanel) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    /// Really quit, e.g. from the menu bar menu.
    @MainActor static func quit() {
        AppDelegate.quitRequested = true
        NSApp.terminate(nil)
    }

    /// The login item is the helper app in the bundle; it starts Fundus with `--silent`.
    static let launcher = SMAppService.loginItem(identifier: "de.max-venz.ablage.launcher")

    static var launchesAtLogin: Bool {
        launcher.status == .enabled || SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try launcher.register()
            try? SMAppService.mainApp.unregister()
        } else {
            try? launcher.unregister()
            try? SMAppService.mainApp.unregister()
        }
    }

    /// Earlier versions registered the app itself; switch over to the helper app.
    static func migrateLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try launcher.register()
            try SMAppService.mainApp.unregister()
            Log.app.info("Anmeldeobjekt auf die Hilfs-App umgestellt")
        } catch {
            Log.app.error("Anmeldeobjekt nicht umgestellt: \(String(describing: error), privacy: .public)")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel { .shared }
    private var appearanceObserver: NSKeyValueObservation?
    static var quitRequested = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        TempFiles.cleanUp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyLaunchPolicy()
        if !AppSettings.startsInMenuBar { NSApp.activate(ignoringOtherApps: true) }
        AppSettings.migrateLoginItem()
        // The watcher is also the notification center's delegate. It has to exist at launch, otherwise
        // a click on a notification that launched Fundus gets lost.
        _ = model.watcher
        QuickSearchController.shared.applySetting()
        Appearance.apply(UserDefaults.standard.string(forKey: Appearance.key))
        Appearance.applyIcon()
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { Appearance.applyIcon() }
        }
    }

    /// ⌘Q retreats the app into the menu bar. It quits via the menu bar menu,
    /// “Quit Fundus completely” or when the system asks (log out, shut down, Dock, AppleScript).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitRequested || !AppSettings.keepsRunningInMenuBar {
            return .terminateNow
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication {
            return .terminateNow
        }
        AppSettings.retreatToMenuBar()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempFiles.cleanUp()
    }

    /// With notifications or the menu bar icon enabled, the app keeps running without a window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: NewDocumentWatcher.enabledKey) && !defaults.bool(forKey: AppSettings.menuBarKey)
    }

    /// Reopening (Finder, Spotlight app hit) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { model.showMainWindow() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model.handle(url: url) }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let id = SpotlightIndexer.documentID(from: identifier) else { return false }
        Task { @MainActor in await self.model.open(documentID: id) }
        return true
    }
}

enum Appearance {
    static let key = "appearance"

    /// Custom menu bar icon; as a template, macOS tints it light or dark.
    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    /// `.icns` has no light and dark variants. The Dock icon of the running app can be swapped,
    /// though; in Finder it stays the light version.
    @MainActor static func applyIcon() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard isDark, let url = Bundle.main.url(forResource: "AppIconDark", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            NSApp.applicationIconImage = nil
            return
        }
        NSApp.applicationIconImage = image
    }

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
            // So notifications, Spotlight and the menu bar can open the window when it is closed.
            model.registerWindowOpener { openWindow(id: "library") }
        }
        .sheet(isPresented: $model.showLogin) {
            PangolinLoginSheet()
                .environment(model)
        }
    }
}
