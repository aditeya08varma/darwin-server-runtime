// Entry point for darwin-runtimed, the background daemon executable.
// For now this just prints a startup message and exits. The real Unix
// domain socket server and job supervision are built out across Stages 1
// through 4; this file exists so the executable target has something to run
// and the launchd plist (added later in Stage 1) has a real binary to point at.
import Foundation
import RuntimeCore
import Telemetry

print("darwin-runtimed starting (stage 0 stub)")
print("RuntimeCore version: \(RuntimeCore.version())")
print("CSystemBridge linked correctly: \(Telemetry.bridgeIsLinked())")
