import Foundation
import Combine

/// FIX (Bug #6): the password fields are gone.
///
/// They validated length and confirmation, then handed the value to `AuthService`,
/// which derived a PBKDF2 key and discarded it. Nothing in the app ever checked a
/// password again — `login` succeeded for any string. Keeping the fields would have
/// meant keeping a security promise the code doesn't make.
///
/// Local protection now comes from `AppLockService` (Face ID / Touch ID / passcode)
/// plus `.userPresence` access control on the storage key in the Keychain.
@MainActor
final class AuthViewModel: ObservableObject {
    @Published var username = ""
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let authService: AuthService
    private let messagingService: MessagingService

    init(authService: AuthService, messagingService: MessagingService) {
        self.authService = authService
        self.messagingService = messagingService
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmitLogin: Bool { !trimmedUsername.isEmpty && !isLoading }
    var canSubmitRegister: Bool { trimmedUsername.count >= 3 && !isLoading }

    func login() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.login(username: trimmedUsername)
            messagingService.startListening()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func register() async {
        errorMessage = nil
        guard trimmedUsername.count >= 3 else {
            errorMessage = "Username must be at least 3 characters."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.register(username: trimmedUsername)
            messagingService.startListening()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
