import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            NotificationSettings()
                .tabItem { Label("Mitteilungen", systemImage: "bell.badge") }
            LibrarySettings()
                .tabItem { Label("Bibliothek", systemImage: "internaldrive") }
            ConnectionSettings()
                .tabItem { Label("Verbindung", systemImage: "network") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Appearance.key) private var appearance = "system"
    @AppStorage("showInfo") private var showInfo = true
    @AppStorage("showType") private var showType = false
    @AppStorage("showCorrespondent") private var showCorrespondent = true
    @AppStorage("showTags") private var showTags = true
    @AppStorage(AppSettings.menuBarKey) private var showMenuBar = true
    @AppStorage(AppSettings.hideDockKey) private var hideDock = true
    @AppStorage(QuickSearchController.enabledKey) private var quickSearch = true
    @State private var launchAtLogin = AppSettings.launchesAtLogin
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Erscheinungsbild", selection: $appearance) {
                    Text("Automatisch").tag("system")
                    Text("Hell").tag("light")
                    Text("Dunkel").tag("dark")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Automatisch folgt der Einstellung von macOS.").settingsFooter()
            }

            Section {
                Toggle("Dokumentinformationen anzeigen", isOn: $showInfo)
                Group {
                    Toggle("Dokumenttyp", isOn: $showType)
                    Toggle("Korrespondent", isOn: $showCorrespondent)
                    Toggle("Tags", isOn: $showTags)
                }
                .disabled(!showInfo)
                .padding(.leading, 18)
            } header: {
                Text("Dokumentraster")
            } footer: {
                Text("Titel und Datum, dazu wahlweise Typ, Korrespondent und Tags. Leere Werte bleiben ausgeblendet.").settingsFooter()
            }

            Section {
                Toggle("Symbol in der Menüleiste", isOn: $showMenuBar)
                Toggle("Nur in der Menüleiste (kein Dock-Symbol)", isOn: $hideDock)
                    .disabled(!showMenuBar)
                Toggle("Schnellsuche mit \(QuickSearchController.shortcutLabel)", isOn: $quickSearch)
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Programm")
            } footer: {
                Text("Mit Menüleisten-Symbol läuft Ablage weiter: ⌘Q schließt nur die Fenster und blendet das Dock-Symbol aus, „Ablage beenden“ im Menüleisten-Menü beendet die App. Nur in der Menüleiste startet Ablage ohne Fenster und ohne Dock-Symbol, beim Anmelden immer. Die Schnellsuche öffnet sich aus jeder App und zeigt den Treffer in Ablage. Für den Start beim Anmelden sollte die App im Ordner „Programme“ liegen.").settingsFooter()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance, initial: false) { _, value in Appearance.apply(value) }
        .onChange(of: showMenuBar) { AppSettings.showInDock() }
        .onChange(of: hideDock) { AppSettings.showInDock() }
        .onChange(of: quickSearch) { QuickSearchController.shared.applySetting() }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                try AppSettings.setLaunchAtLogin(enabled)
                loginError = nil
            } catch {
                loginError = error.localizedDescription
                launchAtLogin = AppSettings.launchesAtLogin
            }
        }
    }
}

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NewDocumentWatcher.enabledKey) private var notify = true
    @AppStorage(NewDocumentWatcher.intervalKey) private var interval = 120.0

    var body: some View {
        Form {
            Section {
                Toggle("Bei neuen Dokumenten benachrichtigen", isOn: $notify)
                Picker("Nachsehen alle", selection: $interval) {
                    Text("Minute").tag(60.0)
                    Text("2 Minuten").tag(120.0)
                    Text("5 Minuten").tag(300.0)
                    Text("15 Minuten").tag(900.0)
                }
                .disabled(!notify)
            } footer: {
                Text("Funktioniert, solange Ablage läuft.").settingsFooter()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: notify) { model.watcher.start() }
        .onChange(of: interval) { model.watcher.start() }
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = true
    @State private var usage: Int64 = 0
    @State private var indexed: Int?

    var body: some View {
        Form {
            Section {
                Toggle("Dokumente in Spotlight finden", isOn: $spotlight)
                if spotlight, let indexed {
                    LabeledContent("In Spotlight", value: String(localized: "\(indexed) Dokumente"))
                }
            } footer: {
                Text("Titel, Text und Tags werden an Spotlight gemeldet. Ein Treffer öffnet das Dokument in Ablage.").settingsFooter()
            }

            Section {
                LabeledContent("Belegter Speicher", value: usage.formatted(.byteCount(style: .file)))
                LabeledContent("Letzter Abgleich") {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(model.lastSync?.formatted(date: .omitted, time: .shortened) ?? "–")
                    }
                }
                HStack {
                    Button("Jetzt abgleichen") {
                        Task {
                            await model.syncLibrary(forceFull: true)
                            await refreshUsage()
                        }
                    }
                    .disabled(model.phase != .ready || model.isSyncing)
                    Spacer()
                    Button("Lokale Kopie löschen", role: .destructive) {
                        Task {
                            await model.clearOfflineCopy()
                            await refreshUsage()
                        }
                    }
                }
            } header: {
                Text("Offline-Kopie")
            } footer: {
                Text("Ablage hält Titel, Text und Vorschaubilder aller Dokumente sowie zuletzt geöffnete Dokumente lokal vor. Ohne Verbindung lassen sich so die Bibliothek durchsuchen und bereits geöffnete Dokumente lesen.").settingsFooter()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refreshUsage() }
        .onChange(of: spotlight) { _, enabled in
            Task {
                await model.setSpotlight(enabled: enabled)
                indexed = await SpotlightIndexer.count()
            }
        }
    }

    private func refreshUsage() async {
        indexed = await SpotlightIndexer.count()
        usage = await model.store?.diskUsage() ?? 0
    }
}

private struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var apiToken = ""
    @State private var pangolinID = ""
    @State private var pangolinSecret = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Server", value: model.serverURL?.host() ?? "–")
                LabeledContent("Angemeldet als", value: model.profile?.displayName ?? "–")
                if let version = model.client?.serverVersion {
                    LabeledContent("Paperless-Version", value: version)
                }
            }

            Section {
                SecureField("API-Token", text: $apiToken)
            } header: {
                Text("Paperless")
            } footer: {
                Text("Aus Paperless unter Profil → API-Auth-Token. Wird für Importe und Änderungen gebraucht und im Schlüsselbund gespeichert.").settingsFooter()
            }

            Section {
                TextField("Token-ID", text: $pangolinID)
                SecureField("Token", text: $pangolinSecret)
            } header: {
                Text("Pangolin Access Token (optional)")
            } footer: {
                Text("Alternative zum Login-Fenster. In Pangolin unter Resource → Share Link anlegen.").settingsFooter()
            }

            HStack {
                Button("Abmelden") { Task { await model.signOut() } }
                Button("Server entfernen", role: .destructive) { Task { await model.forgetServer() } }
                Spacer()
                Button("Sichern") {
                    model.apiToken = apiToken
                    model.pangolinTokenID = pangolinID
                    model.pangolinToken = pangolinSecret
                    Task { await model.connect() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            apiToken = model.apiToken
            pangolinID = model.pangolinTokenID
            pangolinSecret = model.pangolinToken
        }
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
