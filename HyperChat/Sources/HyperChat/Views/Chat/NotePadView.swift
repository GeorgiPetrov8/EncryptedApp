import SwiftUI

/// The shared note/todo/get/buy pad for one conversation.
///
/// This pack adds the two things that were missing (feature #1):
///   - an explicit **send button** next to the add field, matching the chat
///     composer, rather than return-key-only submission;
///   - a **delete affordance on completed items**, so finishing something and
///     clearing it are separate, discoverable actions.
struct NotePadView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: NotePadViewModel
    @FocusState private var addFieldFocused: Bool

    init(container: AppContainer, conversation: Conversation) {
        _viewModel = StateObject(
            wrappedValue: NotePadViewModel(
                conversation: conversation,
                notePadService: container.notePadService
            )
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
                    outstandingSection
                    completedSection
                }
            }
            .listStyle(.plain)
            .navigationTitle("Shared Pad")
            .appScreenStyle()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                // Clearing finished items one by one is tedious once a few
                // have piled up, which is the normal state of a shopping list
                // after a shop.
                if viewModel.completedItems.count > 1 {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Clear done") { viewModel.deleteCompleted() }
                            .font(.footnote)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { addItemBar }
        }
    }

    // MARK: Sections
    //
    // Split into two sections rather than one sorted list so the delete
    // affordance can differ: outstanding items are deleted by swiping (a
    // deliberate, slightly effortful gesture, because deleting something you
    // still need to do is usually a mistake), while completed items get a
    // visible tap target (because clearing them is routine).

    @ViewBuilder
    private var outstandingSection: some View {
        if !viewModel.outstandingItems.isEmpty {
            Section {
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
            Section {
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
        HStack(spacing: 10) {
            TextField("Add an item…", text: $viewModel.newItemText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .onSubmit(submit)

            // FIX (feature #1): the send button the pad was missing.
            //
            // Return-key-only submission is invisible on a soft keyboard and
            // impossible with an external one where Return may insert a
            // newline. It also made the pad inconsistent with the chat
            // composer directly beneath it in the same app.
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSubmit ? Color.brand : Color.secondary)
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Add item")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSubmit: Bool {
        !viewModel.newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        viewModel.addItem()
        // Focus is kept so several items can be added in a row without
        // reaching for the field again — the common case when writing a
        // shopping list.
        addFieldFocused = true
    }
}

private struct NotePadRow: View {
    let item: NotePadItem
    let showsDeleteButton: Bool
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

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
                    .onSubmit(commitEdit)
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

            Spacer(minLength: 8)

            // FIX (feature #1): visible delete for completed items.
            //
            // Swipe-to-delete stays available for everything, but it's a
            // hidden gesture. A ticked-off item is finished business, and
            // clearing it shouldn't require discovering a swipe.
            if showsDeleteButton && !isEditing {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete item")
            }
        }
        .contentShape(Rectangle())
        .onChange(of: editFieldFocused) { _, focused in
            // Ends editing on focus loss, not only on explicit submit —
            // matches inline list editing elsewhere on iOS.
            if !focused && isEditing { commitEdit() }
        }
    }

    private func commitEdit() {
        isEditing = false
        onRename(editedText)
    }
}
