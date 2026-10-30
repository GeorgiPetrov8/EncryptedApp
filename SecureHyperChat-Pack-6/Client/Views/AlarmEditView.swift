import SwiftUI

/// Create or edit one alarm, including picking the accountability contact.
///
/// FIX: the contact list only shows people who **accepted** the chat. It used
/// to list every stored contact, including pending invitations: a word sent to
/// someone who hadn't accepted went into a queue, and the alarm stopped as if it
/// had been delivered.
struct AlarmEditView: View {
    @Environment(\.dismiss) private var dismiss

    private let container: AppContainer
    private let existing: Alarm?

    @State private var time: Date
    @State private var label: String
    @State private var repeatWeekdays: Set<Int>
    @State private var dismissalMode: AlarmDismissalMode
    @State private var accountabilityPeerId: String?
    @State private var requiredTaskCount: Int
    @State private var contacts: [User] = []

    init(container: AppContainer, alarm: Alarm?) {
        self.container = container
        self.existing = alarm
        let components = DateComponents(hour: alarm?.hour ?? 7, minute: alarm?.minute ?? 0)
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        _label = State(initialValue: alarm?.label ?? "Alarm")
        _repeatWeekdays = State(initialValue: Set(alarm?.repeatWeekdays ?? []))
        _dismissalMode = State(initialValue: alarm?.dismissalMode ?? .tasks)
        _accountabilityPeerId = State(initialValue: alarm?.accountabilityPeerId)
        _requiredTaskCount = State(initialValue: alarm?.requiredTaskCount ?? 3)
    }

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    DatePicker(selection: $time, displayedComponents: .hourAndMinute) {
                        Text("Time").fixedSize(horizontal: true, vertical: false)
                    }
                    .datePickerStyle(.wheel)

                    TextField("Label", text: $label)
                }

                ThemedSection("Repeat") {
                    WeekdayPicker(selected: $repeatWeekdays)
                    if repeatWeekdays.isEmpty {
                        Text("Rings once, then switches itself off.")
                            .font(.caption)
                            .themedSecondary()
                    }
                }

                ThemedSection {
                    Picker("To stop it", selection: $dismissalMode) {
                        ForEach(AlarmDismissalMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Text(dismissalMode.explanation)
                        .font(.caption)
                        .themedSecondary()
                } header: {
                    Text("Dismissal")
                }

                if dismissalMode == .tasks {
                    ThemedSection("How many problems") {
                        Stepper("\(requiredTaskCount) problems", value: $requiredTaskCount, in: 1...10)
                    }
                }

                if dismissalMode == .messageContact {
                    ThemedSection {
                        if contacts.isEmpty {
                            Text("No accepted chats yet. The person has to accept your invitation before an alarm can message them.")
                                .font(.footnote)
                                .themedSecondary()
                        } else {
                            Picker("Contact", selection: $accountabilityPeerId) {
                                Text("Choose…").tag(String?.none)
                                ForEach(contacts) { contact in
                                    Text(contact.shownName).tag(String?.some(contact.id))
                                }
                            }
                        }
                    } header: {
                        Text("Who you'll message")
                    } footer: {
                        Text("A random word appears when the alarm rings. Type it and it's sent to them as a normal encrypted message — so someone other than you knows you're actually up.")
                    }
                }

                ThemedSection { reliabilityNote }
            }
            .navigationTitle(existing == nil ? "New Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .appScreenStyle()
            .onAppear(perform: loadContacts)
        }
    }

    private var reliabilityNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Before you rely on this", systemImage: "info.circle")
                .font(.footnote.bold())
            Text("iOS only lets the built-in Clock app override Focus modes and the mute switch. This alarm rings through notifications, and gets loud once you open it — but if your phone is in Do Not Disturb with this app filtered out, it may stay quiet. Keep the Clock alarm as a backup for anything you can't miss.")
                .font(.caption)
                .themedSecondary()
        }
    }

    private var canSave: Bool {
        guard dismissalMode == .messageContact else { return true }
        guard let id = accountabilityPeerId else { return false }
        return contacts.contains { $0.id == id }
    }

    /// Only people with an **accepted** chat.
    private func loadContacts() {
        guard let me = container.authService.currentUserId else { return }
        let accepted = ((try? container.conversationRepository.fetchAllSortedByRecentActivity(ownerUserId: me)) ?? [])
            .filter { $0.relationshipState == .accepted }
            .compactMap { $0.otherParticipant(myUserId: me) }
        let peerIds = Set(accepted)
        contacts = ((try? container.userRepository.fetchAll(ownerUserId: me)) ?? [])
            .filter { $0.id != me && peerIds.contains($0.id) }
            .sorted { $0.shownName.localizedCaseInsensitiveCompare($1.shownName) == .orderedAscending }
        if let selected = accountabilityPeerId, !peerIds.contains(selected) {
            accountabilityPeerId = nil
        }
    }

    private func save() {
        guard let ownerUserId = container.authService.currentUserId else { return }
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)

        var alarm = existing ?? Alarm(ownerUserId: ownerUserId, hour: components.hour ?? 7, minute: components.minute ?? 0)
        alarm.hour = components.hour ?? 7
        alarm.minute = components.minute ?? 0
        alarm.label = label.trimmingCharacters(in: .whitespaces)
        alarm.repeatWeekdays = repeatWeekdays.sorted()
        alarm.dismissalMode = dismissalMode
        alarm.accountabilityPeerId = dismissalMode == .messageContact ? accountabilityPeerId : nil
        alarm.requiredTaskCount = requiredTaskCount
        alarm.isEnabled = true
        alarm.lastFiredAt = nil
        alarm.lastDismissedAt = nil

        Task {
            await container.alarmService.save(alarm)
            dismiss()
        }
    }
}

private struct WeekdayPicker: View {
    @Binding var selected: Set<Int>
    @Environment(\.appTheme) private var theme

    private let weekdays = Array(1...7)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(weekdays, id: \.self) { day in
                let isOn = selected.contains(day)
                Button {
                    if isOn { selected.remove(day) } else { selected.insert(day) }
                } label: {
                    Text(symbol(for: day))
                        .font(.caption.bold())
                        .frame(width: 38, height: 38)
                        .background(isOn ? theme.accentFill : theme.fieldFill, in: Circle())
                        .foregroundStyle(isOn ? theme.accentText : theme.text)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(for weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
    }
}
