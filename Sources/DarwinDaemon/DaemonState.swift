// Tracks every job the daemon has started: its current lifecycle state,
// its exit code once it has one, and - critically for .stop - a
// reference to the actual running Process, so a stop request can signal
// the real thing rather than just recording an intention.
import Foundation
import RuntimeCore

/// One job's full record: what it's doing, and (while running) the
/// Process needed to actually signal it.
struct JobRecord {
    var state: JobState
    var exitCode: Int32?
    var process: Process?
}

/// Holds the daemon's in-memory record of every job it has started.
/// This is a Swift actor rather than a plain class specifically because
/// the socket server handles multiple connections concurrently, and an
/// actor guarantees only one piece of code touches `jobs` at a time,
/// without writing any manual locking.
actor DaemonState {
    private var jobs: [String: JobRecord] = [:]

    /// Records a newly launched job as running, holding onto its Process
    /// so a later .stop request has something real to signal.
    func recordJobStarted(id: String, process: Process) {
        jobs[id] = JobRecord(state: .running, exitCode: nil, process: process)
    }

    /// Records that a job has finished, storing its real exit code and
    /// dropping the Process reference - once a process has exited there
    /// is nothing left to signal, so there's no reason to keep holding it.
    /// `killed` is used instead of `exited` when ProcessSupervisor itself
    /// caused the termination (a .stop request), so a client can tell the
    /// difference between "it finished on its own" and "we killed it."
    func recordJobFinished(id: String, exitCode: Int32, wasKilled: Bool) {
        guard var record = jobs[id] else { return }
        record.state = wasKilled ? .killed : .exited
        record.exitCode = exitCode
        record.process = nil
        jobs[id] = record
    }

    /// Looks up the current lifecycle state of a job by ID. Returns nil
    /// if no job with that ID has ever been recorded.
    func state(ofJob jobID: String) -> JobState? {
        return jobs[jobID]?.state
    }

    /// Looks up a job's exit code, if it has one yet (nil while running).
    func exitCode(ofJob jobID: String) -> Int32? {
        return jobs[jobID]?.exitCode
    }

    /// Looks up the actual running Process for a job, so .stop can send
    /// it a real signal. Returns nil for an unknown job or one that has
    /// already finished (and so has nothing left to signal).
    func process(forJob jobID: String) -> Process? {
        return jobs[jobID]?.process
    }
}
