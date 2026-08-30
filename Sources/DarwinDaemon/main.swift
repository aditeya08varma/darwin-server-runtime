// Entry point for darwin-runtimed, the background daemon executable.
// Starts the Unix domain socket server and then keeps the process alive so
// Network.framework's callback-driven listener has a chance to actually
// run.
import Foundation
import RuntimeCore
import Telemetry
import os.log

private let startupLogger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "startup")

startupLogger.info("darwin-runtimed starting")
startupLogger.info("CSystemBridge linked correctly: \(Telemetry.bridgeIsLinked())")

let daemonState = DaemonState()
let server = try SocketServer(path: RuntimeSocket.path, state: daemonState)
server.start()
startupLogger.info("listening on \(RuntimeSocket.path, privacy: .public)")

// Network.framework delivers connection and data events on a dispatch
// queue in the background; without something keeping the main thread
// alive, this executable would start the listener and then immediately
// exit before it ever accepted a connection.
dispatchMain()
