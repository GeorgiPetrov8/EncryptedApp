import Foundation

/// #3 / #9: signals relayed over the WebSocket and never stored (server
/// `src/ephemeral.js`). The server only forwards them between mutual contacts
/// and never from someone who hid their online status.
enum EphemeralFrame: Equatable {
    case typing(from: String, isTyping: Bool)
    /// `level == nil`: the contact stopped sharing (or went offline).
    case battery(from: String, level: Int?, charging: Bool, at: Date)

    /// Parses a frame received on the socket; nil for anything else.
    static func parse(_ data: Data) -> EphemeralFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let from = object["from"] as? String, !from.isEmpty, from.count <= 64
        else { return nil }
        switch type {
        case "typing":
            guard let state = object["state"] as? String else { return nil }
            return .typing(from: from, isTyping: state == "start")
        case "battery":
            let level = (object["level"] as? Int).flatMap { (0...100).contains($0) ? $0 : nil }
            let at = (object["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            return .battery(from: from, level: level, charging: object["charging"] as? Bool ?? false, at: min(at, Date()))
        default:
            return nil
        }
    }
}

/// What the app sends. Encoded as small JSON frames.
enum EphemeralOutgoing {
    case typing(to: String, isTyping: Bool)
    case battery(level: Int?, charging: Bool)

    var json: Data {
        let object: [String: Any]
        switch self {
        case .typing(let to, let isTyping):
            object = ["type": "typing", "to": to, "state": isTyping ? "start" : "stop"]
        case .battery(let level, let charging):
            object = ["type": "battery", "level": level.map { $0 as Any } ?? NSNull(), "charging": charging]
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
