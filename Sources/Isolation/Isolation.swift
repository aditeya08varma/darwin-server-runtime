// Isolation will hold the ProcessIsolationEngine protocol and its two
// backends (Seatbelt sandbox-exec and a POSIX fallback), built out in
// Stage 3. This file is a placeholder so the target compiles now.
import RuntimeCore

/// A placeholder namespace for the Isolation module.
public enum Isolation {
    /// Returns a fixed status string.
    /// Used as a smoke test that Isolation compiles, before the real
    /// ProcessIsolationEngine protocol and backends are added in Stage 3.
    public static func status() -> String {
        return "Isolation ready (stage 0 stub)"
    }
}
