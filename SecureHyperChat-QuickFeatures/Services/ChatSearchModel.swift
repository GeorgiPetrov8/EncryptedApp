import Foundation
import SwiftUI
import Combine

/// #6: search inside the open chat.
///
/// Message bodies are encrypted in the database, so there is no SQL search.
/// When search opens, the chat's text messages are decrypted once into a small
/// in-memory index (id + folded text). It's dropped when search closes, and
/// nothing is written anywhere. Only the open conversation is ever indexed —
/// a cross-chat index would hold every conversation's plaintext in memory.
///
/// Matching ignores case and accents ("cafe" finds "Café"). Results run newest
/// first: ↑ goes to older matches, ↓ to newer.
@MainActor
final class ChatSearchModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var matches: [String] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isIndexing = false

    static let minimumQueryLength = 2
    private static let maxMatches = 500

    private let messageRepository: MessageRepository
    private let messagingService: MessagingService
    private var index: [(id: String, text: String)] = []
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    init(messageRepository: MessageRepository, messagingService: MessagingService) {
        self.messageRepository = messageRepository
        self.messagingService = messagingService
    }

    var currentMatchId: String? {
        matches.indices.contains(currentIndex) ? matches[currentIndex] : nil
    }

    /// "3 of 12", or "No results".
    var statusText: String {
        guard query.count >= Self.minimumQueryLength else { return "" }
        if isIndexing { return "Searching…" }
        if matches.isEmpty { return "No results" }
        return "\(currentIndex + 1) of \(matches.count)\(matches.count == Self.maxMatches ? "+" : "")"
    }

    /// The term to highlight in bubbles (nil when too short).
    var highlightTerm: String? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.count >= Self.minimumQueryLength ? term : nil
    }

    func start(conversationId: String, ownerUserId: String) {
        stop()
        isIndexing = true
        indexTask = Task { [weak self] in
            guard let self else { return }
            let messages = (try? self.messageRepository.fetchMessages(
                conversationId: conversationId, ownerUserId: ownerUserId
            )) ?? []
            var built: [(id: String, text: String)] = []
            built.reserveCapacity(messages.count)
            // Newest first, decrypted in slices so the UI stays responsive.
            for (offset, message) in messages.reversed().enumerated() {
                if Task.isCancelled { return }
                if message.contentType == .text,
                   let payload = self.messagingService.textContent(for: message),
                   payload.gif == nil {
                    built.append((message.id, Self.fold(payload.text)))
                }
                if offset % 200 == 199 { await Task.yield() }
            }
            self.index = built
            self.isIndexing = false
            self.scheduleSearch(immediately: true)
        }
    }

    func stop() {
        indexTask?.cancel()
        searchTask?.cancel()
        index = []
        matches = []
        currentIndex = 0
        query = ""
        isIndexing = false
    }

    /// ↑ — an older match.
    func older() {
        guard !matches.isEmpty else { return }
        currentIndex = min(currentIndex + 1, matches.count - 1)
    }

    /// ↓ — a newer match.
    func newer() {
        guard !matches.isEmpty else { return }
        currentIndex = max(currentIndex - 1, 0)
    }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let term = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard term.count >= Self.minimumQueryLength else {
            matches = []
            currentIndex = 0
            return
        }
        guard !isIndexing else { return }
        searchTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard let self, !Task.isCancelled else { return }
            var found: [String] = []
            for entry in self.index where entry.text.contains(term) {
                found.append(entry.id)
                if found.count == Self.maxMatches { break }
            }
            self.matches = found
            self.currentIndex = 0
        }
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

// MARK: - Highlighting

private struct ChatSearchTermKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Set by the chat while search is open; bubbles highlight it.
    var chatSearchTerm: String? {
        get { self[ChatSearchTermKey.self] }
        set { self[ChatSearchTermKey.self] = newValue }
    }
}

enum SearchHighlight {
    /// Every occurrence on a yellow background with black text — readable on
    /// any bubble colour.
    static func attributed(_ text: String, term: String?) -> AttributedString {
        var result = AttributedString(text)
        guard let term, !term.isEmpty else { return result }
        var searchRange = text.startIndex..<text.endIndex
        var hits = 0
        while hits < 50, let found = text.range(
            of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: searchRange
        ) {
            if let lower = AttributedString.Index(found.lowerBound, within: result),
               let upper = AttributedString.Index(found.upperBound, within: result) {
                result[lower..<upper].backgroundColor = .yellow
                result[lower..<upper].foregroundColor = .black
            }
            hits += 1
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return result
    }
}
