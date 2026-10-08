import SwiftUI

/// Settings → Notifications: opt-in ntfy notifications.
struct NotificationSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var errorMessage: String?
    @State private var info: String?
    @State private var confirmRegenerate = false

    private var service: NtfyService { container.ntfyService }

    var body: some View {
        Form {
            ThemedSection {
                Toggle("Notify me via ntfy", isOn: Binding(
                    get: { service.isEnabled },
                    set: { on in
                        perform {
                            if on { try await service.enable() } else { try await service.disable() }
                        }
                    }
                ))
            } footer: {
                Text("Shows “New message” when HyperChat is closed. The text of your messages is never sent — only that something arrived.")
            }

            if let topic = service.topic {
                ThemedSection {
                    LabeledContent("Topic") {
                        Text(topic)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button {
                        service.copyTopic()
                        info = "Topic copied."
                    } label: {
                        Label("Copy topic", systemImage: "doc.on.doc")
                    }
                    Button {
                        service.openAppStore()
                    } label: {
                        Label("Get ntfy from the App Store", systemImage: "arrow.down.app")
                    }
                    Button {
                        perform {
                            try await service.sendTest()
                            info = "Test sent — it should appear within a few seconds."
                        }
                    } label: {
                        Label("Send test notification", systemImage: "bell.badge")
                    }
                } header: {
                    Text("Set up on this phone")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Install **ntfy** from the App Store.")
                        Text("2. In ntfy tap **+**, paste the topic, keep the server as ntfy.sh, and subscribe.")
                        Text("3. Allow notifications for ntfy, then send a test.")
                    }
                }

                ThemedSection {
                    Button("Generate a new topic", role: .destructive) {
                        confirmRegenerate = true
                    }
                } footer: {
                    Text("Anyone who knows the topic can see when you get messages (not what they say). Don't share it. If you did, generate a new one and subscribe to it in ntfy.")
                }
            }

            if let info {
                ThemedSection { Text(info).font(.footnote).foregroundStyle(.green) }
            }
            if let errorMessage {
                ThemedSection { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Notifications")
        .appScreenStyle()
        .disabled(service.isBusy)
        .confirmationDialog("Generate a new topic?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Generate", role: .destructive) { perform { try await service.regenerate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notifications stop arriving until you subscribe to the new topic in ntfy.")
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        errorMessage = nil
        info = nil
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
