import Foundation
import os

/// GIF search via Tenor (feature: GIFs, Discord-style).
///
/// ## The privacy decision that shapes this file
///
/// Tenor is Google. Every search query and every GIF fetch tells them what a
/// user is looking for and, by IP, roughly who and where they are. In an app
/// whose premise is that even *our own* server learns nothing, silently
/// routing queries to Google would be a contradiction.
///
/// So:
///
/// 1. **The GIF is re-uploaded through the normal encrypted media path.** The
///    recipient never contacts Tenor at all — they receive an encrypted blob
///    like any other attachment. Without this, every recipient's IP would leak
///    to Google on every GIF, and the GIF's Tenor URL would sit in plaintext
///    inside the message.
/// 2. **Searching is opt-in and disclosed**, with the reason stated in the UI
///    rather than buried here.
/// 3. **Requests carry no user identifier.** Tenor accepts a `client_key` for
///    per-app analytics; it is deliberately not sent.
///
/// The cost is bandwidth — the sender downloads then re-uploads, and the same
/// GIF sent twice is stored twice. That is the right trade against leaking the
/// recipient's IP to a third party they never chose to talk to.
@MainActor
final class TenorService: ObservableObject {

    @Published private(set) var results: [TenorGIF] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    /// Off by default. A user who never opens the GIF picker never contacts
    /// Tenor, and the toggle in Settings says plainly what enabling it means.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    private let session: URLSession
    private let logger = Logger(subsystem: "com.HyperChat", category: "tenor")
    private var searchTask: Task<Void, Never>?

    private enum Keys {
        static let enabled = "tenor.enabled"
    }

    /// Supplied via Info.plist rather than hardcoded, so the key isn't in the
    /// repository. Tenor keys are not secret in the cryptographic sense — the
    /// client must present one — but they are rate-limited per key, so leaking
    /// one invites having your quota burned by strangers.
    private var apiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "TENOR_API_KEY") as? String
    }

    init(session: URLSession = .shared) {
        self.session = session
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    var isConfigured: Bool { apiKey?.isEmpty == false }

    // MARK: Search

    func search(_ query: String) {
        // Debounced: a search-as-you-type field would otherwise fire a request
        // per keystroke, which is both wasteful and a finer-grained disclosure
        // of what the user is typing than the finished query.
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    private func performSearch(_ query: String) async {
        guard isEnabled else { return }
        guard let apiKey, !apiKey.isEmpty else {
            errorMessage = "GIF search isn't configured in this build."
            return
        }

        isSearching = true
        defer { isSearching = false }
        errorMessage = nil

        let endpoint = query.isEmpty ? "featured" : "search"
        var components = URLComponents(string: "https://tenor.googleapis.com/v2/\(endpoint)")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "limit", value: "30"),
            // `tinygif` is the small preview for the grid; `gif` is the full
            // one, fetched only when the user actually picks something.
            URLQueryItem(name: "media_filter", value: "tinygif,gif"),
            // Tenor's default is permissive. A GIF picker in a messaging app
            // shouldn't surface explicit results by accident.
            URLQueryItem(name: "contentfilter", value: "medium"),
        ]
        if !query.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "q", value: query))
        }
        // Deliberately absent: `client_key`, which would let Tenor correlate
        // searches across sessions into a per-install profile.

        guard let url = components.url else { return }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "GIF search is unavailable right now."
                return
            }
            let decoded = try JSONDecoder().decode(TenorResponse.self, from: data)
            results = decoded.results.compactMap(TenorGIF.init)
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Tenor search failed")
            errorMessage = "Couldn't load GIFs. Check your connection."
        }
    }

    /// Downloads the full-size GIF so it can go through the normal encrypted
    /// attachment path.
    func downloadGIFData(_ gif: TenorGIF) async throws -> Data {
        let (data, response) = try await session.data(from: gif.fullURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TenorError.downloadFailed
        }
        // Validated like any other attachment rather than trusted because it
        // came from a known host — a compromised or misconfigured CDN
        // response shouldn't bypass the allow-list.
        switch AttachmentPolicy.inspect(data: data, declaredExtension: "gif") {
        case .success(let accepted) where accepted.category == .image:
            return data
        default:
            throw TenorError.notAnImage
        }
    }

    func clear() {
        results = []
        errorMessage = nil
        searchTask?.cancel()
    }
}

struct TenorGIF: Identifiable, Equatable {
    let id: String
    let previewURL: URL
    let fullURL: URL
    let width: Int
    let height: Int
    /// Tenor supplies a short description; used as the accessibility label,
    /// since a GIF is otherwise opaque to VoiceOver.
    let description: String

    var aspectRatio: Double {
        guard height > 0 else { return 1 }
        return Double(width) / Double(height)
    }

    init?(_ result: TenorResponse.Result) {
        guard let preview = result.media_formats["tinygif"] ?? result.media_formats["gif"],
              let full = result.media_formats["gif"] ?? result.media_formats["tinygif"],
              let previewURL = URL(string: preview.url),
              let fullURL = URL(string: full.url) else { return nil }

        self.id = result.id
        self.previewURL = previewURL
        self.fullURL = fullURL
        self.width = full.dims.first ?? 0
        self.height = full.dims.count > 1 ? full.dims[1] : 0
        self.description = result.content_description ?? "GIF"
    }
}

struct TenorResponse: Decodable {
    struct MediaFormat: Decodable {
        let url: String
        let dims: [Int]
    }
    struct Result: Decodable {
        let id: String
        let media_formats: [String: MediaFormat]
        let content_description: String?
    }
    let results: [Result]
}

enum TenorError: LocalizedError {
    case downloadFailed
    case notAnImage

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Couldn't download that GIF."
        case .notAnImage: return "That file wasn't a valid GIF."
        }
    }
}
