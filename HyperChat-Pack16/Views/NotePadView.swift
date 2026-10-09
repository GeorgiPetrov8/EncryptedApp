import SwiftUI

/// The shared note/todo/get/buy pad for one conversation.
struct NotePadView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: NotePadViewModel
    @ObservedObject private var appearanceStore: AppearanceStore
    @FocusState private var addFieldFocused: Bool

    init(container: AppContainer, conversation: Conversation) {
        _appearanceStore = ObservedObject(wrappedValue: container.appearanceStore)
        _viewModel = StateObject(
            wrappedValue: NotePadViewModel(
                conversation: conversation,
                notePadService: container.notePadService
            )
        )
    }

    /// Read explicitly: an `@Environment(\.appTheme)` declared here would be the
    /// value from *outside* `.appScreenStyle()` (the default look), because this
    /// view is the one applying it.
    private var theme: AppTheme { appearanceStore.appTheme }

    var body: some View {
        ThemedNavigationStack {
            List {
                if viewModel.visibleItems.isEmpty {
                    // FIX: this was inside a section, which drew it as one big
                    // rectangular card. It now sits straight on the background.
                    ThemedEmptyState(
                        title: "Nothing here yet",
                        systemImage: "checklist",
                        description: "Add something to get, do, or remember — it's shared and end-to-end encrypted, just like the chat.",
                        placement: .background
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    outstandingSection
                    completedSection
                }
            }
            // FIX: was `.plain`, whose pinned headers have their own system
            // background — a different surface from every other screen.
            .listStyle(.insetGrouped)
            .navigationTitle("Shared Pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if viewModel.completedItems.count > 1 {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Clear done") { viewModel.deleteCompleted() }
                            .font(.footnote)
                    }
                }
            }
            // FIX: the add bar was attached AFTER `.appScreenStyle()` (and once
            // more by a duplicate call), so it sat outside the themed scope in a
            // system material. It now sits inside it, as a notch like the chat
            // composer.
            .safeAreaInset(edge: .bottom) { addItemBar }
            .appScreenStyle()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var outstandingSection: some View {
        if !viewModel.outstandingItems.isEmpty {
            ThemedSection {
                ForEach(viewModel.outstandingItems) { item in
                    NotePadRow(
                        item: item,
                        showsDeleteButton: false,
                        onToggle: { viewModel.toggle(item) },
                        onRename: { viewModel.rename(item, to: $0) },
                        onDelete: { viewModel.delete(item) }
                    )
                }
                .onDelete { viewModel.deleteOutstanding(at: $0) }
            } header: {
                Text("To do (\(viewModel.outstandingItems.count))")
            }
        }
    }

    @ViewBuilder
    private var completedSection: some View {
        if !viewModel.completedItems.isEmpty {
            ThemedSection {
                ForEach(viewModel.completedItems) { item in
                    NotePadRow(
                        item: item,
                        showsDeleteButton: true,
                        onToggle: { viewModel.toggle(item) },
                        onRename: { viewModel.rename(item, to: $0) },
                        onDelete: { viewModel.delete(item) }
                    )
                }
                .onDelete { viewModel.deleteCompleted(at: $0) }
            } header: {
                Text("Done (\(viewModel.completedItems.count))")
            }
        }
    }

    // MARK: Composer

    private var addItemBar: some View {
        let current = theme
        return HStack(spacing: 10) {
            ThemedTextField("Add an item…", text: $viewModel.newItemText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(current.tint.opacity(canSubmit ? 1 : 0.4))
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Add item")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .notchStyle(current.chrome)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var canSubmit: Bool {
        !viewModel.newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        viewModel.addItem()
        // Focus is kept so several items can be added in a row.
        addFieldFocused = true
    }
}

private struct NotePadRow: View {
    let item: NotePadItem
    let showsDeleteButton: Bool
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.appTheme) private var theme

    @State private var isEditing = false
    @State private var editedText = ""
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Done is a filled tick, not-done an empty circle — the shape tells
            // them apart, so no green/grey is needed.
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone && !theme.isCustom ? Color.green : theme.text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark not done" : "Mark done")

            if isEditing {
                TextField("Item", text: $editedText)
                    .focused($editFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(commitEdit)
                    .onAppear {
                        editedText = item.text
                        editFieldFocused = true
                    }
            } else {
                // A finished item is struck through (and secondary on the default
                // look). On a custom background it keeps full contrast.
                Text(item.text)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? theme.secondaryText : theme.text)
                    .onTapGesture { isEditing = true }
            }

            Spacer(minLength: 8)

            // A visible delete for completed items; swipe-to-delete remains for all.
            if showsDeleteButton && !isEditing {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete item")
            }
        }
        .contentShape(Rectangle())
        .onChange(of: editFieldFocused) { _, focused in
            // Ends editing on focus loss, not only on explicit submit.
            if !focused && isEditing { commitEdit() }
        }
    }

    private func commitEdit() {
        isEditing = false
        onRename(editedText)
    }
}
