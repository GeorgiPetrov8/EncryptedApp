import Foundation
import CoreLocation

/// #8: a shared location — a single point, not live tracking.
///
/// Rides inside the encrypted text message (`TextPayload.location`), like GIFs,
/// so the server never sees the coordinates and needs no change. An older app
/// version shows the fallback text "📍 Location".
struct LocationAttachment: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    /// Metres. Shown as "± 20 m".
    let accuracy: Double?
    /// Optional label typed by the sender ("Café on the corner").
    let label: String?

    static let fallbackText = "📍 Location"
    static let maxLabelLength = 80

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Received values come from another phone: reject out-of-range or
    /// non-finite numbers, clean the label (no new lines / bidi tricks).
    func validated() -> LocationAttachment? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let cleanAccuracy = accuracy.flatMap { $0.isFinite && $0 >= 0 ? min($0, 100_000) : nil }
        return LocationAttachment(
            latitude: latitude,
            longitude: longitude,
            accuracy: cleanAccuracy,
            label: SafeText.line(label, maxLength: Self.maxLabelLength)
        )
    }

    /// "42.69766, 23.32196" — 5 decimals ≈ 1 m.
    var coordinateText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    // MARK: Opening in a maps app

    var appleMapsURL: URL? {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: label ?? "Shared location"),
        ]
        return components?.url
    }

    /// The Google Maps app (needs `comgooglemaps` in LSApplicationQueriesSchemes).
    var googleMapsAppURL: URL? {
        URL(string: "comgooglemaps://?q=\(latitude),\(longitude)&center=\(latitude),\(longitude)&zoom=16")
    }

    /// Fallback in Safari when the Google Maps app isn't installed.
    var googleMapsWebURL: URL? {
        URL(string: "https://www.google.com/maps/search/?api=1&query=\(latitude),\(longitude)")
    }
}
