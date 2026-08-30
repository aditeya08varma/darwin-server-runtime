// A bounded queue of metric samples, sitting between MachMetricsSampler
// (which produces samples) and OTelExporter (which will drain and ship
// them). "Bounded" is the operative word: if the exporter ever falls
// behind - a slow network, a collector that's down - memory here still
// cannot grow without limit, since the oldest sample gets dropped to make
// room for each new one once the buffer is full.
//
// This is deliberately not described as "lock-free." A true lock-free
// SPSC ring buffer needs ManagedBuffer and manual atomic operations, real
// engineering effort with real risk of subtle bugs, for a benefit this
// project's expected sampling rate (roughly one sample per job per
// second, not thousands per second) doesn't actually need. An actor is
// simpler, safer, and plenty fast enough here: it guarantees only one
// piece of code touches the buffer at a time, without a single hand-written
// lock, which is what "actor-guarded" means as opposed to "lock-free."
import Foundation

/// One timestamped sample, ready to be queued for export.
public struct TimestampedMetrics: Sendable, Equatable {
    public let timestamp: Date
    public let jobID: String
    public let metrics: TaskMetrics

    public init(timestamp: Date = Date(), jobID: String, metrics: TaskMetrics) {
        self.timestamp = timestamp
        self.jobID = jobID
        self.metrics = metrics
    }
}

public actor MetricsRingBuffer {
    private var buffer: [TimestampedMetrics] = []
    private let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Appends one sample. If the buffer is already at capacity, the
    /// single oldest sample is dropped first to make room - this is what
    /// keeps the buffer's memory bounded regardless of how long sampling
    /// runs or how far behind the exporter falls, at the honest cost of
    /// losing old data rather than new data when that happens. Dropping
    /// the oldest entry is an O(n) array shift, not an O(1) operation;
    /// for this project's expected sampling rate that cost is not worth
    /// the added complexity of a true circular buffer with wraparound
    /// indices.
    public func append(_ sample: TimestampedMetrics) {
        buffer.append(sample)
        if buffer.count > capacity {
            buffer.removeFirst()
        }
    }

    /// Removes and returns every sample currently queued, in the order
    /// they were appended, leaving the buffer empty. This is how
    /// OTelExporter will drain the buffer for one batch export.
    public func drainAll() -> [TimestampedMetrics] {
        let drained = buffer
        buffer.removeAll()
        return drained
    }

    /// The number of samples currently queued, mostly useful for tests
    /// and for observability logging rather than anything the export
    /// path itself needs to check.
    public var count: Int {
        buffer.count
    }
}
