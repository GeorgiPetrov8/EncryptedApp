import Foundation

struct RecoveryEmailStatus: Decodable, Equatable {
    struct BackupInfo: Decodable, Equatable {
        let sizeBytes: Int
        let updatedAt: Date
    }

    let email: String?
    let verified: Bool
    /// Address a verification code was just sent to, not yet confirmed.
    let pendingEmail: String?
    let backup: BackupInfo?
    /// NEW. `false` when the server has no email provider set up, so the app can
    /// say so instead of reporting a code as sent. Absent on older servers.
    var mailConfigured: Bool? = nil
}

struct RecoveryTicket: Decodable, Equatable {
    let ticket: String
    let userId: String
    let username: String
    let hasBackup: Bool
    let backupUpdatedAt: Date?
}

enum RecoveryAPIError: LocalizedError {
    case server(code: String, message: String)
    case notSignedIn
    case unexpected(Int)

    var errorDescription: String? {
        switch self {
        case .server(_, let message): return message
        case .notSignedIn: return "You're not signed in."
        case .unexpected(let status): return "The server responded unexpectedly (HTTP \(status))."
        }
    }

    var code: String? {
        if case .server(let code, _) = self { return code }
        return nil
    }
}

/// HTTP client for the recovery endpoints.
///
/// Separate from `APIClientProtocol` on purpose: half of these calls are made
/// while signed out (on a brand-new device), and none of them belong in the mock
/// backend.
final class RecoveryAPI {
    private let baseURL: URL
    private let tokenStore: SessionTokenStore
    private let session: URLSession

    init(tokenStore: SessionTokenStore, baseURL: URL = NetworkConfiguration.baseURL, session: URLSession = .shared) {
        self.tokenStore = tokenStore
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Signed in

    func emailStatus() async throws -> RecoveryEmailStatus {
        try await json("GET", "/account/email", auth: true)
    }

    /// Asks the server to send a verification code to `email`.
    ///
    /// The server now requires proof that this device holds the account's keys: a
    /// leaked session token alone could otherwise attach an attacker's address and
    /// take the account over through recovery. `prove` is the same signer used for
    /// `deleteAccountOnServer(prove:)` — it signs the server's one-time nonce with
    /// the identity key.
    func requestEmailCode(_ email: String, prove: ChallengeSigner) async throws {
        let challenge: LoginChallenge = try await json(
            "POST", "/account/challenge", body: [String: String](), auth: true
        )
        let signature = try await prove(challenge)
        try await send(
            "POST", "/account/email",
            body: [
                "email": email,
                "nonce": challenge.nonce,
                "signature": signature.base64EncodedString(),
            ],
            auth: true
        )
    }

    /// Unsigned variant. A server with the default configuration answers
    /// `proofRequired`; it only works against one run with
    /// `ALLOW_UNSIGNED_EMAIL_CHANGE=1`. Call sites should move to
    /// `requestEmailCode(_:prove:)`.
    @available(*, deprecated, message: "The server requires a signature from this device's key. Use requestEmailCode(_:prove:).")
    func requestEmailCode(_ email: String) async throws {
        try await send("POST", "/account/email", body: ["email": email], auth: true)
    }

    func verifyEmail(code: String) async throws {
        try await send("POST", "/account/email/verify", body: ["code": code], auth: true)
    }

    func removeEmail() async throws {
        try await send("POST", "/account/email/remove", body: [String: String](), auth: true)
    }

    func uploadBackup(_ data: Data) async throws {
        var request = try makeRequest("POST", "/backup", auth: true)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: request, from: data)
        try check(response, body)
    }

    func deleteBackup() async throws {
        try await send("POST", "/backup/delete", body: [String: String](), auth: true)
    }

    // MARK: Signed out

    func startRecovery(username: String) async throws {
        try await send("POST", "/recovery/start", body: ["username": username], auth: false)
    }

    func verifyRecovery(username: String, code: String) async throws -> RecoveryTicket {
        try await json("POST", "/recovery/verify", body: ["username": username, "code": code], auth: false)
    }

    func downloadBackup(ticket: String) async throws -> Data {
        var request = try makeRequest("GET", "/recovery/backup", auth: false)
        request.setValue(ticket, forHTTPHeaderField: "X-Recovery-Ticket")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return data
    }

    func rebind(ticket: String, bundle: PreKeyBundleUpload) async throws -> AuthToken {
        struct Body: Encodable { let ticket: String; let bundle: PreKeyBundleUpload }
        return try await json("POST", "/recovery/rebind", body: Body(ticket: ticket, bundle: bundle), auth: false)
    }

    // MARK: Plumbing

    private func makeRequest(_ method: String, _ path: String, auth: Bool) throws -> URLRequest {
        // FIX: `URL(string:relativeTo:)`, like `RealAPIClient` — not
        // `appendingPathComponent`, which mishandles a leading "/".
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw RecoveryAPIError.unexpected(0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if auth {
            guard let token = tokenStore.currentToken else { throw RecoveryAPIError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<B: Encodable>(_ method: String, _ path: String, body: B, auth: Bool) async throws {
        var request = try makeRequest(method, path, auth: auth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SecureHyperChatJSON.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    private func json<T: Decodable>(_ method: String, _ path: String, auth: Bool) async throws -> T {
        let request = try makeRequest(method, path, auth: auth)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try SecureHyperChatJSON.decoder.decode(T.self, from: data)
    }

    private func json<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B, auth: Bool) async throws -> T {
        var request = try makeRequest(method, path, auth: auth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SecureHyperChatJSON.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try SecureHyperChatJSON.decoder.decode(T.self, from: data)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RecoveryAPIError.unexpected(0) }
        guard !(200..<300).contains(http.statusCode) else { return }
        struct ErrorBody: Decodable { let error: String; let message: String? }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            throw RecoveryAPIError.server(code: body.error, message: body.message ?? body.error)
        }
        throw RecoveryAPIError.unexpected(http.statusCode)
    }
}
