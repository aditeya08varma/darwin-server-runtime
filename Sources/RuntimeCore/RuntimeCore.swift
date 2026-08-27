// RuntimeCore holds types that both the daemon and the CLI need to agree on,
// starting with the IPC message protocol in Stage 1. For now it only holds a
// placeholder so the module has something to compile and other targets have
// something real to depend on.
import Foundation

/// A placeholder namespace for the RuntimeCore module.
/// Its only job right now is to prove the module builds; the real IPC
/// message types (IPCMessage, ExecConfig, and friends) are added in Stage 1.
public enum RuntimeCore {
    /// Returns a fixed version string for this module.
    /// Used as a simple smoke test that RuntimeCore compiled and can be
    /// imported by other targets, before there is any real functionality here.
    public static func version() -> String {
        return "0.0.1-stage0"
    }
}
