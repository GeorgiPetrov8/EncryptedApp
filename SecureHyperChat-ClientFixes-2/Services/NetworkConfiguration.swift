import Foundation

/// Where the real backend lives, and how JSON is coded on the wire.
///
/// FIX (D8): in Release builds
///   - the `API_BASE_URL` / `USE_MOCK_BACKEND` environment overrides are ignored
///     (they exist for Xcode Run schemes only);
///   - a missing or non-HTTPS base URL is a configuration error, not a silent
///     fall-back to `http://127.0.0.1:8080`;
///   - the mock backend can't be switched on.
enum NetworkConfiguration {

    static var baseURL: URL {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["API_BASE_URL"], let url = URL(string: env) {
            return url
        }
        #endif
        if let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           !raw.isEmpty, !raw.hasPrefix("$("),
           let url = URL(string: raw) {
            #if DEBUG
            return url
            #else
            if url.scheme == "https" { return url }
            #endif
        }
        #if DEBUG
        return URL(string: "http://127.0.0.1:8080")!
        #else
        // A Release build without a valid https URL must not talk to anything.
        // An unroutable address makes every request fail visibly instead.
        return URL(string: "https://invalid.invalid")!
        #endif
    }

    static var webSocketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/ws"
        return components.url!
    }

    static var useMockBackend: Bool {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["USE_MOCK_BACKEND"] {
            return env.caseInsensitiveCompare("YES") == .orderedSame || env == "1"
        }
        let raw = Bundle.main.object(forInfoDictionaryKey: "USE_MOCK_BACKEND") as? String
        return raw?.caseInsensitiveCompare("YES") == .orderedSame
        #else
        return false
        #endif
    }

    /// FIX (S25): one URL session for the API — no disk cache (responses carry
    /// ciphertext and metadata), sensible timeouts, no cookies.
    static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

/// The single JSON encoder/decoder pair every network type uses (fractional
/// ISO-8601 seconds, see history).
enum SecureHyperChatJSON {
    private static let formatterWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let formatterWithoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatterWithFraction.string(from: date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = formatterWithFraction.date(from: raw) { return date }
            if let date = formatterWithoutFraction.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected ISO-8601 date, got: \(raw)")
        }
        return decoder
    }()
}
