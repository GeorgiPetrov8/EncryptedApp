import Foundation

/// Where the real backend lives, and how JSON is coded on the wire.
///
/// This is the one file you edit per environment. Everything else
/// (`RealAPIClient`, `RealWebSocketService`) reads from here rather than
/// hardcoding a host anywhere.
enum NetworkConfiguration {

    /// The REST base URL, e.g. `https://chat.example.com` in production or
    /// `http://127.0.0.1:8080` when running the bundled server locally.
    ///
    /// Sourced from the `API_BASE_URL` Info.plist key, which `project.yml`
    /// sets per build configuration (`Debug` → your dev machine, `Release` →
    /// your real domain) so switching environments never means editing
    /// source. Falls back to the local dev server if the key is somehow
    /// missing, rather than crashing at launch.
    /// Checked in order: a Run-scheme environment variable (fastest way to
    /// point one build at, say, a colleague's laptop or an ngrok tunnel
    /// without touching `project.yml`), then the Info.plist key, then a
    /// local-loopback fallback so a misconfigured build still does
    /// *something* sensible in the simulator.
    static var baseURL: URL {
        if let env = ProcessInfo.processInfo.environment["API_BASE_URL"], let url = URL(string: env) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
           let url = URL(string: raw), !raw.isEmpty {
            return url
        }
        return URL(string: "http://127.0.0.1:8080")!
    }

    /// Derives the WebSocket URL from `baseURL` — `https` → `wss`,
    /// `http` → `ws` — so there is exactly one place that knows the server's
    /// host, not two that have to be kept in sync by hand.
    static var webSocketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/ws"
        return components.url!
    }

    /// Toggles between the in-memory `MockAPIClient`/`MockWebSocketService`
    /// (useful for UI development and previews with no server running) and
    /// the real network stack.
    ///
    /// Controlled by the `USE_MOCK_BACKEND` Info.plist key so it can differ
    /// per scheme without a source change; defaults to `false` (real
    /// backend) so a build that forgets to set the key fails safe towards
    /// "actually try to talk to a server" rather than silently mocking.
    ///
    /// Read as a *string* ("YES"/"NO"), not a plist Boolean: `project.yml`
    /// sets this via `$(USE_MOCK_BACKEND)` xcconfig-style variable
    /// substitution into Info.plist, and Xcode's substitution is reliably a
    /// text replacement — coercing that into a plist `<true/>`/`<false/>`
    /// boolean node is finicky in ways a plain string comparison sidesteps
    /// entirely.
    static var useMockBackend: Bool {
        if let env = ProcessInfo.processInfo.environment["USE_MOCK_BACKEND"] {
            return env.caseInsensitiveCompare("YES") == .orderedSame || env == "1"
        }
        let raw = Bundle.main.object(forInfoDictionaryKey: "USE_MOCK_BACKEND") as? String
        return raw?.caseInsensitiveCompare("YES") == .orderedSame
    }
}

/// The single JSON encoder/decoder pair every network type in this file uses.
///
/// FIX: the ISO-8601 date pitfall.
///
/// `JSONDecoder.dateDecodingStrategy = .iso8601` looks like the obvious
/// choice, but its default `ISO8601DateFormatter` does **not** include
/// `.withFractionalSeconds`. The server's `new Date().toISOString()` always
/// emits milliseconds (`"2024-01-01T12:00:00.000Z"`), so decoding any
/// server-supplied date with the vanilla `.iso8601` strategy throws
/// "Date string does not match format expected by formatter" — a real,
/// silent failure this project would only have discovered against a live
/// server, not by reading the Swift by itself. The custom strategy below
/// tries with-fractional-seconds first and falls back to without, so it
/// round-trips both what the server sends and what this client itself
/// encodes.
///
/// `Data` fields are left on the default `.base64` strategy, which matches
/// every base64 string field the server reads and writes.
enum SecureChatJSON {
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
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 date, got: \(raw)"
            )
        }
        return decoder
    }()
}
