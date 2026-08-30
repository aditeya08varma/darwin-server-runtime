// Applies ExecConfig's resource limit requests to a Process that an
// isolation engine has already configured with its real executableURL
// and arguments. Shared by every ProcessIsolationEngine backend, since
// the technique is the same regardless of which backend is spawning the
// process.
import Foundation
import RuntimeCore
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "resource-limits")

enum ResourceLimits {
    /// Rewrites `process`'s executableURL/arguments to route the real
    /// binary through a small /bin/sh wrapper that applies `ulimit -t`
    /// (CPU seconds) before exec-ing the real binary in the shell's
    /// place. `exec` replaces the shell's own process image entirely, so
    /// the resulting process still runs as the target binary, with the
    /// target binary's own behavior - the shell is a brief setup step,
    /// not a permanent wrapper process sitting in between.
    ///
    /// This exists because Foundation's Process offers no hook to run
    /// code between fork and exec, which is exactly when setrlimit needs
    /// to happen for it to affect the child rather than the daemon
    /// itself. It's the same "shell out rather than fight Foundation's
    /// launch model" reasoning already used for sandbox-exec.
    ///
    /// Memory limits (config.memoryLimitMB) are accepted but not
    /// enforced here, and that omission was not a convenience shortcut:
    /// setting RLIMIT_AS, RLIMIT_RSS, or RLIMIT_DATA on this version of
    /// macOS was tested three independent ways - bash's `ulimit -v`,
    /// bash's `ulimit -m`, and a raw setrlimit() syscall via Python's
    /// resource module - and all three refuse to lower these limits at
    /// all. `ulimit -t` (CPU), by contrast, was confirmed to genuinely
    /// work and be kernel-enforced: a real spin-loop process was killed
    /// with SIGXCPU once its CPU time ran out. Real per-process memory
    /// containment on macOS would need active monitoring through Mach's
    /// task_info, killing the process if it exceeds the limit - that's
    /// Stage 4 territory, not something to build ahead of schedule here.
    /// If a memory limit is requested, this logs a warning that it
    /// cannot be enforced rather than silently pretending to apply it,
    /// the same "observable degradation, not silent" principle used for
    /// the Seatbelt/POSIX isolation fallback.
    static func apply(_ config: ExecConfig, to process: Process) {
        if config.memoryLimitMB != nil {
            logger.warning(
                "memory limit requested but cannot be enforced on this platform (macOS refuses to lower memory-related rlimits); running without a memory cap"
            )
        }

        guard let cpuLimit = config.cpuLimit else {
            return
        }
        guard let currentExecutable = process.executableURL else {
            return
        }

        let escapedExecutable = shellEscape(currentExecutable.path)
        let escapedArguments = (process.arguments ?? []).map(shellEscape).joined(separator: " ")
        let command = "ulimit -t \(cpuLimit); exec \(escapedExecutable) \(escapedArguments)"

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
    }

    /// Wraps a value in single quotes for safe inclusion in a shell
    /// command string, escaping any single quote already in the value.
    /// Needed because the binary path and arguments are being spliced
    /// into a real shell command line, not passed as a pre-split argv
    /// array the way Process normally handles arguments.
    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
