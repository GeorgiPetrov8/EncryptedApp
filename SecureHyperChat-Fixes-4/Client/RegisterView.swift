import SwiftUI

struct RegisterView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("Create your account")
                        .font(.title.bold())
                    Text("Your encryption keys are generated on this device and never leave it — except inside a backup file you create and protect with your own password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                TextField("Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                // FIX (S43): says what actually happens. Only the key that encrypts
                // the stored history needs Face ID / passcode; the identity keys are
                // protected by the device lock. History CAN be moved to a new phone,
                // but only with a backup file (Settings → Account recovery).
                VStack(alignment: .leading, spacing: 6) {
                    Label("No password", systemImage: "faceid")
                        .font(.footnote.bold())
                    Text("SecureHyperChat doesn't use a password. Your stored messages are encrypted with a key that only unlocks with Face ID or your passcode. To move your account and history to another phone, export a backup file from Settings → Account recovery — without one, a lost phone means lost history.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await viewModel.register() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Create Account").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmitRegister)
            }
            .padding()
        }
    }
}
