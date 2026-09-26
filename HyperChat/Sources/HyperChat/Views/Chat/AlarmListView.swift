import SwiftUI

struct AlarmListView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var editing: Alarm?
    @State private var isCreating = false

    private var service: AlarmService { container.alarmService }

    var body: some View {
        List {
            if !service.notificationsAuthorized {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Notifications are off", systemImage: "bell.slash.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Alarms can't ring without notification permission.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Allow notifications") {
                            Task { await service.requestNotificationPermission() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if service.alarms.isEmpty {
                    ContentUnavailableView(
                        "No alarms",
                        systemImage: "alarm",
                        description: Text("Add one that won't let you snooze your way out of it.")
                    )
                } else {
                    ForEach(service.alarms) { alarm in
                        AlarmRow(alarm: alarm) {
                            Task { await service.setEnabled(!alarm.isEnabled, for: alarm) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = alarm }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let alarm = service.alarms[index]
                            Task { await service.delete(alarm) }
                        }
                    }
                }
            } footer: {
                // Surfaced rather than hidden: iOS caps pending local
                // notifications at 64 and silently drops the overflow, so
                // an unexplained "my sixth alarm never rang" is exactly the
                // kind of bug that erodes trust in an alarm app.
                Text("Up to \(AlarmScheduler.maxEnabledAlarms) alarms can be active at once — that's the limit of what iOS will reliably schedule.")
            }
        }
        .navigationTitle("Alarms")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(service.isAtEnabledLimit && service.alarms.count >= AlarmScheduler.maxEnabledAlarms)
                .accessibilityLabel("Add alarm")
            }
        }
        .sheet(isPresented: $isCreating) {
            AlarmEditView(container: container, alarm: nil)
        }
        .sheet(item: $editing) { alarm in
            AlarmEditView(container: container, alarm: alarm)
        }
        .task { await service.activate() }
    }
}

private struct AlarmRow: View {
    let alarm: Alarm
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alarm.formattedTime)
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(alarm.isEnabled ? .primary : .secondary)

                HStack(spacing: 6) {
                    Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                    Text("·")
                    Text(alarm.repeatSummary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    alarm.dismissalMode == .tasks ? "\(alarm.requiredTaskCount) problems" : "Message a contact",
                    systemImage: alarm.dismissalMode == .tasks ? "function" : "paperplane.fill"
                )
                .font(.caption2)
                .foregroundStyle(.tint)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { alarm.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }
}
