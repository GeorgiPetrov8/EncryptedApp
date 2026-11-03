import Foundation
import LocalAuthentication
import SwiftUI

/// #11: lock a single chat behind Face ID / Touch ID / the phone's passcode.
///
/// Only the device owner check — no separate password, no extra encryption.
/// It hides the chat on screen; the messages are protected at rest the same as
/// every other chat. Per device and per account (`conversations.isLocked`),
/// never sent to the other person.
///
/// Separate from App Lock on purpose: unlocking one chat must not unlock the
/// app, and vice versa. Every opening asks again; there is no "unlocked for a
/// while".
@MainActor
final class ChatLockService: ObservableObject {
    enum Outcome: Equatable {
        case success
        case cancelled
        case failed
        /// No Face ID / Touch ID and no passcode on this phone (also the Simulator
        /// without a passcode). Honest message instead of looking stuck.
        case unavailable(String)

        var message: String? {
            switch self {
            case .success, .cancelled: return nil
            case .failed: return "Couldn't confirm it's you. Try again."
            case .unavailable(let reason): return reason
            }
        }
    }

    /// True if this phone can confirm the owner at all. Locking needs it —
    /// otherwise the chat couldn't be opened again.
    var canAuthenticate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("Set a passcode (Settings → Face ID & Passcode) to lock chats.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                return .cancelled
            case .passcodeNotSet:
                return .unavailable("Set a passcode (Settings → Face ID & Passcode) to lock chats.")
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}

/// #11: covers a locked chat when the app goes to the background, and asks
/// again when it comes back. Cancel → `onCancel` (the chat closes).
///
/// The cover appears at `.background`, so the app-switcher snapshot taken
/// afterwards doesn't show the conversation either.
struct ChatLockGate: ViewModifier {
    let isLocked: Bool
    let lock: ChatLockService
    let name: String
    let onCancel: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var covered = false
    @State private var prompting = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .overlay {
                if covered {
                    ZStack {
                        Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                        VStack(spacing: 14) {
                            Image(systemName: "lock.fill").font(.system(size: 44))
                            Text("Chat with \(name) is locked").font(.headline)
                            if let error {
                                Text(error).font(.footnote).multilineTextAlignment(.center)
                            }
                            Button("Unlock") { Task { await unlock() } }
                                .buttonStyle(.borderedProminent)
                            Button("Close chat", action: onCancel)
                        }
                        .padding()
                    }
                    .transition(.opacity)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard isLocked else { return }
                if phase == .background {
                    covered = true
                    error = nil
                } else if phase == .active, covered, !prompting {
                    Task { await unlock() }
                }
            }
    }

    private func unlock() async {
        prompting = true
        defer { prompting = false }
        let outcome = await lock.authenticate(reason: "Unlock your chat with \(name)")
        switch outcome {
        case .success:
            withAnimation { covered = false }
        case .cancelled:
            onCancel()
        default:
            error = outcome.message
        }
    }
}

extension View {
    func chatLockGate(isLocked: Bool, lock: ChatLockService, name: String, onCancel: @escaping () -> Void) -> some View {
        modifier(ChatLockGate(isLocked: isLocked, lock: lock, name: name, onCancel: onCancel))
    }
}
