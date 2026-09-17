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
                Toggle("Schnellsuche aus jeder App", isOn: $quickSearch)
                LabeledContent("Kurzbefehl") { ShortcutRecorder() }
                    .disabled(!quickSearch)
                if quickSearch, QuickSearchController.shared.registrationFailed {
                    Text("Diesen Kurzbefehl belegt schon eine andere App.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Programm")
            } footer: {
                Text("Mit Menüleisten-Symbol läuft Fundus weiter: ⌘Q schließt nur die Fenster und blendet das Dock-Symbol aus, „Fundus beenden“ im Menüleisten-Menü beendet die App. Nur in der Menüleiste startet Fundus ohne Fenster und ohne Dock-Symbol, beim Anmelden immer. Die Schnellsuche öffnet sich mit ihrem Kurzbefehl aus jeder App und zeigt den Treffer in Fundus. Für den Start beim Anmelden sollte die App im Ordner „Programme“ liegen.").settingsFooter()
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
                Text("Funktioniert, solange Fundus läuft.").settingsFooter()
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
                Text("Titel, Text und Tags werden an Spotlight gemeldet. Ein Treffer öffnet das Dokument in Fundus.").settingsFooter()
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
                Text("Fundus hält Titel, Text und Vorschaubilder aller Dokumente sowie zuletzt geöffnete Dokumente lokal vor. Ohne Verbindung lassen sich so die Bibliothek durchsuchen und bereits geöffnete Dokumente lesen.").settingsFooter()
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
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false

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
                TextField("Benutzername", text: $username)
                SecureField("Passwort", text: $password)
                HStack {
                    Button("Anmelden") {
                        isSigningIn = true
                        Task {
                            if await model.signIn(username: username, password: password) {
                                apiToken = model.apiToken
                                password = ""
                            }
                            isSigningIn = false
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSigningIn)
                    if isSigningIn { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Anmeldung")
            } footer: {
                Text("Für Paperless-Konten mit Passwort: Fundus holt sich damit einen API-Token und merkt sich nur diesen. Steht Paperless hinter einem SSO-Zugang wie Pangolin, öffnet sich stattdessen ein Anmeldefenster.").settingsFooter()
            }

            HStack {
                Button("Abmelden") { Task { await model.signOut() } }
                Button("Server entfernen", role: .destructive) { Task { await model.forgetServer() } }
                Spacer()
                Button("Sichern") {
                    model.apiToken = apiToken
                    Task { await model.connect() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            apiToken = model.apiToken
        }
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
