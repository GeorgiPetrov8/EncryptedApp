import SwiftUI

/// #14: "Remind me" on a message.
struct ReminderSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let conversationId: String
    let messageId: String
    let messagePreview: String
    let peerName: String

    @State private var title = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var includeText = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    TextField("Reminder", text: $title)
                } footer: {
                    Text("Shown in the notification. Tapping it opens this chat.")
                }

                ThemedSection("When") {
                    DatePicker("Time", selection: $date, in: Date().addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        quick("In 1 hour", Date().addingTimeInterval(3600))
                        quick("Tonight", at(hour: 20, dayOffset: 0))
                        quick("Tomorrow", at(hour: 9, dayOffset: 1))
                    }
                }

                ThemedSection {
                    Toggle("Show the message in the notification", isOn: $includeText)
                } footer: {
                    Text(includeText
                         ? "The text will be readable on your lock screen."
                         : "Off: the notification only shows your reminder title.")
                }

                if let errorMessage {
                    ThemedSection { StatusText(errorMessage, .error) }
                }
            }
            .navigationTitle("Remind Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(isSaving)
                }
            }
            .appScreenStyle()
            .onAppear { if title.isEmpty { title = "Reply to \(peerName)" } }
        }
    }

    private func quick(_ label: String, _ value: Date?) -> some View {
        Button(label) { if let value { date = value } }
            .buttonStyle(.themedBordered)
            .font(.caption)
            .disabled(value == nil)
    }

    /// Today/tomorrow at `hour`:00, or nil if already past.
    private func at(hour: Int, dayOffset: Int) -> Date? {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()),
              let value = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
              value > Date().addingTimeInterval(60) else { return nil }
        return value
    }

    private func save() {
        guard let me = container.authService.currentUserId else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await container.reminderService.schedule(
                    ownerUserId: me,
                    conversationId: conversationId,
                    messageId: messageId,
                    title: title,
                    body: includeText ? messagePreview : nil,
                    at: date
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
