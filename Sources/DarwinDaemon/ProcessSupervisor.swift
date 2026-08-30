// Owns the full lifecycle of one exec'd job: choosing an isolation
// backend, launching it, capturing its output to log files, recording it
// in DaemonState, reaping its exit, and handling stop requests. This is
// the one place Isolation's engines actually get used together with a
// real running process, the same way BundlePuller is the one place
// ImageStore's two pieces get used together.
import Foundation
import RuntimeCore
import Isolation
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "process-supervisor")

enum ProcessSupervisor {
    /// How long a job gets to exit cleanly after SIGTERM before
    /// ProcessSupervisor escalates to SIGKILL. Chosen as a reasonable
    /// default for this project's scope, not derived from anything
    /// configurable yet.
    private static let stopGracePeriodSeconds: UInt64 = 5

    /// Starts one job: picks an isolation backend, spawns the process,
    /// attaches its stdout/stderr to real log files, launches it, and
    /// records it in `state`. Every failure along the way is caught and
    /// turned into an honest IPCResponse.error, the same pattern
    /// BundlePuller uses - the daemon should never crash because a
    /// client's ExecConfig pointed at a bad binary or a missing rootfs.
    static func start(_ config: ExecConfig, state: DaemonState) async -> IPCResponse {
        let jobID = UUID().uuidString
        let rootfs = URL(fileURLWithPath: config.rootfsPath)

        let process: Process
        do {
            process = try spawnWithFallback(config, rootfs: rootfs, jobID: jobID)
        } catch {
            logger.error("job \(jobID, privacy: .public) failed to spawn: \(String(describing: error), privacy: .public)")
            return .error(message: "failed to start job: \(error)")
        }

        do {
            try attachLogFiles(to: process, jobID: jobID)
        } catch {
            logger.error("job \(jobID, privacy: .public) failed to set up logging: \(String(describing: error), privacy: .public)")
            return .error(message: "failed to set up logging for job: \(error)")
        }

        process.terminationHandler = { finishedProcess in
            let wasKilled = finishedProcess.terminationReason == .uncaughtSignal
            Task {
                await state.recordJobFinished(id: jobID, exitCode: finishedProcess.terminationStatus, wasKilled: wasKilled)
            }
            logger.info("job \(jobID, privacy: .public) finished, status \(finishedProcess.terminationStatus), killed: \(wasKilled)")
        }

        do {
            try process.run()
        } catch {
            logger.error("job \(jobID, privacy: .public) failed to launch: \(String(describing: error), privacy: .public)")
            return .error(message: "failed to launch job: \(error)")
        }

        await state.recordJobStarted(id: jobID, process: process)
        logger.info("job \(jobID, privacy: .public) started")
        return .jobStarted(jobID: jobID)
    }

    /// Sends SIGTERM to the job's process immediately, then schedules a
    /// background check that escalates to SIGKILL if the process hasn't
    /// exited on its own within the grace period. Replies right away
    /// rather than waiting for the grace period to elapse - see
    /// IPCResponse.stopped's own documentation for why. gracePeriodSeconds
    /// defaults to the real production value but can be overridden, which
    /// exists specifically so a test can prove the SIGKILL escalation
    /// path actually works without waiting out the full production delay.
    static func stop(
        jobID: String,
        state: DaemonState,
        gracePeriodSeconds: UInt64 = stopGracePeriodSeconds
    ) async -> IPCResponse {
        guard let process = await state.process(forJob: jobID) else {
            if await state.state(ofJob: jobID) != nil {
                return .error(message: "job \(jobID) has already finished")
            }
            return .error(message: "no such job: \(jobID)")
        }

        process.terminate()

        let gracePeriod = gracePeriodSeconds
        Task.detached {
            try? await Task.sleep(nanoseconds: gracePeriod * 1_000_000_000)
            if process.isRunning {
                logger.warning("job \(jobID, privacy: .public) did not exit within the grace period, sending SIGKILL")
                kill(process.processIdentifier, SIGKILL)
            }
        }

        return .stopped(jobID: jobID)
    }

    /// Tries the Seatbelt backend first (the real, kernel-enforced
    /// sandbox), falling back to the weaker POSIX backend if Seatbelt
    /// fails to even prepare the process - logged as a warning so
    /// degraded isolation is observable, not silent, matching the
    /// resilience reasoning from the original project plan. If
    /// config.isolated is false, Seatbelt is skipped entirely and POSIX
    /// is used directly, since isolated=false is an explicit request not
    /// to sandbox at the kernel level.
    private static func spawnWithFallback(_ config: ExecConfig, rootfs: URL, jobID: String) throws -> Process {
        guard config.isolated else {
            return try POSIXIsolationEngine().spawn(config, rootfs: rootfs)
        }

        do {
            return try SeatbeltIsolationEngine().spawn(config, rootfs: rootfs)
        } catch {
            logger.warning(
                "job \(jobID, privacy: .public): Seatbelt spawn failed, falling back to POSIX: \(String(describing: error), privacy: .public)"
            )
            return try POSIXIsolationEngine().spawn(config, rootfs: rootfs)
        }
    }

    /// Creates a dedicated log directory for this job (keyed by the job's
    /// own ID, not the bundle's - a bundle can be exec'd more than once,
    /// and each run gets its own logs) and attaches stdout/stderr to real
    /// files there, so a job's output survives after it exits instead of
    /// only existing while something happens to be reading a pipe.
    private static func attachLogFiles(to process: Process, jobID: String) throws {
        let logDirectory = logDirectory(forJobID: jobID)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let stdoutURL = logDirectory.appendingPathComponent("stdout.log")
        let stderrURL = logDirectory.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
    }

    /// Computes where a job's log files live: under this user's
    /// Application Support directory, one folder per job ID. Mirrors
    /// BundlePuller's rootfsDirectory(forBundleID:) layout, but keyed by
    /// job ID in its own "job-logs" area rather than living alongside a
    /// bundle's rootfs, since a job and the bundle it runs are different
    /// things with different lifetimes.
    private static func logDirectory(forJobID jobID: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("darwin-runtime", isDirectory: true)
            .appendingPathComponent("job-logs", isDirectory: true)
            .appendingPathComponent(jobID, isDirectory: true)
    }
}
