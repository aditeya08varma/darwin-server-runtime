// Shared socket configuration and message framing, used identically by
// both the daemon (server side) and the CLI (client side) so there is only
// one place that defines "where the socket lives" and "how one message is
// told apart from the next."
import Foundation

/// Where the daemon's Unix domain socket lives on disk.
/// Both the daemon (which binds and listens here) and the CLI (which
/// connects here) import this same constant, so the path can never drift
/// out of sync between the two sides.
public enum RuntimeSocket {
    /// The filesystem path of the Unix domain socket.
    /// Lives under /tmp for local development; a production LaunchDaemon
    /// setup would move this under /var/run instead, as noted in the README.
    public static let path = "/tmp/darwin-runtime.sock"
}

/// Turns a Codable value into one newline-terminated frame of bytes.
/// A Unix domain socket only knows how to move a stream of bytes; it has
/// no concept of "one message." Appending a newline after each compact
/// JSON encoding is what lets the receiving side know where one message
/// ends and the next begins, since JSON itself never contains a raw
/// newline unless something has gone wrong.
public enum IPCFraming {
    /// Encodes a value as compact JSON and appends a trailing newline byte.
    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}

/// Accumulates raw bytes arriving from a socket and hands back complete,
/// newline-delimited frames as they become available. This is an actor
/// because bytes can arrive in arbitrarily small or large chunks from an
/// asynchronous network callback, and appending to the same buffer from
/// overlapping callbacks needs to happen one at a time, safely.
public actor LineFrameBuffer {
    private var buffer = Data()

    public init() {}

    /// Adds newly-received bytes to the buffer and returns every complete
    /// frame (the bytes before each newline) that can now be extracted.
    /// Any leftover partial frame stays in the buffer, waiting for the
    /// rest of it to arrive in a future call.
    public func append(_ newBytes: Data) -> [Data] {
        buffer.append(newBytes)
        var frames: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[buffer.startIndex..<newlineIndex]
            frames.append(Data(frame))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return frames
    }
}
