// Tracks jobs the daemon knows about. This is deliberately small in
// Stage 1: since .exec always replies with an error until Stage 3 wires up
// real process spawning, no job can actually exist yet, so this always
// legitimately reports "no such job." What matters now is getting the
// concurrency-safe container in place, so Stage 3 only has to add real
// inserts into it rather than redesign how state is shared safely.
import RuntimeCore

/// Holds the daemon's in-memory record of every job it has started.
/// This is a Swift actor rather than a plain class specifically because
/// the socket server handles multiple connections concurrently, and an
/// actor guarantees only one piece of code touches `jobs` at a time,
/// without writing any manual locking.
actor DaemonState {
    private var jobs: [String: JobState] = [:]

    /// Looks up the current lifecycle state of a job by ID.
    /// Returns nil if no job with that ID has ever been recorded, which
    /// covers both "the ID is simply wrong" and, in Stage 1, "no job has
    /// ever been started at all," since .exec cannot create one yet.
    func state(ofJob jobID: String) -> JobState? {
        return jobs[jobID]
    }
}
