// Reads a running job's real memory and CPU usage straight from the
// kernel via Mach task_info calls. Only works for a PID whose binary was
// signed with get-task-allow by JobSigner before it was spawned - see
// that file and DEBUGGING_LOG.md #12/#13 for why that's a precondition,
// not an optional nicety. Written entirely in Swift: unlike libarchive,
// Mach APIs (task_for_pid, task_info, and the types below) are part of
// the standard Darwin SDK and are directly callable via `import Darwin`,
// with no C bridging target needed at all.
import Darwin
import Foundation

/// One point-in-time snapshot of a task's resource usage.
public struct TaskMetrics: Sendable, Equatable {
    /// Resident memory, in bytes - the actual physical memory the task
    /// is currently using, not its full virtual address space.
    public let residentBytes: UInt64

    /// Total CPU time this task's threads have accumulated in user mode,
    /// in seconds, since the task started.
    public let userTimeSeconds: Double

    /// Total CPU time this task's threads have accumulated in kernel
    /// (system) mode, in seconds, since the task started.
    public let systemTimeSeconds: Double
}

public enum MachMetricsError: Error, CustomStringConvertible {
    case taskForPidFailed(kernReturn: kern_return_t)
    case taskInfoFailed(kernReturn: kern_return_t, flavor: String)

    public var description: String {
        switch self {
        case .taskForPidFailed(let kernReturn):
            return "task_for_pid failed (kern_return_t \(kernReturn)) - the target process's binary was likely not signed with get-task-allow before it was spawned"
        case .taskInfoFailed(let kernReturn, let flavor):
            return "task_info(\(flavor)) failed (kern_return_t \(kernReturn))"
        }
    }
}

public enum MachMetricsSampler {
    /// Samples the current memory and CPU usage of the process with the
    /// given PID. Acquires a Mach task port via task_for_pid (which only
    /// succeeds if that PID's binary was signed with get-task-allow),
    /// reads TASK_VM_INFO for memory and TASK_THREAD_TIMES_INFO for CPU
    /// time, and releases the task port before returning.
    public static func sample(pid: pid_t) throws -> TaskMetrics {
        var task: task_t = 0
        let taskResult = task_for_pid(mach_task_self_, pid, &task)
        guard taskResult == KERN_SUCCESS else {
            throw MachMetricsError.taskForPidFailed(kernReturn: taskResult)
        }
        defer { mach_port_deallocate(mach_task_self_, task) }

        let residentBytes = try readResidentSize(of: task)
        let (userSeconds, systemSeconds) = try readThreadTimes(of: task)

        return TaskMetrics(
            residentBytes: residentBytes,
            userTimeSeconds: userSeconds,
            systemTimeSeconds: systemSeconds
        )
    }

    /// Reads TASK_VM_INFO and returns phys_footprint, not resident_size.
    ///
    /// The first version of this function read resident_size, which
    /// seemed like the obvious field - its own comment says "resident
    /// memory size (bytes)". Verified live against a real job that
    /// allocated and touched 15MB, it reported under 1MB, consistently,
    /// regardless of whether the job was sandboxed or not (ruling out
    /// Seatbelt as the cause). resident_size is a legacy field with
    /// known accuracy problems on modern macOS - it does not reliably
    /// reflect a process's real memory use once the kernel's memory
    /// compressor and shared-page accounting are involved. phys_footprint
    /// is Apple's own newer, documented replacement for exactly this
    /// question, and is what Activity Monitor and modern profiling tools
    /// actually use. Confirmed by switching to it and re-running the
    /// same live test: it reported the expected ~15MB. See
    /// DEBUGGING_LOG.md for the full comparison.
    private static func readResidentSize(of task: task_t) throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(task, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MachMetricsError.taskInfoFailed(kernReturn: result, flavor: "TASK_VM_INFO")
        }
        return info.phys_footprint
    }

    /// Reads TASK_THREAD_TIMES_INFO and converts its seconds/microseconds
    /// time_value_t fields into plain Double seconds for user and system
    /// CPU time.
    private static func readThreadTimes(of task: task_t) throws -> (user: Double, system: Double) {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(task, task_flavor_t(TASK_THREAD_TIMES_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MachMetricsError.taskInfoFailed(kernReturn: result, flavor: "TASK_THREAD_TIMES_INFO")
        }

        let userSeconds = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let systemSeconds = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return (userSeconds, systemSeconds)
    }
}
