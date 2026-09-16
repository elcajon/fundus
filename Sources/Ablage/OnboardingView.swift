import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var server = "paperless.example.com"
    @State private var token = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Ablage")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                Text("Dein Paperless-Archiv, auch hinter Pangolin.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Server", text: $server, prompt: Text("paperless.example.com"))
                SecureField("API-Token (optional)", text: $token, prompt: Text("wird nach dem Login übernommen"))
            }
            .formStyle(.grouped)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)

            Text("Steht Paperless hinter Pangolin, öffnet sich nach dem Verbinden ein Anmeldefenster. Der API-Token aus deinem Paperless-Profil wird danach automatisch übernommen, falls es einen gibt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 400)

            if case let .failed(message) = model.phase {
                Text(message).foregroundStyle(.red).font(.callout)
            }

            Button {
                busy = true
                Task {
                    await model.configure(server: server, apiToken: token)
                    busy = false
                }
            } label: {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text("Verbinden")
                }
                .frame(width: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(server.isEmpty || busy)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
