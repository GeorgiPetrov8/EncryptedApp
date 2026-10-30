import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var showDeleteConfirmation = false
    @State private var appearanceScope: AppearanceScope?
    @State private var selectedAvatar: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var offerLocalOnlyDeletion = false
    @State private var switching: String?

    var body: some View {
        Form {
            profileSection
            accountsSection
            notificationsSection
            accountSection
            appearanceSection
            privacySection
            blockedSection
            storageSection
            alarmsSection
            connectionSection
            appLockSection
            dangerSection

            if let errorMessage {
                ThemedSection { StatusText(errorMessage, .error) }
            }
        }
        .navigationTitle("Settings")
        .appScreenStyle()
        .sheet(item: $appearanceScope) { scope in
            AppearanceSettingsView(scope: scope).environmentObject(container)
        }
        .onChange(of: selectedAvatar) { _, item in
            guard let item else { return }
            Task { await setAvatar(item) }
        }
        .confirmationDialog("Delete this account and all its data?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your keys and message history will be erased from this device. Without a backup they cannot be restored.")
        }
        .alert("Couldn't reach the server", isPresented: $offerLocalOnlyDeletion) {
            Button("Delete from this device only", role: .destructive) { deleteAccount(includeServer: false) }
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
                .overlay { if container.profileService.isUpdating { ProgressView() } }

                VStack(alignment: .leading, spacing: 8) {
                    Text(container.authService.currentUsername ?? "").font(.headline)
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

    // MARK: Accounts (R8)

    private var accountsSection: some View {
        ThemedSection {
            ForEach(container.authService.localAccounts) { account in
                Button {
                    switchTo(account)
                } label: {
                    HStack {
                        Text(account.username)
                        Spacer()
                        if account.userId == container.authService.currentUserId {
                            Image(systemName: "checkmark")
                        } else if switching == account.userId {
                            ProgressView()
                        }
                    }
                }
                .disabled(account.userId == container.authService.currentUserId || switching != nil)
            }
            Button {
                container.authService.signOutForAnotherAccount()
            } label: {
                Label("Add another account", systemImage: "person.badge.plus")
            }
        } header: {
            Text("Accounts on this phone")
        } footer: {
            Text("Switching keeps the other account signed in — its ntfy notifications keep arriving. Each account has its own keys, chats and settings.")
        }
    }

    private func switchTo(_ account: LocalAccount) {
        switching = account.userId
        Task {
            defer { switching = nil }
            do {
                try await container.authService.switchAccount(to: account.userId)
            } catch {
                errorMessage = "Couldn't switch account: \(error.localizedDescription)"
            }
        }
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
                    Text(container.ntfyService.isEnabled ? "On" : "Off").themedSecondary()
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("The only way SecureHyperChat can notify you while closed. ntfy.sh sees when you receive something and of what kind — never what it says.")
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
                        Image(systemName: "exclamationmark.circle.fill")
                            .themedStatus(.warning)
                            .accessibilityLabel("Not set up")
                    }
                }
            }
            Button("Log Out") { container.authService.logout() }
        }
        .task { await container.recoveryService.refreshEmailStatus() }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        ThemedSection {
            Button { appearanceScope = .chatList } label: {
                Label("App background", systemImage: "list.bullet.rectangle")
            }
            Button { appearanceScope = .allChats } label: {
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
            Text("Online status is only shown to people you chat with, never as a “last seen” time. Turning read receipts off also hides other people's. GIFs: searching and loading GIFs contacts \(container.tenorService.providerName), which sees your IP address.")
        }
    }

    // MARK: Blocked

    @ViewBuilder
    private var blockedSection: some View {
        let me = container.authService.currentUserId ?? ""
        let blocked = Array(container.blockList.blocked(ownerUserId: me)).sorted()
        if !blocked.isEmpty {
            ThemedSection {
                ForEach(blocked, id: \.self) { userId in
                    HStack {
                        Text((try? container.messagingService.contact(userId))?.shownName ?? String(userId.prefix(8)))
                        Spacer()
                        Button("Unblock") {
                            container.messagingService.unblock(userId: userId)
                            container.objectWillChange.send()
                        }
                    }
                }
            } header: {
                Text("Blocked")
            } footer: {
                Text("Blocked people can't invite or message you. They aren't told.")
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        ThemedSection {
            LabeledContent("Photos, videos & files") {
                Text(ByteCountFormatter.string(fromByteCount: Int64(container.mediaEncryptionService.cacheSizeBytes()), countStyle: .file))
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Attachments stay on this phone until you delete them; the server forgets them once delivered. Delete a whole chat by swiping it left in the chat list.")
        }
    }

    private var alarmsSection: some View {
        ThemedSection {
            NavigationLink { AlarmListView() } label: {
                HStack {
                    Label("Alarms", systemImage: "alarm.fill")
                    Spacer()
                    if container.alarmService.enabledCount > 0 {
                        Text("\(container.alarmService.enabledCount) on").themedSecondary()
                    }
                }
            }
        }
    }

    // MARK: Connection (#2: automatic — this only shows the state)

    private var connectionSection: some View {
        ThemedSection {
            LabeledContent("Status") {
                Text(connectionText)
                    .themedStatus(container.connectionMonitor.isConnected ? .success : .warning)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Reconnects by itself when the app opens or the network comes back.")
        }
    }

    private var connectionText: String {
        if !container.connectionMonitor.isOnline { return "No internet" }
        return container.connectionMonitor.isConnected ? "Connected" : "Connecting…"
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
                container.ntfyService.deleteLocalData(ownerUserId: userId)
                container.blockList.removeAll(ownerUserId: userId)
                container.appearanceStore.removeAll(ownerUserId: userId)
                container.draftStore.removeAll(ownerUserId: userId)
                container.messagingService.clearPendingHandshakes(ownerUserId: userId)
                container.authService.logout()
                container.authService.forgetAccount(userId: userId)
            } catch AccountDeletionError.serverUnreachable {
                offerLocalOnlyDeletion = true
            } catch {
                errorMessage = "Couldn't delete the account: \(error.localizedDescription)"
            }
        }
    }
}
