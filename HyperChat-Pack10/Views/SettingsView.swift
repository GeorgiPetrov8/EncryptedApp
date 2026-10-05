import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var showDeleteConfirmation = false
    @State private var appearanceScope: AppearanceScope?
    @State private var selectedAvatar: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            profileSection
            accountSection
            appearanceSection
            privacySection
            alarmsSection
            syncSection
            appLockSection
            dangerSection

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $appearanceScope) { scope in
            AppearanceSettingsView(scope: scope)
                .environmentObject(container)
        }
        .onChange(of: selectedAvatar) { _, item in
            guard let item else { return }
            Task { await setAvatar(item) }
        }
        .confirmationDialog(
            "Delete this account and all its data?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive, action: deleteAccount)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your keys and message history will be erased from this device. Without a backup they cannot be restored.")
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                AvatarView(
                    userId: container.authService.currentUserId ?? "",
                    displayName: container.authService.currentUsername ?? "?",
                    imageData: myAvatar,
                    size: 72
                )
                .overlay {
                    if container.profileService.isUpdating { ProgressView() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(container.authService.currentUsername ?? "")
                        .font(.headline)
                    PhotosPicker(selection: $selectedAvatar, matching: .images) {
                        Text(myAvatar == nil ? "Add photo" : "Change photo")
                    }
                    .disabled(container.profileService.isUpdating)
                    if myAvatar != nil {
                        Button("Remove photo", role: .destructive) {
                            Task { await container.profileService.removeMyAvatar() }
                        }
                        .font(.footnote)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Profile")
        } footer: {
            Text("Your photo is end-to-end encrypted and only shared with people you chat with.")
        }
    }

    private var myAvatar: Data? {
        _ = container.profileService.version
        return container.profileService.myAvatarData()
    }

    // MARK: Account

    private var accountSection: some View {
        Section("Account") {
            if let username = container.authService.currentUsername {
                LabeledContent("Username", value: username)
            }
            NavigationLink {
                RecoverySettingsView()
            } label: {
                HStack {
                    Label("Account recovery", systemImage: "lifepreserver")
                    Spacer()
                    if container.recoveryService.emailStatus?.verified != true {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Not set up")
                    }
                }
            }
            Button("Log Out") {
                container.authService.logout()
            }
        }
        .task { await container.recoveryService.refreshEmailStatus() }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Button {
                appearanceScope = .chatList
            } label: {
                Label("Chats list background", systemImage: "list.bullet.rectangle")
            }
            Button {
                appearanceScope = .allChats
            } label: {
                Label("Chat background", systemImage: "paintbrush")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("“Chat background” applies to every chat without its own. Set one for a single chat from the ⋯ menu inside it.")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle("Show when I'm online", isOn: Binding(
                get: { container.presenceService.isSharingPresence },
                set: { container.presenceService.isSharingPresence = $0 }
            ))
            Toggle("Read receipts", isOn: Binding(
                get: { container.receiptService.sendsReadReceipts },
                set: { container.receiptService.sendsReadReceipts = $0 }
            ))
        } header: {
            Text("Privacy")
        } footer: {
            Text("Online status is only shown to people you chat with, and never as a “last seen” time. Turning read receipts off also hides other people's read receipts from you.")
        }
    }

    // MARK: Unchanged sections

    private var alarmsSection: some View {
        Section {
            NavigationLink {
                AlarmListView()
            } label: {
                HStack {
                    Label("Alarms", systemImage: "alarm.fill")
                    Spacer()
                    if container.alarmService.enabledCount > 0 {
                        Text("\(container.alarmService.enabledCount) on")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            LabeledContent("Connection") {
                Text(container.messagingService.isListening ? "Connected" : "Not connected")
                    .foregroundStyle(container.messagingService.isListening ? .green : .orange)
            }
            if !container.messagingService.isListening {
                Button("Reconnect") {
                    container.messagingService.startListening()
                }
            }
        }
    }

    private var appLockSection: some View {
        Section("App Lock") {
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
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Delete Account and All Data", role: .destructive) {
                showDeleteConfirmation = true
            }
        } header: {
            Text("Danger Zone")
        }
    }

    // MARK: Actions

    private func setAvatar(_ item: PhotosPickerItem) async {
        defer { selectedAvatar = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            try await container.profileService.setMyAvatar(imageData: data)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't set the photo: \(error.localizedDescription)"
        }
    }

    private func deleteAccount() {
        guard let userId = container.authService.currentUserId else { return }
        do {
            container.messagingService.stopListening()
            container.presenceService.stop()
            container.alarmService.stopForLogout()
            container.profileService.deleteLocalData(ownerUserId: userId)
            container.messagingService.clearPendingHandshakes(ownerUserId: userId)
            try container.accountDeletionService.deleteAccount(userId: userId)
            container.authService.logout()
        } catch {
            errorMessage = "Couldn't delete the account: \(error.localizedDescription)"
        }
    }
}
