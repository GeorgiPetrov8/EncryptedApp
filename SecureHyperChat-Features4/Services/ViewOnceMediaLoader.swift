import Foundation
import Network
import CryptoKit
import os

/// #12: loads a view-once photo/video **only while online**, decrypts it in
/// memory and never writes it to the media cache.
///
/// "Online" means our server answers — not just that Wi-Fi is on (a café Wi-Fi
/// without internet would pass the system check). While the viewer is open the
/// connection is re-checked every 5 s and on every network change; when it's
/// lost, `isConnected` turns false and the viewer closes. It still counts as
/// viewed (rule in `ConsumeOnViewPolicy`).
///
/// Videos need a file for `AVPlayer`: they're written to `ProtectedTemp`
/// (file protection, not backed up) and deleted when the viewer closes, and at
/// every launch in case of a crash.
@MainActor
final class ViewOnceMediaLoader: ObservableObject {
    enum LoadError: LocalizedError {
        case offline
        case expired
        case invalid

        var errorDescription: String? {
            switch self {
            case .offline: return "View-once photos and videos open only when you're online."
            case .expired: return "This view-once photo or video is no longer available."
            case .invalid: return "This view-once media couldn't be opened."
            }
        }
    }

    @Published private(set) var isConnected = true

    private let apiClient: APIClientProtocol
    private let cryptoService: CryptoService
    private let monitor = NWPathMonitor()
    private var probeTask: Task<Void, Never>?
    private var pathSatisfied = true
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "viewonce")

    init(apiClient: APIClientProtocol, cryptoService: CryptoService) {
        self.apiClient = apiClient
        self.cryptoService = cryptoService
    }

    /// Our server answers within 4 s.
    func serverReachable() async -> Bool {
        var request = URLRequest(url: NetworkConfiguration.baseURL.appendingPathComponent("healthz"))
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        TrustedClock.shared.record(response)
        return true
    }

    /// Downloads and decrypts. The server deletes the file after this download
    /// (upload uses `X-Media-Recipients: 1`).
    func load(_ message: Message) async throws -> Data {
        guard await serverReachable() else { throw LoadError.offline }
        guard let stored = try? cryptoService.decryptFromStorage(message.encryptedContent),
              let payload = try? MediaEncryptionService.decodeValidated(stored),
              SafeIdentifier.isMediaId(payload.mediaId) else { throw LoadError.invalid }
        let encrypted: Data
        do {
            encrypted = try await apiClient.downloadMedia(mediaId: payload.mediaId)
        } catch {
            throw (await serverReachable()) ? LoadError.expired : LoadError.offline
        }
        guard let plain = try? AESGCM.open(ciphertext: encrypted, key: SymmetricKey(data: payload.key)) else {
            throw LoadError.invalid
        }
        if payload.mediaType == .image, !ImageSafety.isAcceptable(plain) { throw LoadError.invalid }
        return plain
    }

    // MARK: Watching the connection while the viewer is open

    func startWatching() {
        isConnected = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathSatisfied = path.status == .satisfied
                if path.status != .satisfied { self?.isConnected = false }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.securehyperchat.viewonce.path"))
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.pathSatisfied { self.isConnected = false; return }
                if !(await self.serverReachable()) { self.isConnected = false; return }
            }
        }
    }

    func stopWatching() {
        probeTask?.cancel()
        probeTask = nil
        monitor.cancel()
    }
}
