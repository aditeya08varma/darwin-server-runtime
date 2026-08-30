// Tests for MetricsRingBuffer: correct FIFO ordering, correct
// drop-oldest-when-full eviction, and - the actual claim the whole
// "actor-guarded" design rests on - genuine safety under real concurrent
// access from multiple tasks at once.
import XCTest
@testable import Telemetry

final class MetricsRingBufferTests: XCTestCase {
    private func sample(_ jobID: String) -> TimestampedMetrics {
        TimestampedMetrics(jobID: jobID, metrics: TaskMetrics(residentBytes: 0, userTimeSeconds: 0, systemTimeSeconds: 0))
    }

    /// The basic contract: samples come back out in the same order they
    /// went in, and draining leaves the buffer empty.
    func testAppendAndDrainReturnsSamplesInOrder() async {
        let buffer = MetricsRingBuffer(capacity: 10)
        await buffer.append(sample("job-1"))
        await buffer.append(sample("job-2"))
        await buffer.append(sample("job-3"))

        let drained = await buffer.drainAll()
        XCTAssertEqual(drained.map(\.jobID), ["job-1", "job-2", "job-3"])

        let countAfterDrain = await buffer.count
        XCTAssertEqual(countAfterDrain, 0)

        let secondDrain = await buffer.drainAll()
        XCTAssertTrue(secondDrain.isEmpty)
    }

    /// The bounded-memory guarantee: once the buffer is full, appending
    /// another sample drops the single oldest one rather than growing
    /// past capacity or rejecting the new sample.
    func testBufferDropsOldestSampleWhenOverCapacity() async {
        let buffer = MetricsRingBuffer(capacity: 3)
        for i in 1...5 {
            await buffer.append(sample("job-\(i)"))
        }

        let countBeforeDrain = await buffer.count
        XCTAssertEqual(countBeforeDrain, 3, "buffer must never exceed its configured capacity")

        let drained = await buffer.drainAll()
        XCTAssertEqual(
            drained.map(\.jobID),
            ["job-3", "job-4", "job-5"],
            "the two oldest samples (job-1, job-2) should have been dropped, keeping the most recent three"
        )
    }

    /// The actual reason this is an actor rather than a plain class: many
    /// tasks appending concurrently must never corrupt the buffer or lose
    /// an append to a race. Spins up 100 concurrent appends and confirms
    /// every single one is accounted for - a buffer with no actual
    /// concurrency safety would be expected to occasionally drop or
    /// corrupt entries under this, not consistently pass.
    func testConcurrentAppendsAreAllSafelyRecorded() async {
        let buffer = MetricsRingBuffer(capacity: 1000)

        await withTaskGroup(of: Void.self) { group in
            for i in 1...100 {
                group.addTask {
                    await buffer.append(self.sample("job-\(i)"))
                }
            }
        }

        let drained = await buffer.drainAll()
        XCTAssertEqual(drained.count, 100, "every concurrent append must be recorded, none lost to a race")
        XCTAssertEqual(Set(drained.map(\.jobID)).count, 100, "no sample should be duplicated or corrupted")
    }
}
