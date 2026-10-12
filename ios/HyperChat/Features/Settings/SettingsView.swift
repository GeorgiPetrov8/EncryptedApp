import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var showDeleteConfirmation = false
    @State private var appearanceScope: AppearanceScope?
    @State private var selectedAvatar: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var offerLocalOnlyDeletion = false

    var body: some View {
        Form {
            profileSection
            notificationsSection
            accountSection
            appearanceSection
            privacySection
            alarmsSection
            syncSection
            appLockSection
            dangerSection

            if let errorMessage {
                ThemedSection {
                    StatusText(errorMessage, .error)
                }
            }
        }
        .navigationTitle("Settings")
        .appScreenStyle()
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
            Button("Delete Everything", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your keys and message history will be erased from this device. Without a backup they cannot be restored.")
        }
        .alert("Couldn't reach the server", isPresented: $offerLocalOnlyDeletion) {
            Button("Delete from this device only", role: .destructive) {
                deleteAccount(includeServer: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account will stay on the server, and your username stays taken. Try again when you're online to remove it completely.")
        }
    }

    // MARK: Profile

    private var profileSection: some View {
        ThemedSection {
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
                        ThemedRowButton(title: "Remove photo", isDestructive: true) {
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

    // MARK: Notifications

    private var notificationsSection: some View {
        ThemedSection {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                HStack {
                    Label("Notifications (ntfy)", systemImage: "bell.badge")
                    Spacer()
                    Text(container.ntfyService.isEnabled ? "On" : "Off")
                        .themedSecondary()
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get a “New message” notification when HyperChat is closed, through the free ntfy app.")
        }
    }

    // MARK: Account

    private var accountSection: some View {
        ThemedSection("Account") {
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
                        // The shape (a "!" in a circle) carries the meaning; the
                        // colour only adds to it on the default look.
                        Image(systemName: "exclamationmark.circle.fill")
                            .themedStatus(.warning)
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
        ThemedSection {
            Button {
                appearanceScope = .chatList
            } label: {
                Label("App background", systemImage: "list.bullet.rectangle")
            }
            Button {
                appearanceScope = .allChats
            } label: {
                Label("Chat background", systemImage: "paintbrush")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("“App background” is used on every screen outside a chat. “Chat background” applies to every chat without its own; set one for a single chat from the ⋯ menu inside it.")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        ThemedSection {
            Toggle("Show when I'm online", isOn: Binding(
                get: { container.presenceService.isSharingPresence },
                set: { container.presenceService.isSharingPresence = $0 }
            ))
            Toggle("Read receipts", isOn: Binding(
                get: { container.receiptService.sendsReadReceipts },
                set: { container.receiptService.sendsReadReceipts = $0 }
            ))
            Toggle("GIFs (\(container.tenorService.providerName))", isOn: Binding(
                get: { container.tenorService.isEnabled },
                set: { container.tenorService.isEnabled = $0 }
            ))
        } header: {
            Text("Privacy")
        } footer: {
            Text("Online status is only shown to people you chat with, never as a “last seen” time. Turning read receipts off also hides other people's. GIFs: searching and loading GIFs contacts \(container.tenorService.providerName), which sees your IP address; when off, received GIFs only load when you tap them.")
        }
    }

    // MARK: Other sections

    private var alarmsSection: some View {
        ThemedSection {
            NavigationLink {
                AlarmListView()
            } label: {
                HStack {
                    Label("Alarms", systemImage: "alarm.fill")
                    Spacer()
                    if container.alarmService.enabledCount > 0 {
                        Text("\(container.alarmService.enabledCount) on")
                            .themedSecondary()
                    }
                }
            }
        }
    }

    private var syncSection: some View {
        ThemedSection("Sync") {
            LabeledContent("Connection") {
                Text(container.messagingService.isListening ? "Connected" : "Not connected")
                    .themedStatus(container.messagingService.isListening ? .success : .warning)
            }
            if !container.messagingService.isListening {
                Button("Reconnect") {
                    container.messagingService.startListening()
                }
            }
        }
    }

    private var appLockSection: some View {
        ThemedSection("App Lock") {
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
        ThemedSection {
            ThemedRowButton(title: "Delete Account and All Data", isDestructive: true) {
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

    private func deleteAccount(includeServer: Bool = true) {
        guard let userId = container.authService.currentUserId else { return }
        Task {
            do {
                try await container.accountDeletionService.deleteAccount(userId: userId, includeServer: includeServer)
                container.messagingService.stopListening()
                container.presenceService.stop()
                container.alarmService.stopForLogout()
                container.profileService.deleteLocalData(ownerUserId: userId)
                container.authService.logout()
            } catch AccountDeletionError.serverUnreachable {
                offerLocalOnlyDeletion = true
            } catch {
                errorMessage = "Couldn't delete the account: \(error.localizedDescription)"
            }
        }
    }
}
