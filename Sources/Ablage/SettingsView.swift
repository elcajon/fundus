import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            ConnectionSettings()
                .tabItem { Label("Verbindung", systemImage: "network") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Appearance.key) private var appearance = "system"
    @AppStorage("showInfo") private var showInfo = true
    @AppStorage("showType") private var showType = false
    @AppStorage("showCorrespondent") private var showCorrespondent = true
    @AppStorage("showTags") private var showTags = true

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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance, initial: false) { _, value in Appearance.apply(value) }
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
            }

            Section {
                SecureField("API-Token", text: $apiToken)
            } header: {
                Text("Paperless")
            } footer: {
                Text("Aus Paperless unter Profil → API-Auth-Token. Wird für Importe gebraucht und im Schlüsselbund gespeichert.").settingsFooter()
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
