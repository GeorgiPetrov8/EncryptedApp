import SwiftUI

/// #4: when one of your messages was sent, delivered and read.
/// Uses `deliveredAt` / `readAt`, which `ReceiptService` already fills in.
struct MessageInfoSheet: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    let message: DisplayMessage

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    Text(message.text)
                        .lineLimit(4)
                        .font(.callout)
                }

                ThemedSection {
                    row("Sent", systemImage: "paperplane", date: sentDate, missing: sentMissingText)
                    row("Delivered", systemImage: "checkmark.circle", date: message.deliveredAt, missing: "Not yet delivered")
                    row("Read", systemImage: "eye", date: message.readAt, missing: "Not yet read")
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Message Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .appScreenStyle()
        }
        .presentationDetents([.medium, .large])
    }

    private var sentDate: Date? {
        switch message.status {
        case .sending, .failed: return nil
        default: return message.createdAt
        }
    }

    private var sentMissingText: String {
        message.status == .failed ? "Not sent — tap Retry in the chat" : "Waiting to send"
    }

    private var footer: String {
        var parts = ["Times are from your phone's clock."]
        if !container.receiptService.sendsReadReceipts {
            parts.append("Read receipts are off in Settings, so you don't see when others read your messages.")
        } else {
            parts.append("Read shows only if they have read receipts turned on.")
        }
        return parts.joined(separator: " ")
    }

    private func row(_ title: String, systemImage: String, date: Date?, missing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
            Spacer()
            if let date {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(date, format: .dateTime.hour().minute())
                        .fontWeight(.semibold)
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption)
                        .themedSecondary()
                }
            } else {
                Text(missing)
                    .font(.footnote)
                    .themedSecondary()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
