import SwiftUI

/// Tenor GIF search (feature: GIFs).
struct GIFPickerView: View {
    @EnvironmentObject private var container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var isSending = false

    let onPicked: (Data) -> Void

    private var service: TenorService { container.tenorService }

    var body: some View {
        NavigationStack {
            Group {
                if !service.isEnabled {
                    consentGate
                } else if !service.isConfigured {
                    ContentUnavailableView(
                        "GIF search isn't set up",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("This build has no Tenor API key configured.")
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
        }
    }

    /// Shown before any network request is made.
    ///
    /// Spelled out rather than buried in a privacy policy, because in an app
    /// built on "nobody sees your messages", quietly sending what you type to
    /// Google would be the sort of thing a user would be right to be annoyed
    /// about discovering later.
    private var consentGate: some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("GIF search uses Tenor")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Label("Your search terms go to Tenor (owned by Google).", systemImage: "magnifyingglass")
                Label("Tenor sees your IP address when you search.", systemImage: "network")
                Label("The person you send it to never contacts Tenor — the GIF is sent encrypted, like any other attachment.", systemImage: "lock.fill")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Enable GIF search") {
                service.isEnabled = true
                service.search("")
            }
            .buttonStyle(.borderedProminent)

            Text("You can turn this off again in Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            searchField

            if let error = service.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
            }

            ScrollView {
                // A staggered two-column layout, because GIFs vary wildly in
                // aspect ratio and a fixed grid would either crop them or
                // leave large gaps.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(service.results) { gif in
                        GIFCell(gif: gif) { pick(gif) }
                    }
                }
                .padding(4)
            }
            .overlay {
                if service.isSearching && service.results.isEmpty {
                    ProgressView()
                }
            }
        }
        .task {
            // Featured GIFs on open, so the grid isn't empty before typing.
            if service.results.isEmpty { service.search("") }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search Tenor", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: query) { _, newValue in service.search(newValue) }
            if !query.isEmpty {
                Button {
                    query = ""
                    service.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func pick(_ gif: TenorGIF) {
        guard !isSending else { return }
        isSending = true
        Task {
            defer { isSending = false }
            do {
                // Downloaded here, then handed to the normal encrypted media
                // path — so the recipient never talks to Tenor.
                let data = try await service.downloadGIFData(gif)
                onPicked(data)
                dismiss()
            } catch {
                service.clear()
            }
        }
    }
}

private struct GIFCell: View {
    let gif: TenorGIF
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AsyncImage(url: gif.previewURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color(.tertiarySystemBackground)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                default:
                    Color(.tertiarySystemBackground)
                        .overlay(ProgressView())
                }
            }
            .frame(height: 110)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // The GIF itself is opaque to VoiceOver; Tenor's description is the
        // only text that makes it navigable.
        .accessibilityLabel(gif.description)
    }
}
