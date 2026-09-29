import Foundation
import UniformTypeIdentifiers

/// Decides what may be attached to a message, by inspecting **content**, not
/// filenames.
///
/// ## Why the filename is irrelevant
///
/// Blocking `.exe` by extension is not a control. Renaming `payload.exe` to
/// `invoice.pdf` defeats it completely, and iOS doesn't execute either one
/// anyway — the risk is the recipient forwarding the file to a Windows machine
/// where it *is* executable. So the check has to look at the bytes.
///
/// Verified against real signatures before this was written: with the file
/// renamed to `invoice.pdf`, an extension check passes every time, while a
/// magic-byte check catches PE, ELF, all four Mach-O variants, fat binaries,
/// Java class files and shebang scripts.
///
/// ## Why this is an allow-list, not a deny-list
///
/// A deny-list of "known executable formats" was measured and it leaks:
/// `.com` (DOS, no fixed magic), `.jar` (a ZIP, structurally identical to a
/// `.docx`), and `.msi` (OLE compound, same container as legacy `.doc`) all
/// pass a signature deny-list. An allow-list inverts the default: anything not
/// positively recognised as a document, image, audio or video is refused.
enum AttachmentPolicy {

    /// Categories a chat attachment may belong to.
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
        case tooLarge(limitBytes: Int)
        case empty
        /// The bytes don't match the extension. Not automatically malicious —
        /// but a mismatch is exactly what a disguised binary looks like, and
        /// honouring the *content* rather than the name is the safe default.
        case mismatchedExtension(declared: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .executableContent(let kind):
                return "That file is a program (\(kind)) and can't be sent."
            case .unrecognisedFormat:
                return "That file type isn't supported. You can send documents, images, audio and video."
            case .tooLarge(let limit):
                let mb = limit / (1024 * 1024)
                return "That file is too large. The limit is \(mb) MB."
            case .empty:
                return "That file is empty."
            case .mismatchedExtension(let declared, let actual):
                return "This file is named “.\(declared)” but is actually a \(actual) file, so it can't be sent."
            }
        }
    }

    /// 100 MB. Generous for documents, deliberately below the point where a
    /// single attachment dominates the recipient's storage or a mobile data
    /// allowance.
    static let maxBytes = 100 * 1024 * 1024

    /// Executable signatures. Used for a *precise error message* — "this is a
    /// program" rather than "unsupported" — not as the security boundary. The
    /// boundary is the allow-list below.
    private static let executableSignatures: [(name: String, bytes: [UInt8])] = [
        ("Windows program", [0x4D, 0x5A]),                       // MZ — PE/COFF
        ("Linux program",   [0x7F, 0x45, 0x4C, 0x46]),           // ELF
        ("Mac program",     [0xCE, 0xFA, 0xED, 0xFE]),           // Mach-O 32 LE
        ("Mac program",     [0xCF, 0xFA, 0xED, 0xFE]),           // Mach-O 64 LE
        ("Mac program",     [0xFE, 0xED, 0xFA, 0xCE]),           // Mach-O 32 BE
        ("Mac program",     [0xFE, 0xED, 0xFA, 0xCF]),           // Mach-O 64 BE
        // CAFEBABE is both a Mach-O universal binary and a Java .class file.
        // Blocking it blocks both, which is correct — .class is executable
        // bytecode and has no place as a chat attachment either.
        ("executable",      [0xCA, 0xFE, 0xBA, 0xBE]),
        ("script",          [0x23, 0x21]),                       // #!
        ("installer",       [0xD0, 0xCF, 0x11, 0xE0]),           // OLE — .msi, legacy .doc
    ]

    /// The allow-list: signature → what it is.
    ///
    /// Order matters where prefixes overlap; longer signatures are checked
    /// first via `sorted(by: count)` in `identify`.
    private static let allowed: [(bytes: [UInt8], category: Category, type: UTType, ext: String)] = [
        // Documents
        ([0x25, 0x50, 0x44, 0x46], .document, .pdf, "pdf"),                       // %PDF
        // Images
        ([0xFF, 0xD8, 0xFF], .image, .jpeg, "jpg"),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .image, .png, "png"),
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], .image, .gif, "gif"),
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], .image, .gif, "gif"),
        // Audio
        ([0x49, 0x44, 0x33], .audio, .mp3, "mp3"),                                // ID3
        ([0x4F, 0x67, 0x67, 0x53], .audio, .audio, "ogg"),                        // OggS
        ([0x66, 0x4C, 0x61, 0x43], .audio, .audio, "flac"),
    ]

    /// Identifies an attachment from its bytes.
    ///
    /// - Parameter declaredExtension: the filename's extension, used only to
    ///   detect a mismatch and to label ambiguous containers — never trusted
    ///   on its own.
    static func inspect(data: Data, declaredExtension: String?) -> Result<Accepted, Rejection> {
        guard !data.isEmpty else { return .failure(.empty) }
        guard data.count <= maxBytes else { return .failure(.tooLarge(limitBytes: maxBytes)) }

        let header = [UInt8](data.prefix(64))

        // Executables are named explicitly so the user gets a useful message.
        if let exe = executableSignatures.first(where: { matches(header, $0.bytes) }) {
            return .failure(.executableContent(exe.name))
        }

        // ZIP-based containers need structural inspection: .docx, .xlsx and
        // .pptx are ZIPs — but so is .jar, which is executable. The extension
        // alone can't separate them, and neither can the magic bytes, so this
        // is handled by its own routine.
        if matches(header, [0x50, 0x4B, 0x03, 0x04]) || matches(header, [0x50, 0x4B, 0x05, 0x06]) {
            return inspectZipContainer(data: data, declaredExtension: declaredExtension)
        }

        // MPEG-4 family: the signature sits at offset 4, not 0.
        if data.count > 12, [UInt8](data[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: data[8..<12], as: UTF8.self)
            // M4A is audio in an MP4 container; everything else in the family
            // is treated as video.
            if brand.hasPrefix("M4A") {
                return .success(Accepted(category: .audio, utType: .mpeg4Audio, displayExtension: "m4a"))
            }
            return .success(Accepted(category: .video, utType: .mpeg4Movie, displayExtension: "mp4"))
        }

        if let hit = allowed.sorted(by: { $0.bytes.count > $1.bytes.count })
            .first(where: { matches(header, $0.bytes) }) {

            if let declared = declaredExtension?.lowercased(),
               !declared.isEmpty,
               declared != hit.ext,
               !equivalentExtensions(declared, hit.ext) {
                return .failure(.mismatchedExtension(declared: declared, actual: hit.ext))
            }
            return .success(Accepted(category: hit.category, utType: hit.type, displayExtension: hit.ext))
        }

        // Nothing recognised: refuse. This is the allow-list doing its job —
        // `.com` files, raw shell scripts without a shebang, and every future
        // format nobody has thought about all land here.
        return .failure(.unrecognisedFormat)
    }

    /// Separates Office documents from Java archives, both of which are ZIPs.
    ///
    /// Rather than parsing the whole central directory, this scans for the
    /// marker entries each format must contain. A `.jar` is defined by
    /// `META-INF/MANIFEST.MF`; OOXML files are defined by `[Content_Types].xml`.
    private static func inspectZipContainer(data: Data, declaredExtension: String?) -> Result<Accepted, Rejection> {
        // Scanning a bounded window rather than the whole file: local headers
        // appear early, and an unbounded search over a 100 MB upload would be
        // a denial-of-service against our own main thread.
        let window = data.prefix(64 * 1024)

        if contains(window, ascii: "META-INF/MANIFEST.MF") || contains(window, ascii: ".class") {
            return .failure(.executableContent("Java archive"))
        }

        guard contains(window, ascii: "[Content_Types].xml") || contains(window, ascii: "word/")
                || contains(window, ascii: "xl/") || contains(window, ascii: "ppt/") else {
            // A plain ZIP. Refused because its contents are unknown and could
            // include executables — the allow-list default applies.
            return .failure(.unrecognisedFormat)
        }

        let ext = declaredExtension?.lowercased() ?? "docx"
        let type: UTType
        switch ext {
        case "xlsx": type = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
        case "pptx": type = UTType("org.openxmlformats.presentationml.presentation") ?? .data
        default:     type = UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        }
        return .success(Accepted(category: .document, utType: type, displayExtension: ext))
    }

    private static func matches(_ header: [UInt8], _ signature: [UInt8]) -> Bool {
        guard header.count >= signature.count else { return false }
        return zip(header, signature).allSatisfy { $0 == $1 }
    }

    private static func contains(_ data: Data, ascii: String) -> Bool {
        data.range(of: Data(ascii.utf8)) != nil
    }

    /// Extensions that describe the same bytes, so a mismatch isn't reported
    /// for a legitimate alias.
    private static func equivalentExtensions(_ a: String, _ b: String) -> Bool {
        let groups: [Set<String>] = [
            ["jpg", "jpeg"],
            ["m4a", "mp4", "m4v"],
            ["docx", "xlsx", "pptx"],
        ]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }
}
