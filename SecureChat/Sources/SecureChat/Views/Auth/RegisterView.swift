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
                    Text("Your encryption keys are generated on this device and never leave it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 24)

                // FIX (Bug #6): password + confirmation fields removed.
                TextField("Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Protected by Face ID or your passcode", systemImage: "faceid")
                        .font(.footnote.bold())
                    Text("SecureChat doesn't use a password. Your message history is encrypted with a key held in this device's Secure Keychain, released only when you authenticate. Because that key can't leave the device, signing in elsewhere won't recover your history.")
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
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Create Account")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmitRegister)
            }
            .padding()
        }
    }
}
