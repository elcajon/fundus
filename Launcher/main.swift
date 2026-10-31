// Fundus login item: starts the app silently (without a window), like 1Password's launcher.
// Lives in Fundus.app/Contents/Library/LoginItems/FundusLauncher.app.
import AppKit

let mainApp = Bundle.main.bundleURL
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // Fundus.app

if NSRunningApplication.runningApplications(withBundleIdentifier: "de.max-venz.ablage").isEmpty {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = ["--silent"]
    configuration.activates = false
    configuration.addsToRecentItems = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: mainApp, configuration: configuration) { _, error in
        if let error { FileHandle.standardError.write(Data("Ablage nicht gestartet: \(error)\n".utf8)) }
        done.signal()
    }
    done.wait()
}
