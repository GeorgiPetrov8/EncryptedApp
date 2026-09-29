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

        // Live updates: `itemsByConversation` changes when a remote operation
        // arrives or a local one is applied, so a peer ticking something off
        // shows up while this screen is open.
        cancellable = notePadService.$itemsByConversation
            .map { $0[conversation.id] ?? [] }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.items = $0 }

        // Re-sends anything that failed to transmit while offline. Safe to do
        // on every open because the merge is idempotent — see
        // `NotePadService.resyncOwnItems`.
        Task { await notePadService.resyncOwnItems(in: conversation) }
    }

    private var liveItems: [NotePadItem] {
        items.filter { !$0.isDeleted }
    }

    /// Kept separate rather than one sorted list, so the two groups can have
    /// different delete affordances — see `NotePadView`.
    var outstandingItems: [NotePadItem] {
        liveItems.filter { !$0.isDone }.sorted { $0.updatedAt < $1.updatedAt }
    }

    var completedItems: [NotePadItem] {
        liveItems.filter(\.isDone).sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Retained for the badge count in `ChatView`.
    var visibleItems: [NotePadItem] { outstandingItems + completedItems }

    var remainingCount: Int { outstandingItems.count }

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

    func deleteOutstanding(at offsets: IndexSet) {
        let list = outstandingItems
        for index in offsets where list.indices.contains(index) {
            delete(list[index])
        }
    }

    func deleteCompleted(at offsets: IndexSet) {
        let list = completedItems
        for index in offsets where list.indices.contains(index) {
            delete(list[index])
        }
    }

    /// Bulk-clears finished items.
    func deleteCompleted() {
        for item in completedItems { delete(item) }
    }
}
