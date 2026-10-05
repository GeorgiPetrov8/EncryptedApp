import Foundation
import UniformTypeIdentifiers

/// Decides what may be attached to a message, by inspecting **content**, not
/// filenames.
///
/// Blocking `.exe` by extension is not a control — renaming `payload.exe` to
/// `invoice.pdf` defeats it. So the check looks at the bytes, and it's an
/// allow-list: anything not positively recognised as a document, image,
/// audio or video is refused.
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
        /// The bytes don't match the extension — what a disguised file looks like.
        case mismatchedExtension(declared: String, actual: String)

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
            }
        }
    }

    /// FIX (review #7): 25 MB, matching the server's `MAX_MEDIA_BYTES`. The
    /// comment used to say 100 MB while the value was 25 MB.
    static let maxBytes = 25 * 1024 * 1024

    /// Executable signatures — for a precise error message. The security
    /// boundary is the allow-list below, not this list.
    private static let executableSignatures: [(name: String, bytes: [UInt8])] = [
        ("Windows program", [0x4D, 0x5A]),                       // MZ — PE/COFF
        ("Linux program",   [0x7F, 0x45, 0x4C, 0x46]),           // ELF
        ("Mac program",     [0xCE, 0xFA, 0xED, 0xFE]),           // Mach-O 32 LE
        ("Mac program",     [0xCF, 0xFA, 0xED, 0xFE]),           // Mach-O 64 LE
        ("Mac program",     [0xFE, 0xED, 0xFA, 0xCE]),           // Mach-O 32 BE
        ("Mac program",     [0xFE, 0xED, 0xFA, 0xCF]),           // Mach-O 64 BE
        ("executable",      [0xCA, 0xFE, 0xBA, 0xBE]),           // fat binary / Java class
        ("script",          [0x23, 0x21]),                       // #!
    ]

    /// OLE compound file: legacy .doc/.xls/.ppt AND .msi installers. Telling
    /// them apart needs a full OLE parser, so the whole container is refused
    /// with a message that says what to do instead.
    private static let oleSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    private static let allowed: [(bytes: [UInt8], category: Category, type: UTType, ext: String)] = [
        ([0x25, 0x50, 0x44, 0x46], .document, .pdf, "pdf"),                       // %PDF
        ([0x7B, 0x5C, 0x72, 0x74, 0x66], .document, .rtf, "rtf"),                 // {\rtf
        ([0xFF, 0xD8, 0xFF], .image, .jpeg, "jpg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image, .png, "png"),
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], .image, .gif, "gif"),
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], .image, .gif, "gif"),
        ([0x49, 0x44, 0x33], .audio, .mp3, "mp3"),                                // ID3
        ([0x4F, 0x67, 0x67, 0x53], .audio, .audio, "ogg"),
        ([0x66, 0x4C, 0x61, 0x43], .audio, .audio, "flac"),
    ]

    /// Plain-text extensions accepted when the content is genuinely text.
    private static let textExtensions: [String: UTType] = [
        "txt": .plainText,
        "csv": .commaSeparatedText,
        "md": .plainText,
    ]

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

        // MPEG-4 family: signature at offset 4.
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

        // Plain text: only under a text extension, and only if it really is
        // text (valid UTF-8, no NUL bytes). Scripts are excluded by the
        // extension requirement — a .bat/.ps1/.sh never matches.
        if let declared, let type = textExtensions[declared], isPlainText(data) {
            return .success(Accepted(category: .document, utType: type, displayExtension: declared))
        }

        return .failure(.unrecognisedFormat)
    }

    /// Reports a mismatch between the extension and the detected type.
    private static func checked(_ accepted: Accepted, declared: String?) -> Result<Accepted, Rejection> {
        guard let declared, !declared.isEmpty,
              declared != accepted.displayExtension,
              !equivalentExtensions(declared, accepted.displayExtension)
        else { return .success(accepted) }
        return .failure(.mismatchedExtension(declared: declared, actual: accepted.displayExtension))
    }

    /// Separates Word / Excel / PowerPoint from Java archives — all are ZIPs.
    ///
    /// FIX (review #5), and more than the review found. The review blamed the
    /// docx/xlsx/pptx entry in `equivalentExtensions`, but ZIPs never reached
    /// that function — this routine returned before any mismatch check, and
    /// took the type straight from the filename. So a .pptx renamed .xlsx was
    /// accepted as .xlsx, and a document renamed to anything (even ".exe") was
    /// labelled with that name. It now detects the actual type from the
    /// required part of each format and compares it with the name.
    ///
    /// Also scans the end of the file, not just the start: the ZIP central
    /// directory (which lists every entry) is at the end. Checked on real ZIP
    /// files: a .pptx whose first entry is a 200 KB thumbnail used to be
    /// rejected, and a .jar whose manifest sat after 200 KB used to slip past
    /// the jar check. Both are now handled.
    private static func inspectZipContainer(data: Data, declared: String?) -> Result<Accepted, Rejection> {
        let window = 64 * 1024
        var scanned = Data(data.prefix(window))
        if data.count > window { scanned.append(data.suffix(window)) }

        if contains(scanned, ascii: "META-INF/MANIFEST.MF") || contains(scanned, ascii: ".class") {
            return .failure(.executableContent("Java archive"))
        }
        guard contains(scanned, ascii: "[Content_Types].xml") else {
            // A plain ZIP: contents unknown, may hide executables.
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

        let accepted = Accepted(
            category: .document,
            utType: UTType(kind.type) ?? .data,
            displayExtension: kind.ext
        )
        return checked(accepted, declared: declared)
    }

    private static func isPlainText(_ data: Data) -> Bool {
        let sample = data.prefix(64 * 1024)
        guard !sample.contains(0) else { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    private static func matches(_ header: [UInt8], _ signature: [UInt8]) -> Bool {
        guard header.count >= signature.count else { return false }
        return zip(header, signature).allSatisfy { $0 == $1 }
    }

    private static func contains(_ data: Data, ascii: String) -> Bool {
        data.range(of: Data(ascii.utf8)) != nil
    }

    /// Extensions that describe the same bytes.
    ///
    /// FIX (review #5): docx/xlsx/pptx removed — they are different formats.
    private static func equivalentExtensions(_ a: String, _ b: String) -> Bool {
        let groups: [Set<String>] = [
            ["jpg", "jpeg"],
            ["m4a", "mp4", "m4v", "mov"],
        ]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }
}
