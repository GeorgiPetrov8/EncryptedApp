import SwiftUI

/// The shared note/todo/get/buy pad for one conversation.
///
/// Presented as a sheet from `ChatView`. Unlike `VerifyIdentityView`
/// (which only needs `container` inside `.onAppear`/button actions, after
/// the environment is already available), this view owns a `@StateObject`
/// that must be constructed synchronously in `init` — before
/// `@EnvironmentObject` values are readable. So `container` is taken as an
/// explicit init parameter here, the same way `ChatView` itself already
/// takes it, rather than pulled from the environment.
struct NotePadView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: NotePadViewModel
    @FocusState private var addFieldFocused: Bool

    init(container: AppContainer, conversation: Conversation) {
        _viewModel = StateObject(
            wrappedValue: NotePadViewModel(conversation: conversation, notePadService: container.notePadService)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.visibleItems.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "checklist",
                        description: Text("Add something to get, do, or remember — it's shared and end-to-end encrypted, just like the chat.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.visibleItems) { item in
                        NotePadRow(
                            item: item,
                            onToggle: { viewModel.toggle(item) },
                            onRename: { newText in viewModel.rename(item, to: newText) }
                        )
                    }
                    .onDelete { viewModel.delete(at: $0) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Shared Pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                addItemBar
            }
        }
    }

    private var addItemBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            TextField("Add an item…", text: $viewModel.newItemText)
                .textFieldStyle(.plain)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    viewModel.addItem()
                    addFieldFocused = true // stay focused for rapid multi-item entry
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct NotePadRow: View {
    let item: NotePadItem
    let onToggle: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editedText = ""
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")

            if isEditing {
                TextField("Item", text: $editedText)
                    .focused($editFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { commitEdit() }
                    .onAppear {
                        editedText = item.text
                        editFieldFocused = true
                    }
            } else {
                Text(item.text)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .onTapGesture { isEditing = true }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onChange(of: editFieldFocused) { _, focused in
            // Editing ends when the field loses focus (tap elsewhere), not
            // only on explicit submit — matches standard iOS list-row
            // inline-editing behaviour (e.g. Reminders).
            if !focused && isEditing { commitEdit() }
        }
    }

    private func commitEdit() {
        isEditing = false
        onRename(editedText)
    }
}
