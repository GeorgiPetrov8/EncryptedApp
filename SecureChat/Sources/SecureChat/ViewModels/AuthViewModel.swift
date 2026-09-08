import Foundation
import Combine

/// FIX (Bug #6): the password fields are gone.
///
/// They validated length and confirmation, then handed the value to `AuthService`,
/// which derived a PBKDF2 key and discarded it. Nothing in the app ever checked a
/// password again — `login` succeeded for any string.
///
/// FIX (Bug #25): no longer holds a `MessagingService`.
///
/// It used to call `messagingService.startListening()` after each successful
/// login/register. That responsibility now sits in `AppContainer`, which observes
/// the active account — so there is exactly one place that starts the listener and
/// it cannot be forgotten on a new sign-in path.
@MainActor
final class AuthViewModel: ObservableObject {
    @Published var username = ""
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
