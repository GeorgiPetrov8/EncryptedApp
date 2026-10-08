import SwiftUI

/// The out-of-band verification surface (Bug #2).
struct VerifyIdentityView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let peerId: String
    let peerUsername: String

    @State private var safetyNumber: String?
    @State private var pendingSafetyNumber: String?
    @State private var isVerified = false
    @State private var identityChanged = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if identityChanged {
                    ThemedSection {
                        Label("Security keys changed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text("""
                        The server presented different security keys for \(peerUsername). This happens \
                        when they reinstall the app or switch device — but it is also what an \
                        interception attempt looks like.

                        Compare the new safety number with them over a channel this app doesn't \
                        control before accepting.
                        """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if let pendingSafetyNumber {
                        ThemedSection("New safety number") {
                            SafetyNumberGrid(value: pendingSafetyNumber)
                        }
                    }

                    ThemedSection {
                        Button("Accept new keys", role: .destructive) {
                            acceptChange()
                        }
                    } footer: {
                        Text("Messaging stays paused until you accept.")
                    }
                } else {
                    ThemedSection {
                        Text("Compare this number with \(peerUsername) in person or over a call. If it matches on both devices, your conversation is not being intercepted.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let safetyNumber {
                        ThemedSection("Safety number") {
                            SafetyNumberGrid(value: safetyNumber)
                        }

                        ThemedSection {
                            Toggle("Marked as verified", isOn: Binding(
                                get: { isVerified },
                                set: { setVerified($0) }
                            ))
                        } footer: {
                            Text("Marking as verified only changes how this contact is shown to you. It does not send anything to \(peerUsername).")
                        }
                    } else {
                        ThemedSection {
                            Text("No identity key on record for this contact yet. It will be pinned when the first message is exchanged.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    ThemedSection {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Verify \(peerUsername)")
            .appScreenStyle()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        do {
            // FIX: goes through `MessagingService.contact`, which scopes the lookup to
            // the signed-in account. Reading `users` by id alone is ambiguous now that
            // the table is keyed by `(ownerUserId, id)`.
            let peer = try container.messagingService.contact(peerId)
            isVerified = peer?.isVerified ?? false
            identityChanged = peer?.hasUnacknowledgedIdentityChange ?? false
            safetyNumber = try container.messagingService.safetyNumber(forPeerId: peerId)
            pendingSafetyNumber = try container.messagingService.pendingSafetyNumber(forPeerId: peerId)
        } catch {
            errorMessage = "Couldn't load verification details: \(error.localizedDescription)"
        }
    }

    private func acceptChange() {
        do {
            try container.messagingService.acknowledgeIdentityChange(userId: peerId)
            load()
        } catch {
            errorMessage = "Couldn't accept the new keys: \(error.localizedDescription)"
        }
    }

    private func setVerified(_ value: Bool) {
        do {
            try container.messagingService.setVerified(value, userId: peerId)
            isVerified = value
        } catch {
            errorMessage = "Couldn't update verification: \(error.localizedDescription)"
        }
    }
}

/// Renders the 12 five-digit groups in a monospaced grid, which is far easier to read
/// aloud than a single long run of digits.
private struct SafetyNumberGrid: View {
    let value: String

    private var groups: [String] { value.split(separator: " ").map(String.init) }

    var body: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }
}
