import SwiftUI

/// GIF search (KLIPY / GIPHY).
///
/// FIX: it was a plain system sheet — grey `.secondary` text, `.tint` icons and a
/// system-grey search field. It now follows the app theme.
struct GIFPickerView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    let onPicked: (GIFAttachment) -> Void

    private var service: GIFService { container.tenorService }
    private var theme: AppTheme { container.appearanceStore.appTheme }

    var body: some View {
        NavigationStack {
            Group {
                if !service.isEnabled {
                    consentGate
                } else if !service.isConfigured {
                    ThemedEmptyState(
                        title: "GIF search isn't set up",
                        systemImage: "wrench.and.screwdriver",
                        description: "This build has no GIF_API_KEY. Get a free key at partner.klipy.com and add it to Info.plist.",
                        placement: .background
                    )
                } else {
                    grid
                }
            }
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .appScreenStyle()
        }
    }

    private var consentGate: some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.tint)
            Text("GIFs come from \(service.providerName)")
                .font(.headline)
                .foregroundStyle(theme.isCustom ? theme.backgroundText : Color.primary)

            VStack(alignment: .leading, spacing: 10) {
                Label("Your search terms go to \(service.providerName).", systemImage: "magnifyingglass")
                Label("\(service.providerName) sees your IP address when you search or load a GIF.", systemImage: "network")
                Label("The GIF link is sent end-to-end encrypted. The other person's phone loads it from \(service.providerName) — automatically only if they turned GIFs on, otherwise after they tap it.", systemImage: "lock.fill")
            }
            .font(.footnote)
            .foregroundStyle(theme.onBackground)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Turn on GIFs") {
                service.isEnabled = true
                service.search("")
            }
            .buttonStyle(.themedProminent)

            Text("You can turn this off again in Settings → Privacy.")
                .font(.caption2)
                .foregroundStyle(theme.onBackground)
        }
        .padding(28)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            searchField

            if let error = service.errorMessage {
                StatusText(error, .warning)
                    .padding()
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(service.results) { gif in
                        Button {
                            onPicked(service.attachment(for: gif))
                            dismiss()
                        } label: {
                            AnimatedGIFView(url: gif.previewURL, maxPixelSize: 240)
                                .frame(height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(gif.description)
                    }
                }
                .padding(4)
            }
            .overlay {
                if service.isSearching && service.results.isEmpty {
                    ProgressView()
                }
            }

            // Required attribution.
            Text("Powered by \(service.providerName)")
                .font(.caption2.bold())
                .foregroundStyle(theme.onBackground)
                .padding(.vertical, 6)
        }
        .task {
            if service.results.isEmpty { service.search("") }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Search \(service.providerName)", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: query) { _, newValue in service.search(newValue) }
            if !query.isEmpty {
                Button {
                    query = ""
                    service.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
        }
        .themedField()
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
