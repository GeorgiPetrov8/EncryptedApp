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

    /// Set by `AppContainer` after construction, same pattern as
    /// `NotePadService.setSendHandler` — `MessagingService` is built after
    /// this service, so the dependency can't go through the initializer
    /// without a cycle.
    private var sendMessageHandler: ((String, Conversation) async throws -> Void)?

    /// An alarm nobody engages with eventually gives up.
    ///
    /// Without this, a phone left ringing in an empty flat loops audio and
    /// haptics until the battery dies. Thirty minutes is long enough that a
    /// genuinely sound sleeper still gets woken, short enough that it isn't
    /// destructive. It also bounds the "resume after force-quit" window, so
    /// an alarm from this morning can't ambush you at lunchtime.
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

    /// Called when an account becomes active, and whenever the app
    /// foregrounds.
    ///
    /// The foreground call matters for two separate reasons: it refreshes
    /// the burst notifications for the next occurrence (see
    /// `AlarmScheduler`), and it re-checks for an alarm that fired while
    /// the app was closed.
    func activate() async {
        guard let ownerUserId = authService.currentUserId else { return }

        notificationsAuthorized = await scheduler.authorizationStatus() == .authorized
        reloadAlarms()
        pruneDeletedAccountabilityContacts(ownerUserId: ownerUserId)
        await scheduler.reschedule(alarms: alarms)
        resumeRingingIfNeeded(ownerUserId: ownerUserId)
    }

    func requestNotificationPermission() async {
        notificationsAuthorized = await scheduler.requestAuthorization()
        await scheduler.reschedule(alarms: alarms)
    }

    func reloadAlarms() {
        guard let ownerUserId = authService.currentUserId else { return }
        alarms = (try? repository.fetchAll(ownerUserId: ownerUserId)) ?? []
    }

    /// An alarm pointing at a deleted contact can't be silenced by messaging
    /// them, so it's downgraded to a task challenge rather than left
    /// unsilenceable. See `Alarm.accountabilityPeerId` for why this is an
    /// explicit sweep instead of a cascading foreign key.
    private func pruneDeletedAccountabilityContacts(ownerUserId: String) {
        let existing = Set(((try? userRepository.fetchAll(ownerUserId: ownerUserId)) ?? []).map(\.id))
        try? repository.clearMissingAccountabilityPeers(ownerUserId: ownerUserId, existingPeerIds: existing)
        reloadAlarms()
    }

    /// Restores a ringing alarm after the app was force-quit mid-challenge.
    ///
    /// Swiping the app away is otherwise the one bypass that needs no
    /// thought at all, which would make the entire feature decorative.
    private func resumeRingingIfNeeded(ownerUserId: String) {
        guard ringingAlarm == nil,
              let unresolved = try? repository.fetchUnresolvedRinging(
                  ownerUserId: ownerUserId, window: Self.autoExpiry
              )
        else { return }
        logger.info("Resuming an alarm that was still ringing before the app closed")
        beginRinging(unresolved, markFired: false)
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

    /// True when enabling one more alarm would exceed what iOS will
    /// actually schedule — surfaced in the UI rather than letting the
    /// overflow vanish silently.
    var isAtEnabledLimit: Bool { enabledCount >= AlarmScheduler.maxEnabledAlarms }

    // MARK: Ringing

    /// Entry point from a tapped notification, or from the in-app check
    /// that runs when the app opens at a time an alarm should be ringing.
    func fireAlarm(id: String) {
        guard ringingAlarm == nil,
              let ownerUserId = authService.currentUserId,
              let alarm = try? repository.fetch(ownerUserId: ownerUserId, id: id)
        else { return }
        beginRinging(alarm, markFired: true)
    }

    private func beginRinging(_ alarm: Alarm, markFired: Bool) {
        ringingAlarm = alarm
        sendFailures = 0
        fallbackNotice = nil
        challengeError = nil

        if markFired {
            try? repository.markFired(ownerUserId: alarm.ownerUserId, id: alarm.id)
        }

        challenge = makeChallenge(for: alarm)
        audio.start()
        scheduleExpiry(from: alarm.lastFiredAt ?? Date())
    }

    private func makeChallenge(for alarm: Alarm) -> Challenge {
        switch alarm.dismissalMode {
        case .tasks:
            return .tasks(completed: 0, required: max(1, alarm.requiredTaskCount), task: .random())

        case .messageContact:
            guard let peerId = alarm.accountabilityPeerId,
                  let peer = try? userRepository.fetch(ownerUserId: alarm.ownerUserId, id: peerId)
            else {
                // The contact is gone despite the sweep above (deleted
                // between sweep and fire). Degrade rather than present an
                // impossible challenge.
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
            finishRinging(dismissed: false)
            return
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finishRinging(dismissed: false) }
        }
    }

    // MARK: Task challenge

    func submitTaskAnswer(_ input: String) {
        guard case .tasks(let completed, let required, let task) = challenge else { return }

        guard task.isCorrect(input) else {
            challengeError = "Not quite."
            // A wrong answer regenerates the problem but keeps the progress
            // counter. Resetting to zero punishes a genuine half-asleep slip
            // far out of proportion; leaving the same numbers up would let
            // someone brute-force a single problem by typing nearby values.
            // Regenerating blocks the brute force without the cruelty.
            challenge = .tasks(completed: completed, required: required, task: .random(excluding: task))
            return
        }

        challengeError = nil
        let next = completed + 1
        if next >= required {
            finishRinging(dismissed: true)
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
            finishRinging(dismissed: true)
        } catch {
            sendFailures += 1
            logger.error("Couldn't send the alarm word: \(String(describing: type(of: error)), privacy: .public)")

            if sendFailures >= Self.sendFailuresBeforeFallback {
                // Falling back to tasks rather than just letting the alarm
                // stop is the whole reason this branch exists. Airplane
                // mode is the obvious way to defeat a message-based alarm —
                // switch it on, the send can't succeed, and if failure meant
                // dismissal the challenge would be worth nothing. Tasks
                // still require being awake, and they need no network.
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

    /// Finds the existing conversation with this contact, or creates one
    /// locally.
    ///
    /// Local-only on purpose: `MessagingService.startConversation` does a
    /// directory lookup over the network, and this runs at the exact moment
    /// connectivity is least certain. The deterministic conversation id
    /// means a locally-created conversation converges with the peer's own
    /// anyway, so nothing is lost by not asking the server.
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

    private func finishRinging(dismissed: Bool) {
        expiryTask?.cancel()
        expiryTask = nil
        audio.stop()

        if let alarm = ringingAlarm {
            // Recorded whether or not the challenge was completed: an
            // expired alarm must not resume on next launch, or a
            // 6am alarm nobody answered would reappear whenever the app is
            // next opened.
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

    /// Stops audio without resolving the challenge — used when the account
    /// signs out mid-alarm, where continuing to ring for a user who is no
    /// longer signed in makes no sense.
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
