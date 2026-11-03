import Foundation
import CoreLocation

/// #8: one location reading, on request.
///
/// "When in use" permission only, and `requestLocation()` — a single fix, never
/// continuous updates. Nothing runs in the background and nothing is stored.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum LocationError: LocalizedError {
        case denied
        case unavailable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .denied: return "Location access is off. Allow it for SecureHyperChat in Settings to share where you are."
            case .unavailable: return "Couldn't get your location. Try again outside or with Wi-Fi on."
            case .timedOut: return "Getting your location took too long. Try again."
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func currentLocation() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { authContinuation = $0; manager.requestWhenInUseAuthorization() }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: throw LocationError.denied
        }

        continuation?.resume(throwing: LocationError.unavailable)
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(LocationError.timedOut))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            self.authContinuation?.resume()
            self.authContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if (error as? CLError)?.code == .denied {
                self.finish(.failure(LocationError.denied))
            } else {
                self.finish(.failure(LocationError.unavailable))
            }
        }
    }
}
