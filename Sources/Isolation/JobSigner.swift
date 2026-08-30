// Ad-hoc signs a job's binary with the get-task-allow entitlement, right
// before it's spawned, so Stage 4's Mach telemetry can later sample its
// real memory and CPU usage via task_for_pid. Called from
// BinaryPathResolver, the one place every ProcessIsolationEngine backend
// resolves the real target binary path before any wrapping (sandbox-exec
// argument wrapping, or the ulimit /bin/sh wrapping from ResourceLimits)
// happens - signing has to happen on that raw path, not on whatever
// process.executableURL ends up being after wrapping, or it would sign
// the wrong file (sandbox-exec or /bin/sh instead of the actual job).
//
// See Configurations/task-inspectable.entitlements and DEBUGGING_LOG.md
// #12 for why this entitlement goes on the job's own binary rather than
// on darwin-runtimed itself - that was the opposite of the original plan.
import Foundation
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "job-signer")

public enum JobSigner {
    /// The same entitlement XML as Configurations/task-inspectable.entitlements,
    /// embedded directly rather than read from that file at runtime - the
    /// same "write the text out to a temp file when needed" pattern
    /// SeatbeltIsolationEngine already uses for its SBPL profiles, kept
    /// self-contained rather than depending on Swift Package resource
    /// bundling for an executable target.
    private static let entitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.get-task-allow</key>
        <true/>
    </dict>
    </plist>
    """

    /// Ad-hoc signs `binaryURL` in place with the get-task-allow
    /// entitlement by shelling out to /usr/bin/codesign - the same
    /// "shell out to a real system tool" reasoning already used for
    /// sandbox-exec. This is deliberately best-effort: a signing failure
    /// is logged and swallowed, not thrown, because a job that cannot be
    /// made inspectable should still run - it will simply have no
    /// telemetry available for it, which is a smaller problem than
    /// refusing to execute an otherwise legitimate job over it.
    ///
    /// Known cost, not yet addressed: shelling out to codesign on every
    /// spawn adds real latency (tens of milliseconds), which cuts against
    /// this project's own cold-start goals. Making this conditional on
    /// whether a caller actually wants telemetry for a given job would
    /// be the natural next refinement, once real cold-start numbers are
    /// measured rather than assumed.
    ///
    /// A second, more fundamental limit: this only makes a genuinely
    /// compiled binary inspectable. For a job whose binaryPath is a
    /// script with a #! shebang line, the kernel actually executes the
    /// interpreter named on that line (e.g. /bin/sh) as the real Mach-O
    /// process image, not the script text - so the process that ends up
    /// running carries Apple's own signature on /bin/sh, not the ad-hoc
    /// signature just applied to the script file. Confirmed directly: an
    /// identical setup succeeds for a compiled binary and fails for a
    /// shell script. Re-signing a system interpreter like /bin/sh isn't
    /// something this project does. Telemetry sampling in Stage 4
    /// therefore only works for compiled binaries, not shebang scripts -
    /// a real scope boundary, not an oversight.
    public static func makeInspectable(_ binaryURL: URL) {
        let entitlementsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("darwin-runtime-entitlements-\(UUID().uuidString).plist")

        do {
            try entitlementsXML.write(to: entitlementsURL, atomically: true, encoding: .utf8)
        } catch {
            logger.warning(
                "could not write entitlements file, job will not be inspectable: \(String(describing: error), privacy: .public)"
            )
            return
        }
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-s", "-", "--entitlements", entitlementsURL.path, "-f", binaryURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.warning("codesign exited with status \(process.terminationStatus), job will not be inspectable")
            }
        } catch {
            logger.warning(
                "failed to run codesign, job will not be inspectable: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
