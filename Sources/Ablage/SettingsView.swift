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
    @AppStorage(AppSettings.hideDockKey) private var hideDock = false
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
                Toggle("Kein Symbol im Dock", isOn: $hideDock)
                    .disabled(!showMenuBar)
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Programm")
            } footer: {
                Text("Mit Menüleisten-Symbol läuft Ablage nach dem Schließen des Fensters weiter. Für den Start beim Anmelden sollte die App im Ordner „Programme“ liegen.").settingsFooter()
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance, initial: false) { _, value in Appearance.apply(value) }
        .onChange(of: showMenuBar) { AppSettings.applyDockPolicy() }
        .onChange(of: hideDock) { AppSettings.applyDockPolicy() }
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
    @AppStorage("pushServer") private var pushServer = "https://ntfy.sh"
    @AppStorage("pushTopic") private var pushTopic = ""
    @State private var isWorking = false

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
            } header: {
                Text("Auf diesem Mac")
            } footer: {
                Text("Funktioniert, solange Ablage läuft.").settingsFooter()
            }

            Section {
                TextField("ntfy-Server", text: $pushServer, prompt: Text("https://ntfy.sh"))
                HStack {
                    TextField("Thema", text: $pushTopic, prompt: Text("geheimes-thema"))
                    Button("Zufällig") { pushTopic = "ablage-" + UUID().uuidString.lowercased().prefix(18) }
                }
                HStack {
                    Button("In Paperless einrichten") {
                        guard let url = URL(string: pushServer.trimmingCharacters(in: .whitespaces)) else { return }
                        isWorking = true
                        Task {
                            _ = await model.setupPush(server: url, topic: pushTopic)
                            isWorking = false
                        }
                    }
                    .disabled(!model.canEdit || pushTopic.count < 8 || isWorking)
                    Button("Deaktivieren") {
                        isWorking = true
                        Task {
                            await model.disablePush()
                            isWorking = false
                        }
                    }
                    .disabled(!model.canEdit || isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                if let link = URL(string: "ntfy://\(URL(string: pushServer)?.host() ?? "ntfy.sh")/\(pushTopic)"), !pushTopic.isEmpty {
                    LabeledContent("In der ntfy-App abonnieren") {
                        Text(link.absoluteString).textSelection(.enabled).font(.caption.monospaced())
                    }
                }
            } header: {
                Text("Push aufs iPhone (ntfy)")
            } footer: {
                Text("Legt in Paperless den Workflow „\(AppModel.pushWorkflowName)“ an, der bei jedem neuen Dokument Titel und Korrespondent an ntfy schickt. Das kommt auch an, wenn der Mac aus ist. Wer das Thema kennt, liest mit: bei ntfy.sh also ein langes, zufälliges Thema wählen oder einen eigenen ntfy-Server nutzen.").settingsFooter()
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

    var body: some View {
        Form {
            Section {
                Toggle("Dokumente in Spotlight finden", isOn: $spotlight)
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
        .onChange(of: spotlight) { _, enabled in Task { await model.setSpotlight(enabled: enabled) } }
    }

    private func refreshUsage() async {
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
