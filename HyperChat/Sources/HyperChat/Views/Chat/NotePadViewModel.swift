import Foundation
import Combine

@MainActor
final class NotePadViewModel: ObservableObject {
    @Published var newItemText = ""
    @Published private(set) var items: [NotePadItem] = []

    let conversation: Conversation
    private let notePadService: NotePadService
    private var cancellable: AnyCancellable?

    init(conversation: Conversation, notePadService: NotePadService) {
        self.conversation = conversation
        self.notePadService = notePadService

        notePadService.loadItems(for: conversation)
        items = notePadService.items(for: conversation.id)

        // FIX (shared notepad): live updates.
        //
        // `NotePadService.itemsByConversation` changes whenever a remote
        // operation arrives (`MessagingService.handleIncoming` →
        // `applyRemoteOperation`) or a local one is applied
        // (`NotePadService.apply`). Subscribing here, rather than requiring
        // the view to poll or the parent `ChatView` to manually refresh it,
        // is what makes a peer's checkbox toggle show up on this screen
        // while it's open, the same way an incoming chat message appears
        // in `ChatViewModel` without the user pulling to refresh.
        cancellable = notePadService.$itemsByConversation
            .map { $0[conversation.id] ?? [] }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.items = $0 }
    }

    /// Non-deleted items, unfinished first.
    ///
    /// Finished items stay visible rather than being hidden or auto-purged:
    /// for a shared buy/todo pad, "did we already get milk?" needs an
    /// answer without scrolling back through chat history, which is the
    /// whole reason this feature exists instead of just typing "buy milk"
    /// as a normal message. Within each group, oldest-edited-first, so a
    /// freshly re-ticked or re-added item doesn't jump to a surprising spot.
    var visibleItems: [NotePadItem] {
        items
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.isDone != rhs.isDone { return !lhs.isDone }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    var remainingCount: Int {
        visibleItems.filter { !$0.isDone }.count
    }

    func addItem() {
        let text = newItemText
        newItemText = ""
        Task { await notePadService.addItem(text: text, in: conversation) }
    }

    func toggle(_ item: NotePadItem) {
        Task { await notePadService.toggleItem(item, in: conversation) }
    }

    func rename(_ item: NotePadItem, to newText: String) {
        guard newText.trimmingCharacters(in: .whitespacesAndNewlines) != item.text else { return }
        Task { await notePadService.updateText(item, newText: newText, in: conversation) }
    }

    func delete(_ item: NotePadItem) {
        Task { await notePadService.deleteItem(item, in: conversation) }
    }

    func delete(at offsets: IndexSet) {
        let visible = visibleItems
        for index in offsets {
            delete(visible[index])
        }
    }
}
