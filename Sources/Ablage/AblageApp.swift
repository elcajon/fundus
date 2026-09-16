import AppKit
import SwiftUI

@main
struct AblageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Ablage", id: "library") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands { AblageCommands(model: model) }

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
            Button("Teilen …") { Task { await model.share() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.actionTarget == nil)
            Button("Exportieren …") { Task { await model.export() } }
                .keyboardShortcut("e")
                .disabled(model.actionTarget == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Dokumente durchsuchen") { model.searchFocusRequest += 1 }
                .keyboardShortcut("f")
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Als SwiftPM-Binary ohne Xcode-Bundle-Magie explizit in den Vordergrund.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply(UserDefaults.standard.string(forKey: Appearance.key))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
        .sheet(isPresented: $model.showLogin) {
            PangolinLoginSheet()
                .environment(model)
        }
    }
}

/// Fläche, an der sich das titellose Fenster verschieben lässt.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
