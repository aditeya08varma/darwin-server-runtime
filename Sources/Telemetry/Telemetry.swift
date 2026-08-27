// Telemetry will hold Mach kernel metrics sampling, the bounded ring buffer,
// and the OpenTelemetry exporter, built out in Stage 4. This file is a
// placeholder that also proves, from Stage 0 onward, that Swift code can
// call through CSystemBridge into C, which is the riskiest interop point in
// the whole project and worth verifying early.
import CSystemBridge

/// A placeholder namespace for the Telemetry module.
public enum Telemetry {
    /// Calls into the C bridge and checks that it returned the expected value.
    /// Used as an end-to-end smoke test that C interop (Swift calling a C
    /// function through the CSystemBridge target) works, before any real
    /// Mach kernel sampling logic is added in Stage 4.
    public static func bridgeIsLinked() -> Bool {
        return csystembridge_ping() == 1
    }
}
