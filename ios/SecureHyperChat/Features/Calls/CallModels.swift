import Foundation

/// Signalling payloads for calls (feature: audio/video calls + screen share).
///
/// ## How this fits the existing crypto
///
/// WebRTC has its own media encryption (DTLS-SRTP), but DTLS-SRTP alone
/// authenticates the *connection*, not the person — it's vulnerable to a
/// signalling server that swaps the fingerprints, which is precisely the
/// attacker this app already defends against with identity pinning.
///
/// So the SDP offer/answer and ICE candidates travel as ordinary `.call`
/// envelopes through the Double Ratchet, exactly like a text message. Two
/// consequences, both intended:
///
///   - the server relays opaque ciphertext and cannot read or alter the
///     session description, so it can't perform a fingerprint swap;
///   - the DTLS fingerprint inside the SDP is therefore authenticated by the
///     same pinned identity key the chat uses, which is what actually binds
///     the media stream to the person rather than to the connection.
enum CallSignal: Codable, Equatable {
    /// Invitation to start a call. Contains the SDP offer.
    case offer(CallOffer)
    /// Acceptance, with the SDP answer.
    case answer(CallAnswer)
    /// An ICE candidate, exchanged continuously while connecting.
    case candidate(IceCandidate)
    /// Declined, hung up, or failed. `reason` distinguishes them so the UI can
    /// say "declined" rather than a generic "call ended".
    case end(CallEnd)
    /// Mid-call state change: muted, camera off, screen share started.
    case update(CallStateUpdate)

    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum Kind: String, Codable { case offer, answer, candidate, end, update }

    // Hand-written rather than synthesised so the wire format is an explicit
    // `{kind, payload}` envelope. Swift's default enum encoding produces a
    // single-key object whose key *is* the case name, which is fine until a
    // case is renamed and old clients silently fail to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .offer:     self = .offer(try container.decode(CallOffer.self, forKey: .payload))
        case .answer:    self = .answer(try container.decode(CallAnswer.self, forKey: .payload))
        case .candidate: self = .candidate(try container.decode(IceCandidate.self, forKey: .payload))
        case .end:       self = .end(try container.decode(CallEnd.self, forKey: .payload))
        case .update:    self = .update(try container.decode(CallStateUpdate.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offer(let p):     try container.encode(Kind.offer, forKey: .kind);     try container.encode(p, forKey: .payload)
        case .answer(let p):    try container.encode(Kind.answer, forKey: .kind);    try container.encode(p, forKey: .payload)
        case .candidate(let p): try container.encode(Kind.candidate, forKey: .kind); try container.encode(p, forKey: .payload)
        case .end(let p):       try container.encode(Kind.end, forKey: .kind);       try container.encode(p, forKey: .payload)
        case .update(let p):    try container.encode(Kind.update, forKey: .kind);    try container.encode(p, forKey: .payload)
        }
    }

    /// Every signal carries the call id so a late-arriving message from a
    /// previous call can be discarded rather than disrupting the current one.
    var callId: String {
        switch self {
        case .offer(let p): return p.callId
        case .answer(let p): return p.callId
        case .candidate(let p): return p.callId
        case .end(let p): return p.callId
        case .update(let p): return p.callId
        }
    }
}

struct CallOffer: Codable, Equatable {
    let callId: String
    let sdp: String
    /// Whether the caller is sending video. The callee needs this before
    /// answering, to show "video call" and to decide whether to enable its own
    /// camera — asking for camera permission on an audio call would be wrong.
    let isVideo: Bool
    let startedAt: Date
}

struct CallAnswer: Codable, Equatable {
    let callId: String
    let sdp: String
    let isVideo: Bool
}

struct IceCandidate: Codable, Equatable {
    let callId: String
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String?
}

struct CallEnd: Codable, Equatable {
    enum Reason: String, Codable {
        case hangUp
        case declined
        case busy
        case failed
        case unanswered
    }
    let callId: String
    let reason: Reason
}

/// Mid-call changes. Sent over the signalling channel rather than inferred
/// from the media stream, because "the track stopped" and "they muted" look
/// identical at the RTP layer — and showing "muted" when someone's connection
/// actually dropped is the wrong information at the wrong moment.
struct CallStateUpdate: Codable, Equatable {
    let callId: String
    let isAudioMuted: Bool
    let isVideoEnabled: Bool
    let isScreenSharing: Bool
}

/// What the UI is currently showing.
enum CallPhase: Equatable {
    case idle
    /// We called them; waiting for an answer.
    case outgoing(callId: String, isVideo: Bool)
    /// They called us; not yet answered.
    case incoming(callId: String, isVideo: Bool, peerId: String)
    /// Media negotiating.
    case connecting(callId: String)
    case active(callId: String)
    case ended(reason: CallEnd.Reason)

    var isBusy: Bool {
        switch self {
        case .idle, .ended: return false
        case .outgoing, .incoming, .connecting, .active: return true
        }
    }
}

enum CallLimits {
    /// An unanswered call gives up rather than ringing indefinitely.
    static let ringTimeout: TimeInterval = 45
    /// ICE gathering that hasn't produced a connection by now isn't going to.
    static let connectTimeout: TimeInterval = 30
}
