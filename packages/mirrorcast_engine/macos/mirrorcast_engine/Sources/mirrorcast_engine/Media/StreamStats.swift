import Foundation

/// Estimates the offset between the phone's clock and the Mac's clock, the
/// way NTP does.
///
/// Every second the Mac sends PING(t0). The phone answers PONG(t0, p) where p
/// is its own monotonic clock. With RTT = now - t0, the phone's clock at the
/// midpoint was p, so `offset = p - (t0 + RTT/2)`. The sample with the smallest
/// RTT is the most accurate, so we keep a short window and use the best one.
///
/// With that offset, a frame stamped `pts` by the phone was captured at
/// `pts - offset` on the Mac's clock, giving the capture-to-display latency.
final class ClockSync {
    private struct Sample {
        let rttUs: Int64
        let offsetUs: Int64
    }

    private let samples = Locked([Sample]())
    private static let window = 10

    static func nowMicros() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000)
    }

    func addPong(sentAtUs t0: Int64, phoneTimeUs p: Int64) {
        let rtt = Self.nowMicros() - t0
        guard rtt >= 0, rtt < 2_000_000 else { return }
        let sample = Sample(rttUs: rtt, offsetUs: p - (t0 + rtt / 2))
        samples.withLock { list in
            list.append(sample)
            if list.count > Self.window { list.removeFirst(list.count - Self.window) }
        }
    }

    func reset() {
        samples.withLock { $0.removeAll() }
    }

    /// Latest round-trip time in milliseconds.
    var rttMs: Double? {
        samples.withLock { $0.last.map { Double($0.rttUs) / 1_000 } }
    }

    /// Capture-to-now latency for a frame with the phone timestamp `ptsUs`.
    func latencyMs(phonePtsUs: Int64) -> Double? {
        guard let best = samples.withLock({ $0.min { $0.rttUs < $1.rttUs } }) else { return nil }
        let capturedAtMacClock = phonePtsUs - best.offsetUs
        let latency = Double(Self.nowMicros() - capturedAtMacClock) / 1_000
        // Ignore nonsense (clock jumps, repeated frames with old timestamps).
        return (0...5_000).contains(latency) ? latency : nil
    }
}

/// Per-second counters for the stats overlay. Thread-safe.
final class StreamStats {
    struct Snapshot {
        let fps: Double
        let bitrateKbps: Double
        let latencyMs: Double?
    }

    private struct Counters {
        var frames = 0
        var bytes = 0
        var latencySum = 0.0
        var latencyCount = 0
        var since = Date()
    }

    private let counters = Locked(Counters())

    func addBytes(_ count: Int) {
        counters.withLock { $0.bytes += count }
    }

    func frameDisplayed(latencyMs: Double?) {
        counters.withLock { counters in
            counters.frames += 1
            if let latencyMs {
                counters.latencySum += latencyMs
                counters.latencyCount += 1
            }
        }
    }

    /// Returns the rates since the last call and starts a new interval.
    func takeSnapshot() -> Snapshot {
        counters.withLock { counters in
            let elapsed = max(Date().timeIntervalSince(counters.since), 0.001)
            let snapshot = Snapshot(
                fps: Double(counters.frames) / elapsed,
                bitrateKbps: Double(counters.bytes) * 8 / 1_000 / elapsed,
                latencyMs: counters.latencyCount > 0 ? counters.latencySum / Double(counters.latencyCount) : nil
            )
            counters = Counters()
            return snapshot
        }
    }

    func reset() {
        counters.withLock { $0 = Counters() }
    }
}
