import SwiftUI

/// #13: progress bar + checklist under a notepad item.
///
/// Each change goes through `onChange`, which the row hands to
/// `NotePadService.updateSubtasks` — the normal notepad sync path.
struct NotePadSubtasksView: View {
    let item: NotePadItem
    let onChange: (NotePadSubtaskEdit.Result) -> Void

    @Environment(\.appTheme) private var theme
    @State private var newText = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = item.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .tint(theme.isCustom ? theme.text : .green)
                    Text("\(item.doneSubtaskCount)/\(item.checklist.count) done")
                        .font(.caption.monospacedDigit())
                        .themedSecondary()
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(item.checklist) { subtask in
                HStack(spacing: 10) {
                    Button {
                        onChange(NotePadSubtaskEdit.toggle(subtask.id, in: item))
                    } label: {
                        Image(systemName: subtask.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.isDone && !theme.isCustom ? Color.green : theme.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtask.isDone ? "Mark not done" : "Mark done")

                    Text(subtask.text)
                        .font(.subheadline)
                        .strikethrough(subtask.isDone)
                        .foregroundStyle(subtask.isDone ? theme.secondaryText : theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onChange(NotePadSubtaskEdit.remove(subtask.id, from: item))
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove step")
                }
            }

            if item.checklist.count < NotePadSubtaskLimits.maxCount {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(theme.secondaryText)
                    TextField("Add a step", text: $newText)
                        .font(.subheadline)
                        .focused($addFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    if !newText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Add", action: add)
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.tint)
                    }
                }
            }
        }
        .padding(.leading, 34)
        .padding(.vertical, 4)
    }

    private func add() {
        guard let result = NotePadSubtaskEdit.add(newText, to: item) else { return }
        newText = ""
        onChange(result)
        addFocused = true
    }
}
