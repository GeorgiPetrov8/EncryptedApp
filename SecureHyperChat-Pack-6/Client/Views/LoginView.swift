import SwiftUI

struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel
    @EnvironmentObject private var container: AppContainer
    @State private var showRestore = false
    @State private var switchingTo: String?
    @State private var switchError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                    Text("SecureHyperChat")
                        .font(.largeTitle.bold())
                    Text("End-to-end encrypted messaging")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                // NEW (R8): one tap for accounts already on this phone.
                if !container.authService.localAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Accounts on this phone")
                            .font(.footnote.bold())
                            .foregroundStyle(.secondary)
                        ForEach(container.authService.localAccounts) { account in
                            Button {
                                switchTo(account)
                            } label: {
                                HStack {
                                    AvatarView(userId: account.userId, displayName: account.username, imageData: nil, size: 32)
                                    Text(account.username).font(.body.weight(.medium))
                                    Spacer()
                                    if switchingTo == account.userId { ProgressView() }
                                    else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                }
                                .padding(10)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(switchingTo != nil)
                        }
                        if let switchError {
                            Text(switchError).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    Text("or sign in to another account")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TextField("Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                // FIX (S43): accurate. Signing in works only on a phone that has
                // this account's keys; another phone needs a backup file.
                Text("No password: signing in proves this phone holds the account's keys. On a new phone, use “Restore account” with your backup file — without it the account and its history can't be moved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await viewModel.login() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Log In").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmitLogin)

                Button("Restore account") { showRestore = true }
                    .sheet(isPresented: $showRestore) {
                        RestoreAccountView().environmentObject(container)
                    }
            }
            .padding()
        }
        .onAppear { container.authService.refreshLocalAccounts() }
    }

    private func switchTo(_ account: LocalAccount) {
        switchError = nil
        switchingTo = account.userId
        Task {
            defer { switchingTo = nil }
            do {
                try await container.authService.switchAccount(to: account.userId)
            } catch {
                switchError = error.localizedDescription
            }
        }
    }
}
