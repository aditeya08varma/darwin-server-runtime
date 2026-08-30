// Unpacks a tarball (.tar, .tar.gz, and anything else libarchive can read)
// into a destination directory, using libarchive's own read API through
// CArchive. The one line in this file that actually matters for security
// is the path safety check in validateSafePath: everything else here is
// just plumbing to drive libarchive correctly.
import Foundation
import CArchive

/// Errors that can happen while unpacking a tarball.
public enum ImageArchiveError: Error, CustomStringConvertible {
    case cannotOpenArchive(String)
    case corruptEntry(String)
    case unsafeEntryPath(String)

    public var description: String {
        switch self {
        case .cannotOpenArchive(let message):
            return "could not open archive: \(message)"
        case .corruptEntry(let message):
            return "corrupt archive entry: \(message)"
        case .unsafeEntryPath(let path):
            return "refusing to extract entry with unsafe path: \(path)"
        }
    }
}

/// libarchive defines its file-type constants (AE_IFREG, AE_IFDIR, and so
/// on) in archive_entry.h as C cast expressions, like
/// `#define AE_IFREG ((__LA_MODE_T)0100000)`. Swift's Clang importer only
/// pulls in plain literal macros, not ones containing a C cast, so these
/// two never became usable Swift symbols even though the header declares
/// them. These are the exact same fixed octal values from that header,
/// defined here by hand so archive_entry_filetype()'s result can still be
/// compared against them.
private let entryTypeRegularFile: Int32 = 0o100000
private let entryTypeDirectory: Int32 = 0o040000

/// Unpacks tarballs into a destination directory using libarchive.
public enum ImageArchive {
    /// Reads every entry out of `tarball` and writes it into `rootfs`.
    /// Only regular files and directories are extracted; every other entry
    /// type (symlinks, device nodes, and so on) is silently skipped rather
    /// than extracted, since none of this project's use cases need them
    /// and skipping is always safe (a skipped entry never gets written
    /// anywhere, so it can never be the thing that escapes the rootfs).
    /// Before any entry is written, its path is checked by
    /// validateSafePath: this is the line that stops a malicious tarball
    /// from writing outside of `rootfs` using a path like "../../etc/passwd".
    public static func unpack(tarball: URL, into rootfs: URL) throws {
        guard let archive = archive_read_new() else {
            throw ImageArchiveError.cannotOpenArchive("archive_read_new returned no archive")
        }
        defer { archive_read_free(archive) }

        archive_read_support_format_all(archive)
        archive_read_support_filter_all(archive)

        guard archive_read_open_filename(archive, tarball.path, 65536) == ARCHIVE_OK else {
            throw ImageArchiveError.cannotOpenArchive(lastErrorMessage(archive))
        }

        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        while true {
            var entryPointer: OpaquePointer?
            let headerResult = archive_read_next_header(archive, &entryPointer)

            if headerResult == ARCHIVE_EOF {
                break
            }
            guard headerResult == ARCHIVE_OK, let entry = entryPointer else {
                throw ImageArchiveError.corruptEntry(lastErrorMessage(archive))
            }
            guard let rawPathPointer = archive_entry_pathname(entry) else {
                throw ImageArchiveError.corruptEntry("entry is missing a pathname")
            }

            let rawPath = String(cString: rawPathPointer)
            try validateSafePath(rawPath)

            let destination = rootfs.appendingPathComponent(rawPath)
            let fileType = archive_entry_filetype(entry)

            switch Int32(fileType) {
            case entryTypeDirectory:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            case entryTypeRegularFile:
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try extractRegularFile(from: archive, to: destination)
            default:
                continue
            }
        }
    }

    /// Rejects any entry path that could write outside of the destination
    /// directory: an empty path, an absolute path (starting with "/"), or
    /// a path containing a ".." component. Checking by path component
    /// (splitting on "/") rather than checking whether the string contains
    /// ".." anywhere is what makes this correct: it rejects the real
    /// attack ("../../etc/passwd") without also rejecting a legitimately
    /// named file like "foo..bar.txt", which merely contains the two
    /// characters ".." without them being an actual path component.
    private static func validateSafePath(_ path: String) throws {
        if path.isEmpty || path.hasPrefix("/") {
            throw ImageArchiveError.unsafeEntryPath(path)
        }
        if path.split(separator: "/").contains("..") {
            throw ImageArchiveError.unsafeEntryPath(path)
        }
    }

    /// Copies one regular file entry's contents out of the archive and
    /// writes them to `destination`, reading in fixed-size chunks rather
    /// than all at once, since archive entries are not guaranteed to fit
    /// comfortably in memory.
    private static func extractRegularFile(from archive: OpaquePointer, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ImageArchiveError.corruptEntry("could not create destination file: \(destination.path)")
        }
        guard let handle = FileHandle(forWritingAtPath: destination.path) else {
            throw ImageArchiveError.corruptEntry("could not open destination file for writing: \(destination.path)")
        }
        defer { handle.closeFile() }

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                archive_read_data(archive, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                throw ImageArchiveError.corruptEntry(lastErrorMessage(archive))
            }
            if bytesRead == 0 {
                break
            }
            handle.write(Data(buffer[0..<bytesRead]))
        }
    }

    /// Reads libarchive's own last-error message off the archive handle,
    /// falling back to a generic message if libarchive did not set one.
    private static func lastErrorMessage(_ archive: OpaquePointer) -> String {
        guard let messagePointer = archive_error_string(archive) else {
            return "no further detail available from libarchive"
        }
        return String(cString: messagePointer)
    }
}
