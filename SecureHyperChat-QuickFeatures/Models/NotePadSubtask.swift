import Foundation

/// #13: a checklist inside a notepad item.
///
/// The progress bar is *derived* from these (3 of 4 done → 75 %), never set by
/// hand. The subtasks travel inside the existing `NotePadOperation`, so the
/// whole item stays the last-writer-wins unit — no new payload type, no new
/// merge logic.
///
/// Known trade-off (accepted for v1): two people ticking *different* subtasks
/// of the same item before syncing — the later operation replaces the whole
/// list, so one tick is reverted. Stable ids keep text and order intact; only
/// the concurrent tick is lost. Candidate follow-up: merge per subtask.
struct NotePadSubtask: Codable, Equatable, Hashable, Identifiable {
    /// UUID, stable across edits.
    let id: String
    var text: String
    var isDone: Bool

    init(id: String = UUID().uuidString, text: String, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
}

enum NotePadSubtaskLimits {
    static let maxCount = 50
    static let maxTextLength = 200
    static let maxIdLength = 64
}

extension NotePadSubtask {
    /// Cleans a list from another phone: drops empty and duplicate entries,
    /// one line per subtask, capped in count and length.
    static func sanitized(_ list: [NotePadSubtask]?) -> [NotePadSubtask]? {
        guard let list else { return nil }
        var seen = Set<String>()
        var out: [NotePadSubtask] = []
        for item in list {
            guard !item.id.isEmpty, item.id.count <= NotePadSubtaskLimits.maxIdLength,
                  seen.insert(item.id).inserted,
                  let text = SafeText.line(item.text, maxLength: NotePadSubtaskLimits.maxTextLength)
            else { continue }
            out.append(NotePadSubtask(id: item.id, text: text, isDone: item.isDone))
            if out.count == NotePadSubtaskLimits.maxCount { break }
        }
        return out
    }
}

extension NotePadItem {
    var checklist: [NotePadSubtask] { subtasks ?? [] }

    var doneSubtaskCount: Int { checklist.filter(\.isDone).count }

    /// nil = no checklist (a plain item).
    var progress: Double? {
        let list = checklist
        guard !list.isEmpty else { return nil }
        return Double(list.filter(\.isDone).count) / Double(list.count)
    }
}

/// The edits the notepad UI can make, plus the rule for the item's own tick:
///   - the last open subtask ticked → the item is marked done automatically;
///   - a subtask un-ticked on a done item → the item reopens;
///   - otherwise the item's tick is left alone, so it can still be toggled by
///     hand (finish early, reopen after auto-completion).
enum NotePadSubtaskEdit {
    struct Result {
        let subtasks: [NotePadSubtask]
        /// nil = don't touch the item's `isDone`.
        let markDone: Bool?
    }

    static func toggle(_ id: String, in item: NotePadItem) -> Result {
        var list = item.checklist
        guard let index = list.firstIndex(where: { $0.id == id }) else {
            return Result(subtasks: list, markDone: nil)
        }
        list[index].isDone.toggle()
        let nowDone = list[index].isDone
        if nowDone, list.allSatisfy(\.isDone), !item.isDone { return Result(subtasks: list, markDone: true) }
        if !nowDone, item.isDone { return Result(subtasks: list, markDone: false) }
        return Result(subtasks: list, markDone: nil)
    }

    static func add(_ text: String, to item: NotePadItem) -> Result? {
        guard item.checklist.count < NotePadSubtaskLimits.maxCount,
              let clean = SafeText.line(text, maxLength: NotePadSubtaskLimits.maxTextLength)
        else { return nil }
        // A new open subtask reopens a finished item.
        return Result(subtasks: item.checklist + [NotePadSubtask(text: clean)], markDone: item.isDone ? false : nil)
    }

    static func remove(_ id: String, from item: NotePadItem) -> Result {
        let list = item.checklist.filter { $0.id != id }
        if !list.isEmpty, list.allSatisfy(\.isDone), !item.isDone { return Result(subtasks: list, markDone: true) }
        return Result(subtasks: list, markDone: nil)
    }
}
