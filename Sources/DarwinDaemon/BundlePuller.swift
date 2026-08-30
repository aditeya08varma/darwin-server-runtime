// Orchestrates one darwin-run pull request: verify the tarball against
// its signed manifest, then unpack it into a freshly generated bundle
// directory. This is the one place Stage 2's two independent pieces,
// TrustVerifier and ImageArchive, actually get used together.
import Foundation
import RuntimeCore
import ImageStore
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "bundle-puller")

enum BundlePuller {
    /// Runs verification and unpacking for one pull request. Every
    /// failure is caught here and turned into an honest IPCResponse.error
    /// rather than being allowed to throw across the socket handling
    /// boundary: the daemon should never crash just because a client
    /// handed it a bad tarball, a missing file, or an invalid signature.
    static func pull(_ config: PullConfig) -> IPCResponse {
        let tarballURL = URL(fileURLWithPath: config.tarballPath)
        let manifestURL = URL(fileURLWithPath: config.manifestPath)
        let verifyKeyURL = URL(fileURLWithPath: config.verifyKeyPath)

        do {
            let publicKey = try TrustVerifier.loadPublicKey(from: verifyKeyURL)
            try TrustVerifier.verify(tarball: tarballURL, manifest: manifestURL, publicKey: publicKey)
        } catch {
            logger.error("pull rejected: verification failed: \(String(describing: error), privacy: .public)")
            return .error(message: "verification failed: \(error)")
        }

        let bundleID = UUID().uuidString
        let rootfs = rootfsDirectory(forBundleID: bundleID)

        do {
            try ImageArchive.unpack(tarball: tarballURL, into: rootfs)
        } catch {
            logger.error("pull failed: unpack failed: \(String(describing: error), privacy: .public)")
            return .error(message: "unpack failed: \(error)")
        }

        logger.info("pulled bundle \(bundleID, privacy: .public) into \(rootfs.path, privacy: .public)")
        return .pulled(bundleID: bundleID, rootfsPath: rootfs.path)
    }

    /// Computes where a bundle with the given ID should live on disk:
    /// under this user's Application Support directory, one folder per
    /// bundle ID. Deliberately not stored anywhere in memory - the ID to
    /// path mapping is fully deterministic from the ID alone, so there is
    /// nothing to remember yet. Stage 3's .exec will decide how it wants
    /// to look bundles up by ID once it actually needs to.
    private static func rootfsDirectory(forBundleID bundleID: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("darwin-runtime", isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("rootfs", isDirectory: true)
    }
}
