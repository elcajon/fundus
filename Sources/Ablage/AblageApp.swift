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
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neu laden") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                    .disabled(model.phase != .ready)
            }
        }

        WindowGroup("Dokument", for: Int.self) { $id in
            if let id {
                ReaderView(documentID: id)
                    .environment(model)
            }
        }
        .defaultSize(width: 760, height: 980)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Als SwiftPM-Binary ohne Xcode-Bundle-Magie explizit in den Vordergrund.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
        .sheet(isPresented: $model.showLogin) {
            PangolinLoginSheet()
                .environment(model)
        }
    }
}
