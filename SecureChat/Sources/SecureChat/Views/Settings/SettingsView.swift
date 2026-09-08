import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Account") {
                if let username = container.authService.currentUsername {
                    LabeledContent("Username", value: username)
                }
                Button("Log Out") {
                    // The listener stop and media-cache clear happen in the logout
                    // handler wired up by AppContainer (Bugs #23, #25).
                    container.authService.logout()
                }
            }

            Section {
                LabeledContent("Connection") {
                    Text(container.messagingService.isListening ? "Connected" : "Not connected")
                        .foregroundStyle(container.messagingService.isListening ? .green : .orange)
                }
                if !container.messagingService.isListening {
                    // FIX (Bug #25): a manual recovery path, now that the state is
                    // actually observable.
                    Button("Reconnect") {
                        container.messagingService.startListening()
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("SecureChat downloads anything sent while you were offline the next time it connects.")
            }

            Section {
                Toggle("Require Face ID / passcode", isOn: Binding(
                    get: { container.appLockService.isEnabled },
                    set: { container.appLockService.isEnabled = $0 }
                ))
                if container.appLockService.isEnabled {
                    Stepper(
                        "Auto-lock after \(Int(container.appLockService.autoLockMinutes)) min",
                        value: Binding(
                            get: { container.appLockService.autoLockMinutes },
                            set: { container.appLockService.autoLockMinutes = $0 }
                        ),
                        in: 0...30
                    )
                }
            } header: {
                Text("App Lock")
            } footer: {
                // FIX (Bug #6): with the password removed, this is the honest
                // description of what actually protects local data.
                Text("SecureChat has no password. Your message history is encrypted with a key held in this device's Keychain and released only after you authenticate. The conversation is also hidden in the app switcher.")
            }

            // Deletion is explicit, isolated, and clearly labelled (Bug #10).
            Section {
                Button("Delete Account and All Data", role: .destructive) {
                    showDeleteConfirmation = true
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Permanently removes this account's keys, conversations, messages, and cached attachments from this device. This cannot be undone.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                Text("This is a scaffold build. Media auto-delete timers, disappearing messages, and group chats aren't wired into the UI yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Delete this account and all its data?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive, action: deleteAccount)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your keys and message history will be erased from this device and cannot be restored.")
        }
    }

    private func deleteAccount() {
        guard let userId = container.authService.currentUserId else { return }
        do {
            container.messagingService.stopListening()
            try container.accountDeletionService.deleteAccount(userId: userId)
            container.authService.logout()
        } catch {
            errorMessage = "Couldn't delete the account: \(error.localizedDescription)"
        }
    }
}
