// A test-only helper for building tarball fixtures using libarchive's own
// write API directly, rather than shelling out to the command-line `tar`
// tool. This matters specifically for the path-traversal test: a normal
// `tar` invocation refuses to create an entry named "../../etc/passwd" in
// the first place, so it cannot be used to build a fixture for testing
// that ImageArchive correctly rejects one. Writing the archive by hand
// through libarchive gives full control over exactly what path gets
// stored in the entry, safe or not.
import Foundation
import CArchive

enum TarballFixtureError: Error {
    case writeFailed(String)
}

enum TarballFixture {
    struct Entry {
        let path: String
        let content: String
    }

    /// libarchive's file-type macros don't import into Swift (see the
    /// same note in ImageArchive.swift); this is the regular-file value
    /// from archive_entry.h, needed here to build valid entries.
    /// archive_entry_set_filetype expects UInt32, not the mode_t (UInt16)
    /// the header's own typedefs use - the compiler caught the mismatch.
    private static let regularFileType: UInt32 = 0o100000

    /// Writes a tar.gz archive containing exactly the given entries, in
    /// order, to `url`. Each entry is written as a regular file with
    /// fixed, uninteresting permissions, since none of these tests care
    /// about permission bits, only about paths and content.
    static func write(entries: [Entry], to url: URL) throws {
        guard let archive = archive_write_new() else {
            throw TarballFixtureError.writeFailed("archive_write_new returned no archive")
        }
        defer { archive_write_free(archive) }

        archive_write_set_format_pax_restricted(archive)
        archive_write_add_filter_gzip(archive)

        guard archive_write_open_filename(archive, url.path) == ARCHIVE_OK else {
            throw TarballFixtureError.writeFailed(String(cString: archive_error_string(archive)))
        }

        for entry in entries {
            guard let archiveEntry = archive_entry_new() else {
                throw TarballFixtureError.writeFailed("archive_entry_new returned no entry")
            }
            defer { archive_entry_free(archiveEntry) }

            let contentBytes = Array(entry.content.utf8)
            archive_entry_set_pathname(archiveEntry, entry.path)
            archive_entry_set_filetype(archiveEntry, regularFileType)
            archive_entry_set_size(archiveEntry, Int64(contentBytes.count))
            archive_entry_set_perm(archiveEntry, 0o644)

            guard archive_write_header(archive, archiveEntry) == ARCHIVE_OK else {
                throw TarballFixtureError.writeFailed(String(cString: archive_error_string(archive)))
            }

            let bytesWritten = contentBytes.withUnsafeBytes { rawBuffer in
                archive_write_data(archive, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard bytesWritten == contentBytes.count else {
                throw TarballFixtureError.writeFailed("short write for entry \(entry.path)")
            }
        }

        guard archive_write_close(archive) == ARCHIVE_OK else {
            throw TarballFixtureError.writeFailed(String(cString: archive_error_string(archive)))
        }
    }
}
