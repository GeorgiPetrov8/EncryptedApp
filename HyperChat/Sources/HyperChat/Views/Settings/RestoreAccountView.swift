import SwiftUI
import UniformTypeIdentifiers

/// Signed-out screen for getting an account back on a new phone.
struct RestoreAccountView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case file = "Backup file"
        case email = "Email"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .file

    // File
    @State private var showImporter = false
    @State private var pickedFile: URL?
    @State private var filePassword = ""

    // Email
    @State private var username = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var ticket: RecoveryTicket?
    @State private var serverPassword = ""
    @State private var confirmNewKeys = false

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var service: RecoveryService { container.recoveryService }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Restore from", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch mode {
                case .file: fileSection
                case .email: emailSections
                }

                if let errorMessage {
                    ThemedSection { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Restore Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView("Restoring…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item]) { result in
                if case .success(let url) = result { pickedFile = url }
            }
            .confirmationDialog(
                "Recover with new keys?",
                isPresented: $confirmNewKeys,
                titleVisibility: .visible
            ) {
                Button("Recover with new keys", role: .destructive) { recoverWithNewKeys() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You keep your username, but your old messages can't be recovered and your contacts will see that your security keys changed.")
            }
        }
    }

    // MARK: File

    private var fileSection: some View {
        ThemedSection {
            Button {
                showImporter = true
            } label: {
                Label(pickedFile?.lastPathComponent ?? "Choose backup file", systemImage: "doc")
            }
            SecureField("Backup password", text: $filePassword)
                .textContentType(.password)
            Button("Restore") {
                guard let pickedFile else { return }
                run { try await service.restore(fromFile: pickedFile, password: filePassword) }
            }
            .disabled(pickedFile == nil || filePassword.isEmpty)
        } footer: {
            Text("The .hcbackup file you exported from Settings → Account Recovery.")
        }
    }

    // MARK: Email

    @ViewBuilder
    private var emailSections: some View {
        ThemedSection {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(ticket != nil)
            Button(codeSent ? "Send code again" : "Send code to my recovery email") {
                run {
                    try await service.startEmailRecovery(username: username)
                    codeSent = true
                }
            }
            .disabled(username.isEmpty || ticket != nil)
            if codeSent && ticket == nil {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Continue") {
                    run { ticket = try await service.verifyEmailRecovery(username: username, code: code) }
                }
                .disabled(code.count < 6)
            }
        } footer: {
            Text(codeSent
                 ? "If this account has a recovery email, a code is on its way. Check spam too."
                 : "Works only if you added a recovery email in Settings.")
        }

        if let ticket {
            if ticket.hasBackup {
                ThemedSection {
                    SecureField("Backup password", text: $serverPassword)
                        .textContentType(.password)
                    Button("Restore everything") {
                        run { try await service.restoreFromServerBackup(ticket: ticket, password: serverPassword) }
                    }
                    .disabled(serverPassword.isEmpty)
                } header: {
                    Text("Server backup found")
                } footer: {
                    if let date = ticket.backupUpdatedAt {
                        Text("Made \(date.formatted(date: .abbreviated, time: .shortened)). Messages after that aren't in it.")
                    }
                }
            }
            ThemedSection {
                Button(ticket.hasBackup ? "I forgot the password" : "Recover with new keys", role: .destructive) {
                    confirmNewKeys = true
                }
            } footer: {
                Text("Keeps your username. Old messages are lost and contacts see a security-key warning.")
            }
        }
    }

    private func recoverWithNewKeys() {
        guard let ticket else { return }
        run { try await service.recoverWithNewKeys(ticket: ticket) }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await operation()
                // Signed in now — RootView switches to the chats list.
                if container.authService.isAuthenticated { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
