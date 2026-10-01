import SwiftUI

/// The full-screen challenge shown while an alarm is ringing.
///
/// Deliberately has no close button, no swipe-to-dismiss and no navigation
/// out — the only exits are completing the challenge or the 30-minute
/// auto-expiry. Presented from `RootView` as an overlay rather than a
/// `.sheet` for exactly that reason: sheets are interactively dismissible
/// by default, and a half-asleep downward swipe is precisely the reflex
/// this feature exists to defeat.
struct AlarmRingingView: View {
    @EnvironmentObject private var container: AppContainer

    @State private var answer = ""
    @State private var typedWord = ""
    @FocusState private var inputFocused: Bool

    private var service: AlarmService { container.alarmService }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.09, blue: 0.24), Color(red: 0.05, green: 0.04, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header

                    if let notice = service.fallbackNotice {
                        noticeBanner(notice)
                    }

                    switch service.challenge {
                    case .tasks(let completed, let required, let task):
                        taskChallenge(completed: completed, required: required, task: task)
                    case .message(_, let peerUsername, let word):
                        messageChallenge(peerUsername: peerUsername, word: word)
                    case .none:
                        ProgressView().tint(.white)
                    }

                    if let error = service.challengeError {
                        Text(error)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                            .transition(.opacity)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.never)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: service.challengeError)
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "alarm.waves.left.and.right.fill")
                .font(.system(size: 46))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)

            Text(service.ringingAlarm?.label ?? "Alarm")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text(Date(), style: .time)
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
        }
        .padding(.top, 20)
    }

    private func noticeBanner(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Tasks

    private func taskChallenge(completed: Int, required: Int, task: MentalTask) -> some View {
        VStack(spacing: 20) {
            progressDots(completed: completed, required: required)

            Text(task.prompt)
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(task.kind.hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

            TextField("", text: $answer)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 32, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 220)

            Button {
                service.submitTaskAnswer(answer)
                answer = ""
                inputFocused = true
            } label: {
                Text("Check")
                    .font(.headline)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            // Re-keying on the prompt clears the field automatically when
            // a wrong answer regenerates the problem, so the previous
            // (wrong) number isn't left sitting there to be resubmitted.
            .id(task.prompt)
        }
    }

    private func progressDots(completed: Int, required: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<required, id: \.self) { index in
                Image(systemName: index < completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(index < completed ? .green : .white.opacity(0.35))
            }
        }
        .accessibilityLabel("\(completed) of \(required) solved")
    }

    // MARK: Message

    private func messageChallenge(peerUsername: String, word: String) -> some View {
        VStack(spacing: 18) {
            // The storage key is `.userPresence`-gated, so sending anything
            // requires it to be unlocked first. Prompting here — rather
            // than letting the send fail and burn a fallback attempt — is
            // the difference between "authenticate, then send" and
            // "mysteriously fails twice, then switches to maths".
            if !container.authService.isStorageUnlocked {
                VStack(spacing: 12) {
                    Text("Unlock to send the message")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("Unlock") {
                        Task { await container.authService.unlockStorage() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            } else {
                Text("Send this word to **\(peerUsername)**")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(word)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .textSelection(.disabled)
                    .padding(.vertical, 8)

                TextField("Type the word", text: $typedWord)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($inputFocused)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 260)

                Button {
                    Task {
                        await service.submitWord(typedWord)
                        typedWord = ""
                    }
                } label: {
                    Group {
                        if service.isSendingWord {
                            ProgressView().tint(.white)
                        } else {
                            Text("Send & stop alarm").font(.headline)
                        }
                    }
                    .frame(maxWidth: 260)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(typedWord.trimmingCharacters(in: .whitespaces).isEmpty || service.isSendingWord)

                Text("It's a real, end-to-end encrypted message — they'll see it in the chat.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
