import SwiftUI

/// Shown instead of crashing when the local database can't be opened (R23).
///
/// Offers: try again (transient problems such as a locked device or full disk),
/// and — after a confirmation — move the database aside and start empty. The
/// old file is renamed, not deleted, so nothing is destroyed; keys in the
/// Keychain are untouched, so signing in again works and a backup can be
/// restored.
struct DatabaseFailureView: View {
    let error: Error
    let retry: () -> Void

    @State private var confirmReset = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("SecureHyperChat couldn't open its data")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("This can happen when the phone is low on space or was restarted and not yet unlocked. Free some space or unlock the phone, then try again.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text(String(describing: error))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)

            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)

            Button("Start with empty history…", role: .destructive) { confirmReset = true }
                .font(.footnote)

            if let message {
                Text(message).font(.footnote)
            }
        }
        .padding(28)
        .confirmationDialog("Start with empty history?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Move old data aside and restart", role: .destructive) { moveDatabaseAside() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current database is kept as a separate file, not deleted. Your keys are kept, so you can sign in again or restore a backup.")
        }
    }

    private func moveDatabaseAside() {
        guard let url = AppContainer.databaseFileURL else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: url.path + ".broken-\(stamp)" + suffix)
            try? FileManager.default.moveItem(at: source, to: target)
        }
        message = "Moved. Starting again…"
        retry()
    }
}
