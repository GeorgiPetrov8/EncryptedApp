import Foundation

/// The tiny protocol between the screen-share extension and the app.
///
/// **Add this file to BOTH targets** (HyperChat and HyperChatScreenShare).
///
/// The extension runs in its own process, so it needs a way to hand frames to
/// the app. Apple's usual answer is an App Group, but App Groups don't work
/// reliably for sideloaded apps on a free account (SideStore), so this uses a
/// TCP connection on 127.0.0.1 instead — it never leaves the phone.
///
/// Wire format:
///   handshake: UInt32 BE `magic`
///   each frame: UInt32 BE length N | UInt8 orientation | (N-1) bytes of JPEG
enum ScreenShareWire {
    static let port: UInt16 = 47318
    static let magic: UInt32 = 0x4843_5353 // "HCSS"
    static let maxFrameBytes = 4 * 1024 * 1024

    static func encode(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func decodeUInt32(_ data: Data) -> UInt32 {
        data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
