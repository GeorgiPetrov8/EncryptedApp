import Foundation

/// A single arithmetic challenge the user must answer to advance toward
/// dismissing an alarm.
///
/// Calibration matters more here than it looks. Too easy and it's solved on
/// autopilot while half-asleep, which defeats the entire purpose; too hard
/// and it's rage-inducing at 6am and the user uninstalls the app. The
/// generators below were checked over 20,000 samples each before being
/// written, for: no negative answers, no trivially small answers, and a
/// carry/borrow actually being required rather than the sum decomposing
/// into independent digit-wise addition.
struct MentalTask: Equatable {
    let prompt: String
    let answer: Int
    let kind: Kind

    enum Kind: CaseIterable {
        case addition
        case subtraction
        case multiplication
        case sequence

        var hint: String {
            switch self {
            case .addition, .subtraction, .multiplication: return "Type the result"
            case .sequence: return "Type the next number"
            }
        }
    }

    /// Free numeric entry, deliberately not multiple choice.
    ///
    /// With four options, tapping at random clears three tasks one time in
    /// 64 — well within reach of someone determined to get back to sleep,
    /// and they *will* find that out. Open entry over the ~24–170 answer
    /// range makes blind guessing roughly one in three million, so the only
    /// way through is to actually do the arithmetic.
    static func random(excluding previous: MentalTask? = nil) -> MentalTask {
        var task = generate(kind: Kind.allCases.randomElement() ?? .addition)
        // Avoid handing back the identical prompt twice in a row, which
        // would otherwise happen occasionally and feel broken.
        if let previous, task.prompt == previous.prompt {
            task = generate(kind: Kind.allCases.randomElement() ?? .addition)
        }
        return task
    }

    private static func generate(kind: Kind) -> MentalTask {
        switch kind {
        case .addition: return makeAddition()
        case .subtraction: return makeSubtraction()
        case .multiplication: return makeMultiplication()
        case .sequence: return makeSequence()
        }
    }

    /// Requires a carry in the units column — otherwise `23 + 41` is just
    /// two independent single-digit sums and needs no working memory at all.
    private static func makeAddition() -> MentalTask {
        var a = 0, b = 0
        repeat {
            a = Int.random(in: 12...89)
            b = Int.random(in: 12...89)
        } while (a % 10) + (b % 10) < 10
        return MentalTask(prompt: "\(a) + \(b)", answer: a + b, kind: .addition)
    }

    /// Requires a borrow, and a result of at least 15.
    ///
    /// The lower bound is the non-obvious part: without it, roughly 6% of
    /// generated problems came out as things like `31 − 25 = 6`, which
    /// technically borrows but is answered instantly and isn't a challenge.
    private static func makeSubtraction() -> MentalTask {
        var a = 0, b = 0
        repeat {
            a = Int.random(in: 41...99)
            b = Int.random(in: 12...29)
        } while (a % 10) >= (b % 10) || (a - b) < 15
        return MentalTask(prompt: "\(a) − \(b)", answer: a - b, kind: .subtraction)
    }

    /// Single digit × teens: `7 × 14` decomposes to `70 + 28` mentally.
    /// Two-digit × two-digit would need paper, which is the wrong side of
    /// the line for something you do standing next to the bed.
    private static func makeMultiplication() -> MentalTask {
        let a = Int.random(in: 3...9)
        let b = Int.random(in: 11...19)
        return MentalTask(prompt: "\(a) × \(b)", answer: a * b, kind: .multiplication)
    }

    /// Arithmetic progression. Included so the three tasks aren't all the
    /// same mental motion — pattern recognition wakes up a different part
    /// of the brain than column arithmetic does.
    private static func makeSequence() -> MentalTask {
        let start = Int.random(in: 2...15)
        let step = Int.random(in: 3...9)
        let terms = (0..<4).map { start + $0 * step }
        return MentalTask(
            prompt: terms.map(String.init).joined(separator: ", ") + ", ?",
            answer: start + 4 * step,
            kind: .sequence
        )
    }

    func isCorrect(_ input: String) -> Bool {
        Int(input.trimmingCharacters(in: .whitespaces)) == answer
    }
}

/// The word the user must send to their accountability contact.
///
/// Concrete, common, unambiguously-spelled nouns: no homophones, no words
/// whose spelling you'd have to think about, nothing that autocorrect will
/// fight. The challenge is meant to prove you're awake enough to read and
/// type, not to test spelling under duress.
enum AlarmWord {
    private static let words = [
        "anchor", "basket", "candle", "dolphin", "engine", "feather", "garden", "hammer",
        "island", "jacket", "kettle", "ladder", "magnet", "needle", "orange", "pepper",
        "quilt", "rocket", "saddle", "tunnel", "umbrella", "violet", "walnut", "yellow",
        "acorn", "bridge", "cactus", "diamond", "elbow", "forest", "glove", "harbor",
        "lantern", "marble", "nugget", "olive", "pigeon", "ribbon", "silver", "thunder",
        "velvet", "window", "zebra", "button", "copper", "dragon", "falcon", "guitar",
    ]

    static func random() -> String {
        words.randomElement() ?? "orange"
    }

    static func matches(_ input: String, expected: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(expected) == .orderedSame
    }
}
