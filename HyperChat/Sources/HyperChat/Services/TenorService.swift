import Foundation
import os

/// Kept so `AppContainer` (`let tenorService: TenorService`) compiles unchanged.
typealias TenorService = GIFService

/// GIF search through KLIPY (or GIPHY) — both speak the old Tenor v2 API.
///
/// FIX: Google shut the Tenor API down on June 30, 2026, and stopped issuing
/// new keys in January — every request now fails, which is why GIFs never
/// worked. KLIPY and GIPHY offer Tenor-compatible endpoints, so only the host
/// and the key change.
///
/// ## What changed in how GIFs are sent
///
/// Both providers require their media to be loaded straight from the URLs
/// they return — copying a GIF and re-uploading it (what the old code did) is
/// against their terms. So a GIF is now sent as a link inside the encrypted
/// message, and the recipient's phone loads it from the provider. The
/// recipient only does that automatically if they turned GIFs on themselves;
/// otherwise they see "tap to load", because loading reveals their IP address
/// to the provider.
///
/// ## Configuration (Info.plist)
///   GIF_API_KEY   — your KLIPY key (partner.klipy.com) or GIPHY key
///   GIF_API_HOST  — optional, default `api.klipy.com` (or `api.giphy.com`)
@MainActor
final class GIFService: ObservableObject {
    @Published private(set) var results: [GIFResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    /// Off by default. Covers both searching and auto-loading received GIFs.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    private let session: URLSession
    private let logger = Logger(subsystem: "com.HyperChat", category: "gif")
    private var searchTask: Task<Void, Never>?

    private enum Keys {
        static let enabled = "tenor.enabled" // unchanged so existing opt-ins carry over
    }

    /// Same value for every install — the providers ask for one, and a
    /// shared value can't be used to profile individual users.
    private static let clientKey = "hyperchat-ios"

    init(session: URLSession = .shared) {
        self.session = session
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    private var apiKey: String? {
        let info = Bundle.main.infoDictionary
        let key = (info?["GIF_API_KEY"] as? String) ?? (info?["TENOR_API_KEY"] as? String)
        guard let key, !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return key
    }

    var host: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "GIF_API_HOST") as? String
        guard let configured, !configured.isEmpty, !configured.hasPrefix("$(") else { return "api.klipy.com" }
        return configured
    }

    var providerID: String { host.contains("giphy") ? "giphy" : "klipy" }
    var providerName: String { providerID == "giphy" ? "GIPHY" : "KLIPY" }

    var isConfigured: Bool { apiKey != nil }

    // MARK: Search

    func search(_ query: String) {
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
        guard let apiKey else {
            errorMessage = "GIF search isn't configured in this build."
            return
        }

        isSearching = true
        defer { isSearching = false }
        errorMessage = nil

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = query.isEmpty ? "/v2/featured" : "/v2/search"
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "client_key", value: Self.clientKey),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "media_filter", value: "tinygif,mediumgif,gif"),
            URLQueryItem(name: "contentfilter", value: "medium"),
        ]
        if !query.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "q", value: query))
        }
        guard let url = components.url else { return }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(GIFSearchResponse.self, from: data)
                results = decoded.results.compactMap(GIFResult.init)
            case 401, 403:
                errorMessage = "The GIF API key was rejected. Check GIF_API_KEY."
            case 429:
                errorMessage = "Too many GIF searches right now. Try again in a little while."
            default:
                errorMessage = "GIF search is unavailable right now (HTTP \(http.statusCode))."
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("GIF search failed")
            errorMessage = "Couldn't load GIFs. Check your connection."
        }
    }

    func attachment(for gif: GIFResult) -> GIFAttachment {
        GIFAttachment(
            id: gif.id,
            url: gif.fullURL,
            previewURL: gif.mediumURL,
            width: gif.width,
            height: gif.height,
            provider: providerID
        )
    }

    func clear() {
        results = []
        errorMessage = nil
        searchTask?.cancel()
    }
}

struct GIFResult: Identifiable, Equatable {
    let id: String
    let previewURL: URL
    let mediumURL: URL?
    let fullURL: URL
    let width: Int
    let height: Int
    let description: String

    init?(_ result: GIFSearchResponse.Result) {
        let formats = result.media_formats
        guard let full = formats["gif"] ?? formats["mediumgif"] ?? formats["tinygif"],
              let fullURL = URL(string: full.url),
              let preview = formats["tinygif"] ?? formats["mediumgif"] ?? formats["gif"],
              let previewURL = URL(string: preview.url) else { return nil }
        self.id = result.id
        self.fullURL = fullURL
        self.previewURL = previewURL
        self.mediumURL = formats["mediumgif"].flatMap { URL(string: $0.url) } ?? previewURL
        self.width = full.dims?.first ?? 0
        self.height = (full.dims?.count ?? 0) > 1 ? full.dims![1] : 0
        self.description = result.content_description ?? "GIF"
    }
}

struct GIFSearchResponse: Decodable {
    struct MediaFormat: Decodable {
        let url: String
        let dims: [Int]?
    }
    struct Result: Decodable {
        let id: String
        let media_formats: [String: MediaFormat]
        let content_description: String?

        private enum CodingKeys: String, CodingKey { case id, media_formats, content_description }

        // Accepts numeric ids as well — providers don't all use strings.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? c.decode(String.self, forKey: .id) {
                id = text
            } else {
                id = String(try c.decode(Int64.self, forKey: .id))
            }
            media_formats = try c.decode([String: MediaFormat].self, forKey: .media_formats)
            content_description = try c.decodeIfPresent(String.self, forKey: .content_description)
        }
    }
    let results: [Result]
}
