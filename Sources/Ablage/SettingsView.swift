import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiToken = ""
    @State private var pangolinID = ""
    @State private var pangolinSecret = ""

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Adresse", value: model.serverURL?.absoluteString ?? "–")
                LabeledContent("Angemeldet als", value: model.profile?.displayName ?? "–")
            }

            Section {
                SecureField("API-Token", text: $apiToken)
            } header: {
                Text("Paperless")
            } footer: {
                Text("Aus Paperless unter Profil → API-Auth-Token. Wird für Uploads gebraucht und im Schlüsselbund gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Token-ID", text: $pangolinID)
                SecureField("Token", text: $pangolinSecret)
            } header: {
                Text("Pangolin Access Token (optional)")
            } footer: {
                Text("Alternative zum SSO-Login, z. B. wenn der Passkey im Anmeldefenster nicht funktioniert. In Pangolin unter Resource → Share Link anlegen. Die App sendet ihn als P-Access-Token-Id/P-Access-Token-Header.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Sichern & neu verbinden") {
                    model.apiToken = apiToken
                    model.pangolinTokenID = pangolinID
                    model.pangolinToken = pangolinSecret
                    Task { await model.connect() }
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Abmelden") { Task { await model.signOut() } }
                Button("Server entfernen", role: .destructive) { Task { await model.forgetServer() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            apiToken = model.apiToken
            pangolinID = model.pangolinTokenID
            pangolinSecret = model.pangolinToken
        }
    }
}
