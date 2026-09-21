import Foundation
import os

/// `Data` fields you serialize into a request body must match the server's
/// expected shape exactly (see `SecureChat-RealBackend/README.md` for the
/// full route table). This type owns exactly that: turning `APIClientProtocol`
/// calls into HTTP requests against the Node relay in `SecureChatServer/`.
final class RealAPIClient: APIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let tokenStore: SessionTokenStore
    private let logger = Logger(subsystem: "com.securechat", category: "network")

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

    func login(username: String) async throws -> AuthToken {
        try await post("/auth/login", body: ["username": username], auth: false)
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
        // `userId` is accepted for source compatibility with `APIClientProtocol`
        // but the server derives the actual recipient from the bearer token —
        // it will 403 rather than trust a client-supplied id here, so passing
        // anything other than the signed-in account's own id is pointless.
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
        return try SecureChatJSON.decoder.decode(MediaUploadResult.self, from: responseData)
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
            return try SecureChatJSON.decoder.decode(Response.self, from: data)
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
        request.httpBody = try SecureChatJSON.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: expectedStatus, allowRange: true)
        do {
            return try SecureChatJSON.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Decode failure for POST \(path, privacy: .public)")
            throw NetworkError.decodingFailed(error)
        }
    }

    /// For endpoints that respond `204 No Content` (or `202` for a fire-and-forget
    /// accept) with no body to decode.
    private func postNoContent<Body: Encodable>(
        _ path: String,
        body: Body,
        expectedStatus: Int = 204
    ) async throws {
        var request = try makeRequest(path: path, method: "POST", auth: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SecureChatJSON.encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, expectedStatus: expectedStatus, allowRange: true)
    }

    /// Maps a non-2xx response to `APIError` where the server's `error` code
    /// matches one of the mock's existing cases, so callers written against
    /// `MockAPIClient`'s errors don't have to change at all.
    private func validate(
        _ response: URLResponse,
        data: Data,
        expectedStatus: Int,
        allowRange: Bool = false
    ) throws {
        guard let http = response as? HTTPURLResponse else { throw NetworkError.notHTTP }

        let ok = allowRange ? (200..<300).contains(http.statusCode) : http.statusCode == expectedStatus
        guard !ok else { return }

        if let body = try? SecureChatJSON.decoder.decode(ServerErrorBody.self, from: data) {
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

/// Errors specific to talking to a real network, distinct from `APIError`
/// (which describes what the *mock* could fail with). Kept separate rather
/// than folded into `APIError` so call sites that only ever ran against the
/// mock don't suddenly need to handle "the TLS handshake failed" — those
/// call sites already treat any thrown error generically via
/// `LocalizedError.errorDescription`, so this only needs a description, not
/// special-casing everywhere.
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
