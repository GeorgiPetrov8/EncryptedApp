import Foundation
import os

/// `APIClientProtocol` over HTTPS against the Node relay.
final class RealAPIClient: APIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.HyperChat", category: "network")

    init(
        baseURL: URL = NetworkConfiguration.baseURL,
        tokenStore: SessionTokenStore,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.session = session
    }

    // MARK: Auth

    func register(username: String, bundle: PreKeyBundleUpload) async throws -> AuthToken {
        try await post("/auth/register", body: RegisterRequest(username: username, bundle: bundle), auth: false)
    }

    /// The server no longer accepts username-only login.
    func login(username: String) async throws -> AuthToken {
        throw NetworkError.server(status: 400, code: "badRequest", message: "Sign-in requires the device's keys.")
    }

    func login(username: String, prove: ChallengeSigner) async throws -> AuthToken {
        let challenge: LoginChallenge = try await post(
            "/auth/login/challenge", body: ["username": username], auth: false
        )
        let signature = try await prove(challenge)
        return try await post(
            "/auth/login",
            body: SignedChallenge(username: username, nonce: challenge.nonce, signature: signature.base64EncodedString()),
            auth: false
        )
    }

    // MARK: Account

    func deleteAccountOnServer(prove: ChallengeSigner) async throws {
        let challenge: LoginChallenge = try await post("/account/delete/challenge", body: [String: String]())
        let signature = try await prove(challenge)
        try await postNoContent(
            "/account/delete",
            body: ["nonce": challenge.nonce, "signature": signature.base64EncodedString()]
        )
    }

    func registerPushToken(_ token: String, environment: String) async throws {
        try await postNoContent("/devices/push-token", body: ["token": token, "environment": environment])
    }

    func removePushToken(_ token: String, bearer: String) async throws {
        var request = try makeRequest(path: "/devices/push-token/remove", method: "POST", auth: false)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HyperChatJSON.encoder.encode(["token": token])
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: 204, allowRange: true)
    }

    // MARK: Prekeys

    func replenishOneTimePreKeys(userId: String, keys: [OneTimePreKeyPublic]) async throws {
        try await postNoContent("/prekeys/one-time", body: ReplenishRequest(userId: userId, keys: keys))
    }

    func publishSignedPreKey(_ upload: SignedPreKeyUpload) async throws {
        try await postNoContent("/prekeys/signed", body: upload)
    }

    func fetchDirectoryEntry(userId: String) async throws -> DirectoryEntry {
        try await get("/directory/by-id/\(percentEncoded(userId))")
    }

    func fetchDirectoryEntry(username: String) async throws -> DirectoryEntry {
        try await get("/directory/by-username/\(percentEncoded(username))")
    }

    func fetchPreKeyBundle(forUsername username: String) async throws -> PreKeyBundle {
        try await get("/bundles/by-username/\(percentEncoded(username))")
    }

    func fetchPreKeyBundle(forUserId userId: String) async throws -> PreKeyBundle {
        try await get("/bundles/by-id/\(percentEncoded(userId))")
    }

    // MARK: Messaging

    func sendMessage(_ envelope: EnvelopeDTO) async throws {
        try await postNoContent("/messages", body: envelope, expectedStatus: 202)
    }

    func fetchEnvelopes(conversationId: String) async throws -> [EnvelopeDTO] {
        try await get("/messages?conversationId=\(percentEncoded(conversationId))")
    }

    func fetchPendingEnvelopes(userId: String, since cursor: Int) async throws -> PendingEnvelopesPage {
        // The server derives the recipient from the bearer token.
        try await get("/messages/pending?since=\(cursor)")
    }

    func acknowledge(userId: String, envelopeIds: [String]) async throws {
        guard !envelopeIds.isEmpty else { return }
        try await postNoContent("/messages/ack", body: ["envelopeIds": envelopeIds])
    }

    // MARK: Media

    func uploadMedia(data: Data) async throws -> MediaUploadResult {
        var request = try makeRequest(path: "/media", method: "POST", auth: true)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try validate(response, data: responseData, expectedStatus: 201)
        return try HyperChatJSON.decoder.decode(MediaUploadResult.self, from: responseData)
    }

    func downloadMedia(mediaId: String) async throws -> Data {
        let request = try makeRequest(path: "/media/\(percentEncoded(mediaId))", method: "GET", auth: true)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: 200)
        return data
    }

    // MARK: Request plumbing

    private func makeRequest(path: String, method: String, auth: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw NetworkError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if auth {
            guard let token = tokenStore.currentToken else {
                throw NetworkError.missingSessionToken
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        let request = try makeRequest(path: path, method: "GET", auth: true)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: 200)
        do {
            return try HyperChatJSON.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Decode failure for GET \(path, privacy: .public)")
            throw NetworkError.decodingFailed(error)
        }
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        auth: Bool = true,
        expectedStatus: Int = 200
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST", auth: auth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HyperChatJSON.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: expectedStatus, allowRange: true)
        do {
            return try HyperChatJSON.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Decode failure for POST \(path, privacy: .public)")
            throw NetworkError.decodingFailed(error)
        }
    }

    private func postNoContent<Body: Encodable>(
        _ path: String,
        body: Body,
        expectedStatus: Int = 204
    ) async throws {
        var request = try makeRequest(path: path, method: "POST", auth: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try HyperChatJSON.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: expectedStatus, allowRange: true)
    }

    private func validate(
        _ response: URLResponse,
        data: Data,
        expectedStatus: Int,
        allowRange: Bool = false
    ) throws {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.notHTTP }

        let ok = allowRange ? (200..<300).contains(http.statusCode) : http.statusCode == expectedStatus
        guard !ok else { return }

        if let body = try? HyperChatJSON.decoder.decode(ServerErrorBody.self, from: data) {
            switch body.error {
            case "usernameTaken": throw APIError.usernameTaken
            case "userNotFound": throw APIError.userNotFound
            case "mediaNotFound": throw APIError.mediaNotFound
            case "notAuthenticated": throw APIError.notAuthenticated
            case "forbidden": throw NetworkError.forbidden(body.message)
            case "rateLimited": throw NetworkError.rateLimited(body.message)
            default: throw NetworkError.server(status: http.statusCode, code: body.error, message: body.message)
            }
        }
        throw NetworkError.unexpectedStatus(http.statusCode)
    }

    private func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private struct ServerErrorBody: Decodable {
    let error: String
    let message: String
}

private struct ReplenishRequest: Encodable {
    let userId: String
    let keys: [OneTimePreKeyPublic]
}

private struct SignedChallenge: Encodable {
    let username: String
    let nonce: String
    let signature: String
}

enum NetworkError: LocalizedError {
    case invalidURL(String)
    case missingSessionToken
    case notHTTP
    case unexpectedStatus(Int)
    case decodingFailed(Error)
    case forbidden(String)
    case rateLimited(String)
    case server(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "Couldn't build a request for \(path)."
        case .missingSessionToken:
            return "You're not signed in."
        case .notHTTP:
            return "Unexpected response from the server."
        case .unexpectedStatus(let status):
            return "The server responded unexpectedly (HTTP \(status))."
        case .decodingFailed:
            return "The server's response couldn't be understood. Try updating the app."
        case .forbidden(let message):
            return message.isEmpty ? "That action isn't allowed." : message
        case .rateLimited(let message):
            return message.isEmpty ? "Too many requests. Try again shortly." : message
        case .server(_, _, let message):
            return message
        }
    }
}
