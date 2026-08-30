// The daemon's Unix domain socket server. Accepts connections from
// darwin-run, reads newline-framed IPCMessage JSON off each one, decides
// what to do, and writes back a newline-framed IPCResponse. Built on
// Network.framework's NWListener/NWConnection rather than hand-rolled BSD
// sockets, since NWListener is Apple's modern, sanctioned API for this.
import Foundation
import Network
import RuntimeCore
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "socket-server")

/// Owns the listening socket and every active client connection.
final class SocketServer {
    private let listener: NWListener
    private let state: DaemonState

    /// Sets up a listener bound to the Unix domain socket at `path`.
    /// Removes any stale socket file left behind by a previous crashed run
    /// first, since a leftover file at that path would otherwise make
    /// binding fail with "address already in use."
    init(path: String, state: DaemonState) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: parameters)
        self.state = state
    }

    /// Starts accepting connections. Each new connection is handed off to
    /// its own receive loop so multiple clients (or repeated darwin-run
    /// invocations) can be in flight without blocking one another.
    func start() {
        listener.newConnectionHandler = { [state] connection in
            logger.info("accepted a new connection")
            Task {
                await SocketServer.handle(connection: connection, state: state)
            }
        }
        listener.stateUpdateHandler = { newState in
            logger.info("listener state changed to \(String(describing: newState), privacy: .public)")
        }
        listener.start(queue: .main)
    }

    /// Runs the receive loop for one connection: reads bytes as they
    /// arrive, hands them to a LineFrameBuffer to reassemble complete
    /// messages, decodes and responds to each one, and keeps going until
    /// the connection closes or fails.
    private static func handle(connection: NWConnection, state: DaemonState) async {
        connection.start(queue: .main)
        let frameBuffer = LineFrameBuffer()

        while true {
            let receiveResult = await receiveOnce(connection: connection)
            switch receiveResult {
            case .data(let data):
                let frames = await frameBuffer.append(data)
                for frame in frames {
                    await respond(to: frame, on: connection, state: state)
                }
            case .finished:
                logger.info("connection closed by peer")
                connection.cancel()
                return
            case .failed(let error):
                logger.error("connection failed: \(error.localizedDescription, privacy: .public)")
                connection.cancel()
                return
            }
        }
    }

    /// The three things a single receive attempt on a connection can
    /// resolve to: new bytes arrived, the peer closed the connection
    /// cleanly, or something went wrong.
    private enum ReceiveResult {
        case data(Data)
        case finished
        case failed(Error)
    }

    /// Wraps NWConnection's completion-handler-based receive call in
    /// Swift's async/await, so the receive loop above can be written as a
    /// plain while-loop instead of a chain of nested closures.
    private static func receiveOnce(connection: NWConnection) async -> ReceiveResult {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(returning: .failed(error))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: .data(data))
                } else if isComplete {
                    continuation.resume(returning: .finished)
                } else {
                    continuation.resume(returning: .data(Data()))
                }
            }
        }
    }

    /// Decodes one complete frame as an IPCMessage, decides how to
    /// respond, and writes the framed IPCResponse back to the connection.
    /// Every message kind is fully real as of Stage 3: .exec, .stop, and
    /// .status all drive genuine process lifecycle through
    /// ProcessSupervisor and DaemonState.
    private static func respond(to frame: Data, on connection: NWConnection, state: DaemonState) async {
        let response: IPCResponse
        do {
            let message = try JSONDecoder().decode(IPCMessage.self, from: frame)
            switch message {
            case .ping:
                response = .pong
            case .pull(let config):
                response = BundlePuller.pull(config)
            case .exec(let config):
                response = await ProcessSupervisor.start(config, state: state)
            case .stop(let jobID):
                response = await ProcessSupervisor.stop(jobID: jobID, state: state)
            case .status(let jobID):
                if let jobState = await state.state(ofJob: jobID) {
                    let exitCode = await state.exitCode(ofJob: jobID)
                    response = .jobStatus(jobID: jobID, state: jobState, exitCode: exitCode)
                } else {
                    response = .error(message: "no such job: \(jobID)")
                }
            }
        } catch {
            response = .error(message: "could not decode request: \(error.localizedDescription)")
        }

        guard let responseData = try? IPCFraming.frame(response) else {
            logger.error("failed to encode response")
            return
        }

        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error {
                logger.error("failed to send response: \(error.localizedDescription, privacy: .public)")
            }
        })
    }
}
