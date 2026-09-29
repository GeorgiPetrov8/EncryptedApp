import Foundation
import Combine
import os

/// Owns alarm state: scheduling, ringing, and the dismissal challenge.
@MainActor
final class AlarmService: ObservableObject {

    /// What the user has to do right now to silence the current alarm.
    enum Challenge: Equatable {
        case tasks(completed: Int, required: Int, task: MentalTask)
        case message(peerId: String, peerUsername: String, word: String)
    }

    @Published private(set) var alarms: [Alarm] = []
    @Published private(set) var ringingAlarm: Alarm?
    @Published private(set) var challenge: Challenge?
    /// Explains a mode switch the user didn't ask for — currently only the
    /// "couldn't send, so here are tasks instead" fallback.
    @Published private(set) var fallbackNotice: String?
    @Published private(set) var challengeError: String?
    @Published private(set) var isSendingWord = false
    @Published private(set) var notificationsAuthorized = false

    private let repository: AlarmRepository
    private let scheduler: AlarmScheduler
    private let audio: AlarmAudioService
    private let authService: AuthService
    private let userRepository: UserRepository
    private let conversationRepository: ConversationRepository
    private let logger = Logger(subsystem: "com.HyperChat", category: "alarm")

    /// Set by `AppContainer` after construction — `MessagingService` is built
    /// after this service, so the dependency can't go through the initializer
    /// without a cycle.
    private var sendMessageHandler: ((String, Conversation) async throws -> Void)?

    /// An alarm nobody engages with eventually gives up, instead of looping
    /// audio and haptics until the battery dies. It also bounds the "resume
    /// after force-quit" window.
    static let autoExpiry: TimeInterval = 30 * 60

    /// Failed send attempts before `.messageContact` degrades to tasks.
    private static let sendFailuresBeforeFallback = 2
    private var sendFailures = 0

    private var expiryTask: Task<Void, Never>?

    init(
        repository: AlarmRepository,
        scheduler: AlarmScheduler,
        audio: AlarmAudioService,
        authService: AuthService,
        userRepository: UserRepository,
        conversationRepository: ConversationRepository
    ) {
        self.repository = repository
        self.scheduler = scheduler
        self.audio = audio
        self.authService = authService
        self.userRepository = userRepository
        self.conversationRepository = conversationRepository
    }

    func setSendMessageHandler(_ handler: @escaping (String, Conversation) async throws -> Void) {
        sendMessageHandler = handler
    }

    // MARK: Lifecycle

    /// Called when an account becomes active, and whenever the app foregrounds.
    func activate() async {
        guard let ownerUserId = authService.currentUserId else { return }

        notificationsAuthorized = await scheduler.authorizationStatus() == .authorized
        reloadAlarms()
        pruneDeletedAccountabilityContacts(ownerUserId: ownerUserId)
        await scheduler.reschedule(alarms: alarms)
        resumeRingingIfNeeded(ownerUserId: ownerUserId)
        // FIX (Pack 8): the in-app check this method's documentation always
        // claimed but never did.
        checkForDueAlarm()
    }

    func requestNotificationPermission() async {
        notificationsAuthorized = await scheduler.requestAuthorization()
        await scheduler.reschedule(alarms: alarms)
    }

    func reloadAlarms() {
        guard let ownerUserId = authService.currentUserId else { return }
        alarms = (try? repository.fetchAll(ownerUserId: ownerUserId)) ?? []
    }

    /// FIX (Pack 8, Medium #10): a read failure is no longer treated as "this
    /// account has no contacts".
    ///
    /// `(try? fetchAll) ?? []` turned a database error into an empty contact
    /// list, which then downgraded *every* `.messageContact` alarm to tasks and
    /// permanently discarded the peer ids. Now the sweep is skipped entirely
    /// rather than acting on a false empty.
    private func pruneDeletedAccountabilityContacts(ownerUserId: String) {
        let contacts: [User]
        do {
            contacts = try userRepository.fetchAll(ownerUserId: ownerUserId)
        } catch {
            logger.error("Couldn't read contacts; skipping accountability sweep")
            return
        }
        try? repository.clearMissingAccountabilityPeers(
            ownerUserId: ownerUserId,
            existingPeerIds: Set(contacts.map(\.id))
        )
        reloadAlarms()
    }

