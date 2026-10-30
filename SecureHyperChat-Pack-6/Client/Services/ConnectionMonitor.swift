import Foundation
import Network
import Combine
import os

extension Notification.Name {
    /// Posted by `RealWebSocketService`. `userInfo["connected"]` is a Bool.
    static let webSocketStateChanged = Notification.Name("SecureHyperChat.webSocketStateChanged")
}

/// Keeps the app connected without the user doing anything (#2).
///
/// Before, after the phone slept or changed network, the WebSocket could sit in
/// a long back-off (up to 60 s) or the listener could have stopped altogether,
/// and the only fix was Settings → "Reconnect". Now it reconnects
///   - when the app comes to the foreground,
///   - when the network comes back or changes (Wi-Fi ↔ mobile),
///   - every 15 s while the app is open and not connected,
/// and fetches anything that arrived in the meantime.
@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isOnline = true

    private let messagingService: MessagingService
    private let authService: AuthService
    private let webSocketService: WebSocketServiceProtocol
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.HyperChat.network")
    private var watchdog: Timer?
    private var isActive = true
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "connection")

    init(messagingService: MessagingService, authService: AuthService, webSocketService: WebSocketServiceProtocol) {
        self.messagingService = messagingService
        self.authService = authService
        self.webSocketService = webSocketService

        NotificationCenter.default.publisher(for: .webSocketStateChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.isConnected = (note.userInfo?["connected"] as? Bool) ?? false
            }
            .store(in: &cancellables)

        authService.$currentUserId
            .removeDuplicates()
            .sink { [weak self] userId in
                if userId == nil { self?.isConnected = false }
            }
            .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let changed = self.isOnline != online
                self.isOnline = online
                if online && (changed || !self.isConnected) {
                    self.logger.info("Network available; reconnecting")
                    self.reconnect()
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
        startWatchdog()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: App lifecycle

    func appBecameActive() {
        isActive = true
        startWatchdog()
        reconnect()
        guard let userId = authService.currentUserId, !messagingService.isSyncing else { return }
        Task { await messagingService.backfillPendingEnvelopes(myUserId: userId) }
    }

    func appWentToBackground() {
        isActive = false
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: Reconnecting

    /// Starts the listener if it stopped, otherwise wakes a sleeping reconnect
    /// loop so it tries immediately.
    func reconnect() {
        guard authService.currentUserId != nil, isOnline else { return }
        if !messagingService.isListening {
            messagingService.startListening()
        } else if !isConnected {
            (webSocketService as? RealWebSocketService)?.reconnectNow()
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, !self.isConnected else { return }
                self.reconnect()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}
