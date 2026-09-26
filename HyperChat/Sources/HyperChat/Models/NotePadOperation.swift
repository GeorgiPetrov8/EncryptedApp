import Foundation

/// The plaintext payload carried inside a `.notePad` envelope, after Double
/// Ratchet decryption — the encrypted equivalent of a text message's body,
/// except it's merged into a shared checklist instead of rendered as a chat
/// bubble.
///
/// Always the *full current state* of one item, not an incremental delta
/// (no separate "rename" vs. "toggle" vs. "delete" op types). That's a
/// deliberate simplicity trade-off: encoding the whole item keeps the merge
/// rule in `NotePadRepository` a single, uniform comparison
/// (`updatedAt`/`updatedBy`) instead of needing per-field conflict
/// resolution across a partial update from one device landing on top of a
/// different partial update from another. The payload is a few dozen bytes
/// either way, so there's no real cost to sending the whole thing.
///
/// FIX: this uses a plain `JSONEncoder`/`JSONDecoder` (default
/// `.deferredToDate` — seconds-since-1970), not `HyperChatJSON` from the
/// networking layer. `HyperChatJSON`'s custom ISO-8601-with-milliseconds
/// strategy exists solely to match what the Node server emits in HTTP
/// response bodies; this struct never crosses the wire as JSON that a
/// server parses; it's encrypted app-internal payload, encoded by this
/// app and decoded by this same app on the other end. Reaching for the
/// HTTP-specific coder here would be solving a problem that doesn't exist
/// at this layer while adding a dependency this type doesn't need.
struct NotePadOperation: Codable, Equatable {
    let itemId: String
    let text: String
    let isDone: Bool
    let isDeleted: Bool
    let updatedAt: Date
    let updatedBy: String
}
