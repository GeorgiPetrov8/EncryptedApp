import Foundation
import Combine
import GRDB
import os

/// #15: stores and syncs a chat's shared date and decides when to celebrate.
@MainActor
final class OccasionService: ObservableObject {
    let updates = PassthroughSubject<String, Never>()

    private let dbQueue: DatabaseQueue
    private let authService: AuthService
    private var sendHandler: ((Occasion, Conversation) async throws -> Void)?
    private let logger = Logger(subsystem: "com.georgipetrov.securehyperchat", category: "occasion")

    init(dbQueue: DatabaseQueue, authService: AuthService) {
        self.dbQueue = dbQueue
        self.authService = authService
    }

    func setSendHandler(_ handler: @escaping (Occasion, Conversation) async throws -> Void) {
        sendHandler = handler
    }

    func occasion(for conversationId: String) -> Occasion? {
        guard let me = authService.currentUserId else { return nil }
        let record = try? dbQueue.read { db in
            try OccasionRecord.fetchOne(db, key: ["ownerUserId": me, "conversationId": conversationId])
        }
        guard let occasion = record?.occasion, !occasion.removed else { return nil }
        return occasion
    }

    // MARK: Changing (either person)

    func set(kind: Occasion.Kind, label: String?, month: Int, day: Int, year: Int?, in conversation: Conversation) async throws {
        guard let me = authService.currentUserId else { throw APIError.notAuthenticated }
        let occasion = Occasion(kind: kind, label: label, month: month, day: day, year: year,
                                setAt: Date(), setBy: me, removed: false)
        guard let valid = occasion.validated() else { return }
        try store(valid, owner: me, conversationId: conversation.id, force: true)
        try await sendHandler?(valid, conversation)
    }

    func remove(in conversation: Conversation) async throws {
        guard let me = authService.currentUserId, let current = occasion(for: conversation.id) else { return }
        var removed = current
        removed.removed = true
        removed.setAt = Date()
        removed.setBy = me
        try store(removed, owner: me, conversationId: conversation.id, force: true)
        try await sendHandler?(removed, conversation)
    }

    // MARK: Receiving

    func applyRemote(_ incoming: Occasion, from senderId: String, conversation: Conversation, ownerUserId: String) {
        // The setter is whoever sent it — never trust a different name inside.
        var occasion = incoming
        occasion.setBy = senderId
        guard conversation.relationshipState == .accepted, let valid = occasion.validated() else { return }
        if (try? store(valid, owner: ownerUserId, conversationId: conversation.id, force: false)) == true {
            updates.send(conversation.id)
        }
    }

    @discardableResult
    private func store(_ occasion: Occasion, owner: String, conversationId: String, force: Bool) throws -> Bool {
        try dbQueue.write { db in
            if !force, let existing = try OccasionRecord.fetchOne(db, key: ["ownerUserId": owner, "conversationId": conversationId]),
               !occasion.isNewer(than: existing.occasion) {
                return false
            }
            try OccasionRecord(ownerUserId: owner, conversationId: conversationId, occasion: occasion).save(db)
            return true
        }
    }

    // MARK: Celebrating

    /// The occasion to celebrate now, at most once per chat per day.
    func celebrationIfDue(for conversationId: String, now: Date = Date()) -> Occasion? {
        guard let me = authService.currentUserId,
              let occasion = occasion(for: conversationId),
              occasion.matches(now) else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let key = "occasion.shown.\(me).\(conversationId)"
        let today = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        guard UserDefaults.standard.string(forKey: key) != today else { return nil }
        UserDefaults.standard.set(today, forKey: key)
        return occasion
    }

    /// The banner text for today, if it's the day (shown all day, unlike the confetti).
    func bannerText(for conversationId: String, now: Date = Date()) -> String? {
        guard let occasion = occasion(for: conversationId), occasion.matches(now) else { return nil }
        let name = occasion.label.map { " — \($0)" } ?? ""
        switch occasion.kind {
        case .birthday:
            return "\(occasion.kind.emoji) Happy birthday\(name)!"
        case .anniversary:
            if let years = occasion.years(on: now) {
                return "\(occasion.kind.emoji) Happy anniversary — \(years) year\(years == 1 ? "" : "s")!"
            }
            return "\(occasion.kind.emoji) Happy anniversary\(name)!"
        case .other:
            return "\(occasion.kind.emoji) \(occasion.label ?? "Special day")!"
        }
    }

    func deleteAll(ownerUserId: String) {
        _ = try? dbQueue.write { db in
            try OccasionRecord.filter(Column("ownerUserId") == ownerUserId).deleteAll(db)
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("occasion.shown.\(ownerUserId).") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
