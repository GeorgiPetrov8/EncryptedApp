import Foundation

/// #19 "locked until": a clock that changing the phone's time doesn't move.
///
/// Every server response carries a `Date` header. The newest one is remembered
/// together with the device's uptime at that moment; "now" is that server time
/// plus the uptime that has passed since. Changing the date in Settings doesn't
/// change uptime, so it doesn't open a locked message early.
///
/// Limits: uptime resets on reboot, so after a restart the phone must reach the
/// server once before the anchor exists again — until then the device clock is
/// used. A modified app can of course ignore the lock entirely.
final class TrustedClock: @unchecked Sendable {
    static let shared = TrustedClock()

    private let lock = NSLock()
    private var anchor: (server: Date, uptime: TimeInterval)?

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Call with every HTTP response from our server (see SETUP: RealAPIClient).
    func record(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "Date"),
              let date = Self.parser.date(from: header) else { return }
        record(serverDate: date)
    }

    func record(serverDate: Date) {
        lock.lock(); defer { lock.unlock() }
        anchor = (serverDate, ProcessInfo.processInfo.systemUptime)
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        guard let anchor else { return Date() }
        return anchor.server.addingTimeInterval(ProcessInfo.processInfo.systemUptime - anchor.uptime)
    }

    var isAnchored: Bool {
        lock.lock(); defer { lock.unlock() }
        return anchor != nil
    }
}
