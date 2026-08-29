// The CLI's side of talking to darwin-runtimed. Unlike the daemon, which
// stays running and handles many connections over its lifetime, the CLI
// makes one short-lived connection per invocation: connect, send exactly
// one request, wait for exactly one response, then disconnect and exit.
import Foundation
import Network
import RuntimeCore

/// Errors specific to a single request/response exchange with the daemon.
enum SocketClientError: Error, CustomStringConvertible {
    case connectionCancelledBeforeReady
    case connectionClosedBeforeResponse

    var description: String {
        switch self {
        case .connectionCancelledBeforeReady:
            return "connection to the daemon was cancelled before it became ready"
        case .connectionClosedBeforeResponse:
            return "the daemon closed the connection before sending a response"
        }
    }
}

/// A one-shot client for sending a single IPCMessage to the daemon and
/// getting back its IPCResponse. Every darwin-run subcommand that talks to
/// darwin-runtimed goes through this one function.
enum SocketClient {
    /// Connects to the daemon's Unix domain socket, sends `message`, and
    /// returns the first response that comes back. Throws if the daemon
    /// isn't running at all (connection fails to become ready) or the
    /// connection is lost before a full response arrives.
    static func send(_ message: IPCMessage) async throws -> IPCResponse {
        let connection = NWConnection(to: .unix(path: RuntimeSocket.path), using: .tcp)
        connection.start(queue: .main)

        try await waitUntilReady(connection)

        let requestData = try IPCFraming.frame(message)
        try await sendData(requestData, on: connection)

        let responseFrame = try await receiveOneFrame(on: connection)
        connection.cancel()

        return try JSONDecoder().decode(IPCResponse.self, from: responseFrame)
    }

    /// Suspends until the connection is ready to send and receive data, or
    /// throws as soon as it fails or is cancelled first. Clears the state
    /// handler right before resuming so a later state change (like the
    /// .cancelled we trigger ourselves after getting a response) can never
    /// resume the same continuation a second time, which would crash.
    private static func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    // For a fixed local path like a Unix domain socket,
                    // .waiting means "no listener there right now" - most
                    // often because the daemon isn't running. Network.framework's
                    // default behavior is to keep waiting indefinitely in
                    // case the path becomes reachable later, which is right
                    // for a long-lived client but wrong for a one-shot CLI
                    // invocation, which should fail immediately instead of
                    // hanging forever with no feedback.
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: SocketClientError.connectionCancelledBeforeReady)
                default:
                    break
                }
            }
        }
    }

    /// Sends one chunk of bytes and suspends until the send has either
    /// completed or failed.
    private static func sendData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads chunks off the connection, feeding each one into a
    /// LineFrameBuffer, until a complete newline-terminated frame is
    /// available, then returns just that one frame. Reusing
    /// LineFrameBuffer here is what makes this correct even if the
    /// daemon's response happens to arrive split across multiple reads.
    private static func receiveOneFrame(on connection: NWConnection) async throws -> Data {
        let buffer = LineFrameBuffer()
        while true {
            let chunk = try await receiveChunk(on: connection)
            let frames = await buffer.append(chunk)
            if let firstFrame = frames.first {
                return firstFrame
            }
        }
    }

    /// Wraps NWConnection's completion-handler-based receive call in
    /// async/await, the same bridging pattern SocketServer uses on the
    /// daemon side of this same socket.
    private static func receiveChunk(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: SocketClientError.connectionClosedBeforeResponse)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
