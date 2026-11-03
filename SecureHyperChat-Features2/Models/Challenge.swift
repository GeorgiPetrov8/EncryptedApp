import Foundation
import GRDB

/// #20: a challenge card sent in a chat.
///
/// The card itself rides inside the encrypted text message
/// (`TextPayload.challenge`), like GIFs and locations. Its status changes travel
/// as a small control message (`.challengeUpdate`). The server only needs
/// 'challengeUpdate' added to its allow-list.
struct ChallengeCard: Codable, Equatable, Hashable {
    /// Catalog id ("fun.07") or "custom".
    let id: String
    let category: ChallengeCategory
    let title: String
    let detail: String?

    static let fallbackText = "🎲 Challenge"
    static let maxTitleLength = 120
    static let maxDetailLength = 400

    func validated() -> ChallengeCard? {
        guard let title = SafeText.line(title, maxLength: Self.maxTitleLength) else { return nil }
        let cleanId = id.count <= 40 ? id : "custom"
        let cleanDetail = detail.flatMap { value -> String? in
            // Detail may have line breaks; strip only control/bidi characters.
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(8)
                .compactMap { SafeText.line(String($0), maxLength: Self.maxDetailLength) }
            let joined = lines.joined(separator: "\n")
            return joined.isEmpty ? nil : String(joined.prefix(Self.maxDetailLength))
        }
        return ChallengeCard(id: cleanId, category: category, title: title, detail: cleanDetail)
    }
}

enum ChallengeCategory: String, Codable, CaseIterable, Identifiable {
    case fun, romantic, cozy, adventure, spicy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fun: return "Fun"
        case .romantic: return "Romantic"
        case .cozy: return "Cozy"
        case .adventure: return "Adventure"
        case .spicy: return "Spicy"
        }
    }

    var emoji: String {
        switch self {
        case .fun: return "🎉"
        case .romantic: return "💞"
        case .cozy: return "☕️"
        case .adventure: return "🧭"
        case .spicy: return "🌶️"
        }
    }
}

/// Order matters: a status can only move forward.
///   sent → accepted | declined
///   accepted → completed | declined
enum ChallengeStatus: String, Codable {
    case sent, accepted, declined, completed

    func canMove(to next: ChallengeStatus) -> Bool {
        switch (self, next) {
        case (.sent, .accepted), (.sent, .declined),
             (.accepted, .completed), (.accepted, .declined):
            return true
        default:
            return false
        }
    }

    var label: String {
        switch self {
        case .sent: return "Waiting"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .completed: return "Done! 🎉"
        }
    }
}

/// Wire payload for `.challengeUpdate`.
struct ChallengeUpdatePayload: Codable, Equatable {
    let messageId: String
    let status: ChallengeStatus
    let at: Date
}

/// Per-account status of a received or sent challenge (table `challenge_states`).
struct ChallengeState: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "challenge_states"

    var ownerUserId: String
    var conversationId: String
    var messageId: String
    var status: ChallengeStatus
    var updatedAt: Date
}

/// The bundled list of challenge ideas (`challenges.json`).
struct ChallengeCatalog: Decodable {
    struct Item: Decodable, Hashable {
        let id: String
        let category: ChallengeCategory
        let title: String
        let detail: String?

        var card: ChallengeCard { ChallengeCard(id: id, category: category, title: title, detail: detail) }
    }

    let version: Int
    let items: [Item]

    static let bundled: ChallengeCatalog = {
        guard let url = Bundle.main.url(forResource: "challenges", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ChallengeCatalog.self, from: data)
        else { return ChallengeCatalog(version: 0, items: []) }
        return catalog
    }()

    func items(in category: ChallengeCategory) -> [Item] {
        items.filter { $0.category == category }
    }
}
