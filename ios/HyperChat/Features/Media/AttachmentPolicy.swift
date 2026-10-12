import Foundation
import UniformTypeIdentifiers

/// Decides what may be attached to a message, by inspecting **content**, not
/// filenames. An allow-list: anything not positively recognised as a
/// document, image, audio or video is refused.
enum AttachmentPolicy {

    enum Category: String, Codable, Equatable {
        case image
        case video
        case audio
        case document
    }

    struct Accepted: Equatable {
        let category: Category
        let utType: UTType
        let displayExtension: String
    }

    enum Rejection: LocalizedError, Equatable {
        case executableContent(String)
        case unrecognisedFormat
        case legacyOfficeFormat
        case tooLarge(limitBytes: Int)
        case empty
        case mismatchedExtension(declared: String, actual: String)
        case unexpectedType(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .executableContent(let kind):
                return "That file is a program (\(kind)) and can't be sent."
            case .unrecognisedFormat:
                return "That file type isn't supported. You can send PDF, Word, Excel, PowerPoint, text, images, audio and video."
            case .legacyOfficeFormat:
                return "Old Office files (.doc, .xls, .ppt) can't be sent, because they use the same container as Windows installers. Save it as .docx, .xlsx or .pptx and try again."
            case .tooLarge(let limit):
                return "That file is too large. The limit is \(limit / (1024 * 1024)) MB."
            case .empty:
                return "That file is empty."
            case .mismatchedExtension(let declared, let actual):
                return "This file is named “.\(declared)” but is actually a .\(actual) file, so it can't be sent."
            case .unexpectedType(let expected, let actual):
                return "This attachment was sent as \(expected) but is actually \(actual), so it was blocked."
            }
        }
    }

    /// 25 MB, matching the server's `MAX_MEDIA_BYTES`.
    static let maxBytes = 25 * 1024 * 1024

    private static let executableSignatures: [(name: String, bytes: [UInt8])] = [
        ("Windows program", [0x4D, 0x5A]),
        ("Linux program",   [0x7F, 0x45, 0x4C, 0x46]),
        ("Mac program",     [0xCE, 0xFA, 0xED, 0xFE]),
        ("Mac program",     [0xCF, 0xFA, 0xED, 0xFE]),
        ("Mac program",     [0xFE, 0xED, 0xFA, 0xCE]),
        ("Mac program",     [0xFE, 0xED, 0xFA, 0xCF]),
        ("executable",      [0xCA, 0xFE, 0xBA, 0xBE]),
        ("script",          [0x23, 0x21]),
    ]

    /// OLE compound file: legacy .doc/.xls/.ppt AND .msi installers.
    private static let oleSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    private static let allowed: [(bytes: [UInt8], category: Category, type: UTType, ext: String)] = [
        ([0x25, 0x50, 0x44, 0x46], .document, .pdf, "pdf"),
        ([0x7B, 0x5C, 0x72, 0x74, 0x66], .document, .rtf, "rtf"),
        ([0xFF, 0xD8, 0xFF], .image, .jpeg, "jpg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image, .png, "png"),
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], .image, .gif, "gif"),
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], .image, .gif, "gif"),
        ([0x49, 0x44, 0x33], .audio, .mp3, "mp3"),
        ([0x4F, 0x67, 0x67, 0x53], .audio, .audio, "ogg"),
        ([0x66, 0x4C, 0x61, 0x43], .audio, .audio, "flac"),
    ]

    private static let textExtensions: [String: UTType] = [
        "txt": .plainText,
        "csv": .commaSeparatedText,
        "md": .plainText,
    ]

    // MARK: Sending

    static func inspect(data: Data, declaredExtension: String?) -> Result<Accepted, Rejection> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard data.count <= maxBytes else { return .failure(.tooLarge(limitBytes: maxBytes)) }

        let declared = declaredExtension?.lowercased().trimmingCharacters(in: .whitespaces)
        let header = [UInt8](data.prefix(64))

        if let exe = executableSignatures.first(where: { matches(header, $0.bytes) }) {
            return .failure(.executableContent(exe.name))
        }
        if matches(header, oleSignature) {
            return .failure(.legacyOfficeFormat)
        }

        if matches(header, [0x50, 0x4B, 0x03, 0x04]) || matches(header, [0x50, 0x4B, 0x05, 0x06]) {
            return inspectZipContainer(data: data, declared: declared)
        }

        if data.count > 12, [UInt8](data[data.startIndex + 4 ..< data.startIndex + 8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: data[data.startIndex + 8 ..< data.startIndex + 12], as: UTF8.self)
            if brand.hasPrefix("M4A") {
                return checked(Accepted(category: .audio, utType: .mpeg4Audio, displayExtension: "m4a"), declared: declared)
            }
            return checked(Accepted(category: .video, utType: .mpeg4Movie, displayExtension: "mp4"), declared: declared)
        }

        if let hit = allowed.sorted(by: { $0.bytes.count > $1.bytes.count })
            .first(where: { matches(header, $0.bytes) }) {
            return checked(Accepted(category: hit.category, utType: hit.type, displayExtension: hit.ext), declared: declared)
        }

        if let declared, let type = textExtensions[declared], isPlainText(data) {
            return .success(Accepted(category: .document, utType: type, displayExtension: declared))
        }

        return .failure(.unrecognisedFormat)
    }

    // MARK: Receiving

    /// NEW: the check on the **recipient's** device, after decryption.
    ///
    /// The sender-side check runs on the sender's phone, so a modified app
    /// can skip it. The recipient's phone isn't under the sender's control,
    /// so this is the check that actually protects people. It also refuses
    /// an attachment whose bytes don't match what it was sent as — e.g. a
    /// "photo" that is really a document.
    ///
    /// - Parameter expected: the media type the message claims. `nil` (old
    ///   messages without metadata) only applies the executable checks.
    static func checkReceived(_ data: Data, expected: MediaType?) -> Result<Accepted, Rejection> {
        let result = inspect(data: data, declaredExtension: nil)

        switch result {
        case .failure(.unrecognisedFormat) where expected == .document || expected == nil:
            // Plain text has no signature; accept it only if it really is text.
            if isPlainText(data) {
                return .success(Accepted(category: .document, utType: .plainText, displayExtension: "txt"))
            }
            return result
        case .failure:
            return result
        case .success(let accepted):
            guard let expected else { return result }
            let required: Category? = {
                switch expected {
                case .image: return .image
                case .video: return .video
                case .audio: return .audio
                case .document: return nil   // any allowed, non-executable type
                }
            }()
            if let required, required != accepted.category {
                return .failure(.unexpectedType(expected: required.rawValue, actual: accepted.displayExtension))
            }
            return result
        }
    }

    static func acceptsReceived(_ data: Data, expected: MediaType?) -> Bool {
        if case .success = checkReceived(data, expected: expected) { return true }
        return false
    }

    // MARK: Helpers

    private static func checked(_ accepted: Accepted, declared: String?) -> Result<Accepted, Rejection> {
        guard let declared, !declared.isEmpty,
              declared != accepted.displayExtension,
              !equivalentExtensions(declared, accepted.displayExtension)
        else { return .success(accepted) }
        return .failure(.mismatchedExtension(declared: declared, actual: accepted.displayExtension))
    }

    /// Word / Excel / PowerPoint vs Java archives — all ZIPs. Detects the
    /// real type from each format's required part, scanning both ends of the
    /// file (the ZIP directory is at the end).
    private static func inspectZipContainer(data: Data, declared: String?) -> Result<Accepted, Rejection> {
        let window = 64 * 1024
        var scanned = Data(data.prefix(window))
        if data.count > window { scanned.append(data.suffix(window)) }

        if contains(scanned, ascii: "META-INF/MANIFEST.MF") || contains(scanned, ascii: ".class") {
            return .failure(.executableContent("Java archive"))
        }
        guard contains(scanned, ascii: "[Content_Types].xml") else {
            return .failure(.unrecognisedFormat)
        }

        let markers: [(part: String, ext: String, type: String)] = [
            ("word/document.xml", "docx", "org.openxmlformats.wordprocessingml.document"),
            ("xl/workbook.xml", "xlsx", "org.openxmlformats.spreadsheetml.sheet"),
            ("ppt/presentation.xml", "pptx", "org.openxmlformats.presentationml.presentation"),
        ]
        let found = markers.filter { contains(scanned, ascii: $0.part) }
        guard found.count == 1, let kind = found.first else {
            return .failure(.unrecognisedFormat)
        }
        return checked(
            Accepted(category: .document, utType: UTType(kind.type) ?? .data, displayExtension: kind.ext),
            declared: declared
        )
    }

    private static func isPlainText(_ data: Data) -> Bool {
        let sample = data.prefix(64 * 1024)
        guard !sample.contains(0) else { return false }
        if String(data: sample, encoding: .utf8) != nil { return true }
        // The 64 KB cut can split a multi-byte character (e.g. Cyrillic is 2
        // bytes); retry without the last 1–3 bytes before calling it binary.
        guard sample.count < data.count else { return false }
        return (1...3).contains { String(data: sample.dropLast($0), encoding: .utf8) != nil }
    }

    private static func matches(_ header: [UInt8], _ signature: [UInt8]) -> Bool {
        guard header.count >= signature.count else { return false }
        return zip(header, signature).allSatisfy { $0 == $1 }
    }

    private static func contains(_ data: Data, ascii: String) -> Bool {
        data.range(of: Data(ascii.utf8)) != nil
    }

    private static func equivalentExtensions(_ a: String, _ b: String) -> Bool {
        let groups: [Set<String>] = [
            ["jpg", "jpeg"],
            ["m4a", "mp4", "m4v", "mov"],
        ]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }
}