    /// Restores a ringing alarm after the app was force-quit mid-challenge.
    private func resumeRingingIfNeeded(ownerUserId: String) {
        guard ringingAlarm == nil,
              let unresolved = try? repository.fetchUnresolvedRinging(
                  ownerUserId: ownerUserId, window: Self.autoExpiry
              )
        else { return }
        logger.info("Resuming an alarm that was still ringing before the app closed")
        beginRinging(unresolved, firedAt: unresolved.lastFiredAt ?? Date(), markFired: false)
    }

    /// FIX (Pack 8): starts an alarm whose scheduled time has just passed but
    /// which was never acknowledged — the notification was missed, suppressed
    /// by a Focus mode, or swiped away.
    ///
    /// Before this, `resumeRingingIfNeeded` only resumed an alarm *already*
    /// marked as fired, so opening the app at alarm time with no delivered
    /// notification showed nothing at all.
    private func checkForDueAlarm() {
        guard ringingAlarm == nil else { return }
        let now = Date()

        for alarm in alarms where alarm.isEnabled {
            guard let due = scheduler.mostRecentOccurrence(of: alarm, before: now),
                  now.timeIntervalSince(due) < Self.autoExpiry else { continue }
            if let dismissedAt = alarm.lastDismissedAt, dismissedAt >= due { continue }

            beginRinging(alarm, firedAt: due, markFired: true)
            return
        }
    }

    // MARK: Editing

    func save(_ alarm: Alarm) async {
        try? repository.save(alarm)
        reloadAlarms()
        await scheduler.reschedule(alarms: alarms)
    }

    func delete(_ alarm: Alarm) async {
        try? repository.delete(ownerUserId: alarm.ownerUserId, id: alarm.id)
        reloadAlarms()
        await scheduler.reschedule(alarms: alarms)
    }

    func setEnabled(_ isEnabled: Bool, for alarm: Alarm) async {
        var updated = alarm
        updated.isEnabled = isEnabled
        await save(updated)
    }

    var enabledCount: Int { alarms.filter(\.isEnabled).count }

    /// True when enabling one more alarm would exceed what iOS will actually
    /// schedule.
    var isAtEnabledLimit: Bool { enabledCount >= AlarmScheduler.maxEnabledAlarms }

    // MARK: Ringing

    /// Entry point from a tapped or delivered notification.
    ///
    /// FIX (Pack 8): takes the fire date and validates it, instead of trusting
    /// that any tap means "ring now".
    func fireAlarm(id: String, firedAt: Date = Date()) {
        guard ringingAlarm == nil,
              let ownerUserId = authService.currentUserId,
              let alarm = try? repository.fetch(ownerUserId: ownerUserId, id: id)
        else { return }

        // A disabled alarm must not ring — toggling an alarm off and then
        // tapping its already-delivered notification used to start a
        // challenge for an alarm the user switched off.
        //
        // Note: Pack 8's draft allowed `alarm.isEnabled || alarm.repeatsWeekly`,
        // which would still ring a *disabled* repeating alarm. A one-shot alarm
        // stays enabled until it's dismissed, so `isEnabled` alone is correct.
        guard alarm.isEnabled else {
            logger.info("Ignoring a notification for a disabled alarm")
            return
        }

        // Already answered this occurrence (e.g. a burst follow-up tapped
        // after the challenge was solved).
        if let dismissedAt = alarm.lastDismissedAt, dismissedAt >= firedAt {
            logger.debug("Alarm occurrence already dismissed; ignoring")
            return
        }

        beginRinging(alarm, firedAt: firedAt, markFired: true)
    }

    /// FIX (Pack 8): the expiry is now measured from the fire time of *this*
    /// occurrence.
    ///
    /// It used to call `scheduleExpiry(from: alarm.lastFiredAt ?? Date())`
    /// with the `alarm` value read *before* `markFired` wrote the new time.
    /// From the second firing onwards that value was yesterday's, so the
    /// remaining time came out as 30 minutes minus ~24 hours — negative — and
    /// the alarm was marked dismissed instantly without ever ringing. Only a
    /// brand-new alarm's first firing worked.
    private func beginRinging(_ alarm: Alarm, firedAt: Date, markFired: Bool) {
        var ringing = alarm
        if markFired {
            try? repository.markFired(ownerUserId: alarm.ownerUserId, id: alarm.id, at: firedAt)
            ringing.lastFiredAt = firedAt
        }

        ringingAlarm = ringing
        sendFailures = 0
        fallbackNotice = nil
        challengeError = nil

        challenge = makeChallenge(for: ringing)
        audio.start()
        scheduleExpiry(from: firedAt)
    }

