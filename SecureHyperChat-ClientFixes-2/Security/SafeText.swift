import Foundation

/// Cleans text that comes from another person before it is shown.
///
/// FIX (S1, S32, S43): names and quotes supplied by a peer could contain new
/// lines, bidi overrides (U+202E "right-to-left override" makes "gpj.exe" look
/// like "exe.jpg") and thousands of characters. None of that is ever needed in a
/// name or a one-line preview.
enum SafeText {
    /// Format and bidi control characters plus line/paragraph separators.
    private static let forbidden: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.formUnion(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{2028}\u{2029}\u{FEFF}"))
        return set
    }()

    /// A single line, no control characters, at most `maxLength` characters.
    static func line(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }

    /// A name chosen by the other person. Never used instead of the username.
    static func displayName(_ value: String?) -> String? { line(value, maxLength: 40) }

    /// The quoted text of a reply.
    static func preview(_ value: String?) -> String? { line(value, maxLength: ReplyReference.maxPreviewLength) }
}

/// Validates identifiers that end up in file paths or URL paths.
///
/// FIX (S31): `mediaId` comes from inside a message the *sender* wrote. It was
/// appended to a directory and to an API path unchecked, so `../HyperChat.sqlite`
/// pointed at the database (deleted on logout / message deletion) and
/// `../bundles/...` sent an authenticated request to another endpoint.
enum SafeIdentifier {
    static func isMediaId(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && value.count == 36
    }
}
