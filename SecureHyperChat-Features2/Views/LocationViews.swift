import SwiftUI
import MapKit

/// #8: "Share location" sheet: get one fix, show it, optional label, send.
struct ShareLocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locator = LocationService()

    let onSend: (LocationAttachment) -> Void

    @State private var location: CLLocation?
    @State private var label = ""
    @State private var isLocating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                ThemedSection {
                    if let location {
                        LabeledContent("Coordinates") {
                            Text(String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude))
                                .font(.footnote.monospacedDigit())
                        }
                        LabeledContent("Accuracy", value: "± \(Int(location.horizontalAccuracy)) m")
                    } else if isLocating {
                        HStack { ProgressView(); Text("Finding your location…") }
                    }
                    TextField("Label (optional)", text: $label)
                        .onChange(of: label) { _, value in
                            if value.count > LocationAttachment.maxLabelLength {
                                label = String(value.prefix(LocationAttachment.maxLabelLength))
                            }
                        }
                } footer: {
                    Text("Sends this one point, end-to-end encrypted. It doesn't follow you afterwards.")
                }

                if let errorMessage {
                    ThemedSection { StatusText(errorMessage, .error) }
                }
            }
            .navigationTitle("Share Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .bold()
                        .disabled(location == nil)
                }
            }
            .appScreenStyle()
            .task { await locate() }
        }
        .presentationDetents([.medium])
    }

    private func locate() async {
        isLocating = true
        defer { isLocating = false }
        do {
            location = try await locator.currentLocation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send() {
        guard let location else { return }
        let attachment = LocationAttachment(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            label: label
        ).validated()
        guard let attachment else { return }
        onSend(attachment)
        dismiss()
    }
}

/// #8: the location bubble.
///
/// The map picture is **not** loaded automatically: drawing it asks Apple Maps
/// for the tiles around the point, i.e. tells Apple roughly where the
/// coordinates are. It loads only when you tap "Show map" (the same rule as
/// GIFs, which contact their provider only on request).
struct LocationBubble: View {
    let location: LocationAttachment
    let textColor: Color
    let bubbleColor: Color

    @Environment(\.openURL) private var openURL
    @State private var snapshot: UIImage?
    @State private var loadingMap = false
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mapArea
                .frame(width: 230, height: 130)
                .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Label(location.label ?? "Shared location", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(location.coordinateText)
                    .font(.caption2.monospacedDigit())
                if let accuracy = location.accuracy {
                    Text("± \(Int(accuracy)) m").font(.caption2)
                }
            }
            .padding(10)
        }
        .frame(width: 230, alignment: .leading)
        .background(bubbleColor)
        .foregroundStyle(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { showOptions = true }
        .confirmationDialog("Open location", isPresented: $showOptions, titleVisibility: .visible) {
            Button("Open in Apple Maps") {
                if let url = location.appleMapsURL { openURL(url) }
            }
            Button("Open in Google Maps") { openGoogle() }
            Button("Copy coordinates") { UIPasteboard.general.string = location.coordinateText }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the location in a maps app")
    }

    @ViewBuilder
    private var mapArea: some View {
        if let snapshot {
            ZStack {
                Image(uiImage: snapshot).resizable().scaledToFill()
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .red)
                    .shadow(radius: 2)
            }
        } else {
            ZStack {
                LinearGradient(colors: [.green.opacity(0.35), .blue.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if loadingMap {
                    ProgressView()
                } else {
                    Button {
                        Task { await loadSnapshot() }
                    } label: {
                        Label("Show map", systemImage: "map")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func openGoogle() {
        if let app = location.googleMapsAppURL, UIApplication.shared.canOpenURL(app) {
            openURL(app)
        } else if let web = location.googleMapsWebURL {
            openURL(web)
        }
    }

    private func loadSnapshot() async {
        loadingMap = true
        defer { loadingMap = false }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 600, longitudinalMeters: 600)
        options.size = CGSize(width: 230, height: 130)
        options.pointOfInterestFilter = .excludingAll
        snapshot = try? await MKMapSnapshotter(options: options).start().image
    }
}
