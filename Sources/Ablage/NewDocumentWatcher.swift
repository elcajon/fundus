import AppKit
import UserNotifications

/// Fragt Paperless regelmäßig nach neuen Dokumenten und meldet sie als macOS-Mitteilung.
///
/// Neu heißt: eine höhere ID als die höchste bisher gesehene. Der Stand liegt pro Server in den
/// UserDefaults, damit nach einem Neustart nur wirklich Neues gemeldet wird. Beim allerersten Lauf
/// wird nur die Ausgangslage gemerkt, sonst käme eine Mitteilung für jedes vorhandene Dokument.
@MainActor
final class NewDocumentWatcher: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let enabledKey = "notifyNewDocuments"
    nonisolated static let intervalKey = "notifyInterval"

    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var isChecking = false
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        Self.registerDefaults()
    }

    nonisolated static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true, intervalKey: 120.0])
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func start() {
        stop()
        guard isEnabled else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                let interval = max(UserDefaults.standard.double(forKey: Self.intervalKey), 30)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func seenKey(_ client: PaperlessClient) -> String { "lastSeenDocumentID@" + client.baseURL.absoluteString }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let model, model.phase == .ready, let client = model.client else { return }
        let latest: [Document]
        do {
            latest = try await client.latestDocuments()
        } catch ClientError.pangolinLoginRequired {
            // Nicht weiter pollen: jede Runde wäre ein 401 für CrowdSec. Einmal Bescheid geben.
            stop()
            post(id: "session", title: "Ablage",
                 body: String(localized: "Die Pangolin-Anmeldung ist abgelaufen. Öffne Ablage, um dich neu anzumelden."))
            return
        } catch {
            Log.network.error("Nachsehen nach neuen Dokumenten fehlgeschlagen: \(String(describing: error), privacy: .public)")
            return
        }

        let key = seenKey(client)
        let maxID = latest.map(\.id).max() ?? 0
        guard defaults.object(forKey: key) != nil else {
            defaults.set(maxID, forKey: key)
            return
        }
        let lastSeen = defaults.integer(forKey: key)
        let fresh = latest.filter { $0.id > lastSeen }.sorted { $0.id < $1.id }
        guard !fresh.isEmpty else { return }
        defaults.set(maxID, forKey: key)

        model.insertNewDocuments(fresh)
        model.noteNewDocuments(fresh)
        Task { await model.syncLibrary() }

        // Was Ablage selbst importiert hat, meldet schon der Import.
        let foreign = fresh.filter { !model.ownImports.contains($0.id) }
        guard !foreign.isEmpty else { return }
        if foreign.count > 3 {
            post(id: "batch-\(maxID)", title: String(localized: "\(foreign.count) neue Dokumente"),
                 body: foreign.prefix(3).map(\.title).joined(separator: ", ") + " …")
            return
        }
        for doc in foreign {
            let details = [model.correspondentName(doc.correspondent),
                           doc.createdDate?.formatted(date: .abbreviated, time: .omitted)]
                .compactMap { $0 }.joined(separator: " · ")
            let thumb = await thumbnailFile(for: doc, client: client)
            post(id: "doc-\(doc.id)", title: doc.title,
                 body: details.isEmpty ? String(localized: "Neues Dokument") : details,
                 subtitle: String(localized: "Neues Dokument"), documentID: doc.id, attachment: thumb)
        }
    }

    /// Mitteilungs-Anhänge brauchen eine Datei in einem Format, das macOS kennt, also PNG statt WebP.
    private func thumbnailFile(for doc: Document, client: PaperlessClient) async -> URL? {
        guard let model, let image = await model.thumbnails.image(for: doc.id, client: client),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let url = TempFiles.directory.appending(path: "notify-\(doc.id).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func post(id: String, title: String, body: String, subtitle: String? = nil,
                      documentID: Int? = nil, attachment: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        content.sound = .default
        if let documentID { content.userInfo = ["documentID": documentID] }
        if let attachment, let item = try? UNNotificationAttachment(identifier: "thumb", url: attachment) {
            content.attachments = [item]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["documentID"] as? Int
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                self.model?.showMainWindow()
            }
            if let id, let model = self.model { Task { await model.open(documentID: id) } }
        }
    }
}
