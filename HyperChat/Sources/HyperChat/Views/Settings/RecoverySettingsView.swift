import SwiftUI

/// Settings → Account recovery: recovery email, backup file, server backup.
struct RecoverySettingsView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var emailDraft = ""
    @State private var code = ""
    @State private var isEditingEmail = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?

    @State private var passwordPurpose: PasswordPurpose?
    @State private var exportedFile: URL?

    private var service: RecoveryService { container.recoveryService }
    private var status: RecoveryEmailStatus? { service.emailStatus }

    enum PasswordPurpose: String, Identifiable {
        case exportFile, uploadServer
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            emailSection
            fileBackupSection
            serverBackupSection
            explanationSection

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.green) }
            }
            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Account Recovery")
        .appScreenStyle()
        .disabled(isWorking || service.isBusy)
        .overlay { if isWorking || service.isBusy { ProgressView() } }
        .task { await service.refreshEmailStatus() }
        .sheet(item: $passwordPurpose) { purpose in
            BackupPasswordSheet(purpose: purpose) { password in
                passwordPurpose = nil
                Task { await runBackup(purpose, password: password) }
            }
        }
    }

    // MARK: Email

    private var emailSection: some View {
        Section {
            if let email = status?.email, !isEditingEmail {
                LabeledContent("Email") {
                    HStack(spacing: 4) {
                        Text(email)
                        if status?.verified == true {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                }
                Button("Change email") {
                    emailDraft = email
                    isEditingEmail = true
                }
                Button("Remove email", role: .destructive) {
                    perform { try await service.removeEmail() }
                }
            } else {
                TextField("you@example.com", text: $emailDraft)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Send verification code") {
                    perform {
                        try await service.requestEmailCode(emailDraft)
                        message = "Code sent to \(emailDraft)."
                    }
                }
                .disabled(emailDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if isEditingEmail {
                    Button("Cancel") { isEditingEmail = false }
                }
            }

            if let pending = status?.pendingEmail {
                TextField("6-digit code sent to \(pending)", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Verify") {
                    perform {
                        try await service.verifyEmail(code: code)
                        code = ""
                        isEditingEmail = false
                        message = "Recovery email verified."
                    }
                }
                .disabled(code.count < 6)
            }
        } header: {
            Text("Recovery email")
        } footer: {
            Text("Used to send you a code if you lose your phone. It doesn't give anyone access to your messages. If you change it, your old address is notified.")
        }
    }

    // MARK: Backups

    private var fileBackupSection: some View {
        Section {
            Button {
                passwordPurpose = .exportFile
            } label: {
                Label("Export backup file", systemImage: "square.and.arrow.up")
            }
            if let exportedFile {
                ShareLink(item: exportedFile) {
                    Label("Save or share \(exportedFile.lastPathComponent)", systemImage: "folder")
                }
            }
        } header: {
            Text("Backup file")
        } footer: {
            Text("An encrypted file with your keys, chats and history. Save it to Files or iCloud Drive. To restore, choose “Restore account” on a new phone and enter the password.")
        }
    }

    private var serverBackupSection: some View {
        Section {
            if let backup = status?.backup {
                LabeledContent("Last backup") {
                    Text(backup.updatedAt, style: .relative) + Text(" ago")
                }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file))
            }
            Button {
                passwordPurpose = .uploadServer
            } label: {
                Label(status?.backup == nil ? "Back up to server" : "Update server backup", systemImage: "icloud.and.arrow.up")
            }
            .disabled(status?.verified != true)
            if status?.backup != nil {
                Button("Delete server backup", role: .destructive) {
                    perform { try await service.deleteServerBackup() }
                }
            }
        } header: {
            Text("Server backup")
        } footer: {
            Text(status?.verified == true
                 ? "Stored encrypted with your password — the server can't read it. Restore it on a new phone with your email code and the password. It isn't updated automatically, so update it now and then."
                 : "Verify a recovery email first.")
        }
    }

    private var explanationSection: some View {
        Section("If you lose your phone") {
            Label("Backup file + password → everything comes back.", systemImage: "checkmark.circle")
            Label("Email + server backup + password → everything comes back.", systemImage: "checkmark.circle")
            Label("Email only → you keep your username with new keys. Old messages can't be recovered and contacts see a security-key warning.", systemImage: "exclamationmark.triangle")
            Label("Nothing → the account can't be recovered. Nobody, including us, has your keys.", systemImage: "xmark.circle")
        }
        .font(.footnote)
    }

    // MARK: Actions

    private func runBackup(_ purpose: PasswordPurpose, password: String) async {
        errorMessage = nil
        message = nil
        do {
            switch purpose {
            case .exportFile:
                exportedFile = try await service.exportBackupFile(password: password)
                message = "Backup ready — tap “Save or share” to store it."
            case .uploadServer:
                try await service.uploadServerBackup(password: password)
                message = "Server backup updated."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        errorMessage = nil
        message = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Asks for a backup password twice. It's never stored.
private struct BackupPasswordSheet: View {
    let purpose: RecoverySettingsView.PasswordPurpose
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""

    private var isValid: Bool {
        password.count >= BackupArchive.minimumPasswordLength && password == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Repeat password", text: $confirmation)
                        .textContentType(.newPassword)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("At least \(BackupArchive.minimumPasswordLength) characters.")
                        if !confirmation.isEmpty && password != confirmation {
                            Text("The passwords don't match.").foregroundStyle(.red)
                        }
                        Text("Write it down. If you forget it, this backup can't be opened by anyone.")
                            .bold()
                    }
                }
            }
            .navigationTitle(purpose == .exportFile ? "Export Backup" : "Server Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onConfirm(password) }
                        .disabled(!isValid)
                }
            }
        }
    }
}