    private func makeChallenge(for alarm: Alarm) -> Challenge {
        switch alarm.dismissalMode {
        case .tasks:
            return .tasks(completed: 0, required: max(1, alarm.requiredTaskCount), task: .random())

        case .messageContact:
            guard let peerId = alarm.accountabilityPeerId,
                  let peer = try? userRepository.fetch(ownerUserId: alarm.ownerUserId, id: peerId)
            else {
                fallbackNotice = "The contact for this alarm is no longer available, so it's asking for problems instead."
                return .tasks(completed: 0, required: max(1, alarm.requiredTaskCount), task: .random())
            }
            let username = peer.username.isEmpty ? String(peer.id.prefix(8)) : peer.username
            return .message(peerId: peerId, peerUsername: username, word: AlarmWord.random())
        }
    }

    private func scheduleExpiry(from firedAt: Date) {
        expiryTask?.cancel()
        let remaining = Self.autoExpiry - Date().timeIntervalSince(firedAt)
        guard remaining > 0 else {
            finishRinging()
            return
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishRinging()
        }
    }

    // MARK: Task challenge

    func submitTaskAnswer(_ input: String) {
        guard case .tasks(let completed, let required, let task) = challenge else { return }

        guard task.isCorrect(input) else {
            challengeError = "Not quite."
            // Regenerates the problem but keeps progress: resetting to zero
            // punishes a half-asleep slip; keeping the same numbers allows
            // brute force.
            challenge = .tasks(completed: completed, required: required, task: .random(excluding: task))
            return
        }

        challengeError = nil
        let next = completed + 1
        if next >= required {
            finishRinging()
        } else {
            challenge = .tasks(completed: next, required: required, task: .random(excluding: task))
        }
    }

    // MARK: Message challenge

    func submitWord(_ input: String) async {
        guard case .message(let peerId, let peerUsername, let word) = challenge,
              let alarm = ringingAlarm else { return }

        guard AlarmWord.matches(input, expected: word) else {
            challengeError = "That's not the word."
            return
        }

        challengeError = nil
        isSendingWord = true
        defer { isSendingWord = false }

        do {
            let conversation = try resolveConversation(with: peerId, ownerUserId: alarm.ownerUserId)
            try await sendMessageHandler?(word, conversation)
            finishRinging()
        } catch {
            sendFailures += 1
            logger.error("Couldn't send the alarm word: \(String(describing: type(of: error)), privacy: .public)")

            if sendFailures >= Self.sendFailuresBeforeFallback {
                // Airplane mode must not become the way out — fall back to
                // tasks, which need no network but still need you awake.
                fallbackNotice = """
                    Couldn't reach \(peerUsername) — the message wasn't delivered. \
                    Solve the problems instead to stop the alarm.
                    """
                challenge = .tasks(
                    completed: 0,
                    required: max(1, alarm.requiredTaskCount),
                    task: .random()
                )
            } else {
                challengeError = "Couldn't send that. Check your connection and try again."
            }
        }
    }

    /// Finds or locally creates the conversation with this contact — local-only
    /// because this runs exactly when connectivity is least certain.
    private func resolveConversation(with peerId: String, ownerUserId: String) throws -> Conversation {
        if let existing = try conversationRepository.findDirectConversation(
            ownerUserId: ownerUserId, userA: ownerUserId, userB: peerId
        ) {
            return existing
        }
        let participants = [ownerUserId, peerId]
        let conversation = Conversation(
            id: Conversation.deterministicId(participantIds: participants),
            ownerUserId: ownerUserId,
            participantIds: participants,
            isGroup: false,
            createdAt: Date()
        )
        try conversationRepository.upsert(conversation)
        return conversation
    }

    // MARK: Finishing

    /// FIX (Pack 8): the unused `dismissed:` parameter is gone — solved and
    /// expired alarms are deliberately recorded the same way, so an expired
    /// alarm doesn't resume on next launch.
    private func finishRinging() {
        expiryTask?.cancel()
        expiryTask = nil
        audio.stop()

        if let alarm = ringingAlarm {
            try? repository.markDismissed(ownerUserId: alarm.ownerUserId, id: alarm.id)
        }

        ringingAlarm = nil
        challenge = nil
        challengeError = nil
        fallbackNotice = nil
        sendFailures = 0

        reloadAlarms()
        Task { await scheduler.reschedule(alarms: alarms) }
    }

    /// Stops audio without resolving the challenge — used on sign-out.
    func stopForLogout() {
        expiryTask?.cancel()
        expiryTask = nil
        audio.stop()
        ringingAlarm = nil
        challenge = nil
        alarms = []
        scheduler.cancelAll()
    }
}
