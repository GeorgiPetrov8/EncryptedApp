import SwiftUI

/// Create or edit one alarm, including picking the accountability contact.
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

        let components = DateComponents(
            hour: alarm?.hour ?? 7,
            minute: alarm?.minute ?? 0
        )
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
                    DatePicker(
                        selection: $time,
                        displayedComponents: .hourAndMinute
                    ) {
                        Text("Time")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .datePickerStyle(.wheel)
                    TextField("Label", text: $label)
                }

                ThemedSection("Repeat") {
                    WeekdayPicker(selected: $repeatWeekdays)
                    if repeatWeekdays.isEmpty {
                        Text("Rings once, then switches itself off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                            Text("No contacts yet — start a conversation with someone first, then come back.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Contact", selection: $accountabilityPeerId) {
                                Text("Choose…").tag(String?.none)
                                ForEach(contacts) { contact in
                                    Text(contact.username.isEmpty ? String(contact.id.prefix(8)) : contact.username)
                                        .tag(String?.some(contact.id))
                                }
                            }
                        }
                    } header: {
                        Text("Who you'll message")
                    } footer: {
                        Text("A random word appears when the alarm rings. Type it and it's sent to them as a normal encrypted message — so someone other than you knows you're actually up.")
                    }
                }

                ThemedSection {
                    reliabilityNote
                }
            }
            .navigationTitle(existing == nil ? "New Alarm" : "Edit Alarm")
            .appScreenStyle()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadContacts)
        }
    }

    /// Stated up front rather than discovered by oversleeping.
    ///
    /// iOS gives third-party apps no true alarm API — only the Clock app
    /// can override Do Not Disturb and the mute switch. Pretending
    /// otherwise would be the single most harmful thing this screen could
    /// do, so the constraint is spelled out where someone is deciding
    /// whether to rely on it.
    private var reliabilityNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Before you rely on this", systemImage: "info.circle")
                .font(.footnote.bold())
            Text("""
                iOS only lets the built-in Clock app override Focus modes and the mute switch. \
                This alarm rings through notifications, and gets loud once you open it — but if \
                your phone is in Do Not Disturb with this app filtered out, it may stay quiet. \
                Keep the Clock alarm as a backup for anything you can't miss.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canSave: Bool {
        if dismissalMode == .messageContact {
            return accountabilityPeerId != nil
        }
        return true
    }

    private func loadContacts() {
        guard let ownerUserId = container.authService.currentUserId else { return }
        let all = (try? container.userRepository.fetchAll(ownerUserId: ownerUserId)) ?? []
        // Exclude the self-row: messaging yourself proves nothing about
        // being awake to anyone else, which is the entire point of the mode.
        contacts = all
            .filter { $0.id != ownerUserId }
            .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }

    private func save() {
        guard let ownerUserId = container.authService.currentUserId else { return }
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)

        var alarm = existing ?? Alarm(
            ownerUserId: ownerUserId,
            hour: components.hour ?? 7,
            minute: components.minute ?? 0
        )
        alarm.hour = components.hour ?? 7
        alarm.minute = components.minute ?? 0
        alarm.label = label.trimmingCharacters(in: .whitespaces)
        alarm.repeatWeekdays = repeatWeekdays.sorted()
        alarm.dismissalMode = dismissalMode
        alarm.accountabilityPeerId = dismissalMode == .messageContact ? accountabilityPeerId : nil
        alarm.requiredTaskCount = requiredTaskCount
        alarm.isEnabled = true
        // Editing an alarm clears any stale fired/dismissed pair, so a
        // previously-expired alarm doesn't immediately look "still ringing"
        // to the resume check on next launch.
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

    /// 1 = Sunday … 7 = Saturday, matching `Calendar.weekday` and
    /// `DateComponents.weekday` — see `Alarm.repeatWeekdays` for why no
    /// conversion happens anywhere.
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
                        .background(isOn ? Color.brand : Color(.secondarySystemBackground), in: Circle())
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(for weekday: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "?"
    }
}
