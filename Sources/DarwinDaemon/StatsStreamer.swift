// Connects everything Stage 4 built into one real, running loop: samples
// a job's Mach task info on a timer, queues each sample in a bounded ring
// buffer, and periodically drains and ships a batch to an OTLP collector.
// This is the one place MachMetricsSampler, MetricsRingBuffer, and
// OTelExporter actually get used together, the same role BundlePuller
// plays for ImageStore's two pieces and ProcessSupervisor plays for
// Isolation's two backends.
import Foundation
import RuntimeCore
import Telemetry
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "stats-streamer")

enum StatsStreamer {
    /// How often to sample the job while streaming is active.
    private static let sampleIntervalSeconds: UInt64 = 1

    /// How many samples to accumulate before draining the buffer and
    /// sending a batch, rather than making one HTTP request per sample.
    private static let exportEveryNSamples = 5

    /// How many consecutive sampling failures to tolerate before giving
    /// up on this job entirely. A job whose binary was a shebang script
    /// (see JobSigner and DEBUGGING_LOG.md #13) will fail every single
    /// sample attempt, forever - without this, the loop would run and
    /// log a warning every second for as long as that job happens to
    /// stay alive, which is noisy without being useful.
    private static let maxConsecutiveSampleFailures = 3

    /// Confirms `jobID` is currently running, then starts a detached
    /// background task that samples and exports for it, replying
    /// immediately rather than waiting for the loop itself to do
    /// anything - the same "acknowledge the action, don't block the
    /// connection on the work" pattern ProcessSupervisor.stop uses.
    static func start(jobID: String, endpoint: String, state: DaemonState) async -> IPCResponse {
        guard let jobState = await state.state(ofJob: jobID), jobState == .running else {
            return .error(message: "no running job with ID \(jobID) to stream stats for")
        }

        Task.detached {
            await runLoop(jobID: jobID, endpoint: endpoint, state: state)
        }

        return .statsStarted(jobID: jobID)
    }

    /// The actual sampling loop: keeps going until the job is no longer
    /// running (or disappears from DaemonState entirely), sampling once
    /// per sampleIntervalSeconds, batching into the ring buffer, and
    /// flushing every exportEveryNSamples samples. Always does one final
    /// flush after the loop ends, so the last partial batch isn't lost.
    private static func runLoop(jobID: String, endpoint: String, state: DaemonState) async {
        let buffer = MetricsRingBuffer(capacity: 300)
        var samplesSinceLastExport = 0
        var consecutiveSampleFailures = 0

        while true {
            guard
                let currentState = await state.state(ofJob: jobID), currentState == .running,
                let process = await state.process(forJob: jobID)
            else {
                break
            }

            do {
                let metrics = try MachMetricsSampler.sample(pid: process.processIdentifier)
                await buffer.append(TimestampedMetrics(jobID: jobID, metrics: metrics))
                samplesSinceLastExport += 1
                consecutiveSampleFailures = 0
            } catch {
                consecutiveSampleFailures += 1
                if consecutiveSampleFailures == 1 {
                    logger.warning(
                        "failed to sample job \(jobID, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
                if consecutiveSampleFailures >= maxConsecutiveSampleFailures {
                    logger.error(
                        "giving up on stats streaming for job \(jobID, privacy: .public) after \(consecutiveSampleFailures) consecutive failures - its binary was likely not a compiled, JobSigner-signed Mach-O (e.g. a shebang script), which cannot be sampled"
                    )
                    break
                }
            }

            if samplesSinceLastExport >= exportEveryNSamples {
                await flush(buffer, jobID: jobID, endpoint: endpoint)
                samplesSinceLastExport = 0
            }

            try? await Task.sleep(nanoseconds: sampleIntervalSeconds * 1_000_000_000)
        }

        await flush(buffer, jobID: jobID, endpoint: endpoint)
        logger.info("stats streaming stopped for job \(jobID, privacy: .public)")
    }

    /// Drains every sample currently queued and exports them as one
    /// batch. A no-op if the buffer happens to be empty (nothing new
    /// since the last flush), and a logged-but-non-fatal warning if the
    /// export itself fails - a collector being temporarily unreachable
    /// should not crash the daemon or stop the sampling loop.
    private static func flush(_ buffer: MetricsRingBuffer, jobID: String, endpoint: String) async {
        let samples = await buffer.drainAll()
        guard !samples.isEmpty else { return }

        do {
            try await OTelExporter.export(samples, to: endpoint)
            logger.info("exported \(samples.count) sample(s) for job \(jobID, privacy: .public)")
        } catch {
            logger.warning(
                "failed to export samples for job \(jobID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
