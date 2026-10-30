import Foundation

struct RecoveryEmailStatus: Decodable, Equatable {
    struct BackupInfo: Decodable, Equatable {
        let sizeBytes: Int
        let updatedAt: Date
    }
    struct PendingRecovery: Decodable, Equatable {
        let availableAt: Date
    }

    let email: String?
    let verified: Bool
    let pendingEmail: String?
    let backup: BackupInfo?
    var mailConfigured: Bool? = nil
    /// NEW (S2): someone started recovering this account with new keys. Show a
    /// warning with a "Cancel" button (`RecoveryAPI.cancelRecovery`).
    var recoveryPending: PendingRecovery? = nil
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
/// Server v2: changing or removing the recovery email and deleting the server
/// backup all require a signature from this device's identity key (S10), so a
/// stolen session token alone can't undo your recovery set-up.
final class RecoveryAPI {
    private let baseURL: URL
    private let tokenStore: SessionTokenStore
    private let session: URLSession

    init(tokenStore: SessionTokenStore, baseURL: URL = NetworkConfiguration.baseURL, session: URLSession = NetworkConfiguration.apiSession) {
        self.tokenStore = tokenStore
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Signed in

    func emailStatus() async throws -> RecoveryEmailStatus {
        try await json("GET", "/account/email", auth: true)
    }

    func requestEmailCode(_ email: String, prove: ChallengeSigner) async throws {
        var body = try await proof(prove)
        body["email"] = email
        try await send("POST", "/account/email", body: body, auth: true)
    }

    func verifyEmail(code: String) async throws {
        try await send("POST", "/account/email/verify", body: ["code": code], auth: true)
    }

    func removeEmail(prove: ChallengeSigner) async throws {
        try await send("POST", "/account/email/remove", body: try await proof(prove), auth: true)
    }

    func uploadBackup(_ data: Data) async throws {
        var request = try makeRequest("POST", "/backup", auth: true)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: request, from: data)
        try check(response, body)
    }

    func deleteBackup(prove: ChallengeSigner) async throws {
        try await send("POST", "/backup/delete", body: try await proof(prove), auth: true)
    }

    /// NEW (S2): stops a recovery someone started elsewhere.
    func cancelRecovery() async throws {
        try await send("POST", "/recovery/cancel", body: [String: String](), auth: true)
    }

    /// `{ nonce, signature }` for the server's one-time challenge.
    private func proof(_ prove: ChallengeSigner) async throws -> [String: String] {
        let challenge: LoginChallenge = try await json("POST", "/account/challenge", body: [String: String](), auth: true)
        let signature = try await prove(challenge)
        return ["nonce": challenge.nonce, "signature": signature.base64EncodedString()]
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

    /// May fail with code `recoveryPending` (HTTP 423): the account is in use on
    /// another device; the message says when it becomes possible.
    func rebind(ticket: String, bundle: PreKeyBundleUpload) async throws -> AuthToken {
        struct Body: Encodable { let ticket: String; let bundle: PreKeyBundleUpload }
        return try await json("POST", "/recovery/rebind", body: Body(ticket: ticket, bundle: bundle), auth: false)
    }

    // MARK: Plumbing

    private func makeRequest(_ method: String, _ path: String, auth: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw RecoveryAPIError.unexpected(0) }
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
