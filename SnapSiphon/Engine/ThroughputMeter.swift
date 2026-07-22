import Foundation

/// Tracks a smoothed bytes-per-second reading over a sliding window, for the
/// live "1.4 MB/s" readout on the dashboard.
struct ThroughputMeter {
    private var samples: [(time: Date, bytes: Int64)] = []
    private let window: TimeInterval = 5

    mutating func record(bytes: Int64, at time: Date = Date()) {
        samples.append((time, bytes))
        let cutoff = time.addingTimeInterval(-window)
        samples.removeAll { $0.time < cutoff }
    }

    /// Current bytes/second over the window.
    func bytesPerSecond(now: Date = Date()) -> Double {
        guard let first = samples.first, samples.count > 1 else { return 0 }
        let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
        let span = max(0.5, now.timeIntervalSince(first.time))
        return Double(total) / span
    }

    mutating func reset() { samples.removeAll() }
}
