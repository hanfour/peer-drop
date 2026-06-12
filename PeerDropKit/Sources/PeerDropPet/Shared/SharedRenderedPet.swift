import Foundation
import CoreGraphics
import ImageIO
import OSLog
import UniformTypeIdentifiers

private let bridgeLogger = Logger(subsystem: "com.hanfour.peerdrop", category: "SharedRenderedPet")

/// App Group bridge for the rendered pet CGImage. Mirrors SharedPetState's
/// NSFileCoordinator pattern but carries binary PNG bytes instead of JSON.
///
/// Architecture: main app's PetEngine produces a CGImage via PetRendererV3
/// (PNG sprite + mood overlay). Rather than have the widget re-run that
/// pipeline — which would mean duplicating ZIPFoundation, the 3.6 MB asset
/// bundle, and the SpriteService actor into the extension — the main app
/// writes the rendered image as a PNG file in the App Group container. The
/// widget reads it back via the symmetric load API.
///
/// Single file (`pet-rendered.png`), last-write-wins. Direction / mood
/// changes are stale in the widget until the main app re-renders. Widgets
/// refresh on schedule (15-min timeline + system events) so this matches
/// existing UX expectations.
public final class SharedRenderedPet {
    public static let appGroupID = "group.com.hanfour.peerdrop"
    private static let filename = "pet-rendered.png"

    private let containerURL: URL
    /// Write-failure log dedup flag (see write(_:)). Reset on success.
    private var didLogWriteFailure = false

    public init(suiteName: String? = appGroupID) {
        if let suite = suiteName,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite) {
            self.containerURL = url
            // On macOS the group container directory is NOT created
            // automatically (unlike iOS) — every write then fails with
            // "folder doesn't exist", which the render loop repeated at
            // ~6 Hz (audit round 15). Creating it here makes the bridge
            // work on the Mac and is a no-op where it already exists.
            try? FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        } else {
            // Fallback for tests / non-app-group context: per-process temp dir
            // so concurrent test cases don't clobber each other.
            self.containerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SharedRenderedPet-\(ProcessInfo.processInfo.globallyUniqueString)",
                                        isDirectory: true)
            try? FileManager.default.createDirectory(
                at: containerURL, withIntermediateDirectories: true)
        }
    }

    public var fileURL: URL { containerURL.appendingPathComponent(Self.filename) }

    /// Writes the CGImage as PNG bytes to the App Group container.
    /// Coordinated so the widget never reads a half-written file.
    public func write(_ image: CGImage) {
        guard let data = Self.pngData(from: image) else {
            // Release-safe diagnostic — assertionFailure alone is debug-only,
            // so a prod encode failure would silently freeze the widget at
            // its previous frame with no signal in Console.
            bridgeLogger.error("PNG encode failed for \(image.width)×\(image.height) CGImage; bridge write skipped")
            assertionFailure("Failed to encode CGImage as PNG")
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL, options: .forReplacing,
            error: &coordinatorError
        ) { url in
            // .atomic writes to a temp location and renames into place — a
            // concurrent reader either sees the previous file or the new
            // one, never a partial write.
            do {
                try data.write(to: url, options: .atomic)
                self.didLogWriteFailure = false
            } catch {
                // Dedup: the render loop calls write() at animation rate, so
                // a persistent failure (e.g. missing entitlement in dev
                // builds) would otherwise flood the log at ~6 Hz.
                if !self.didLogWriteFailure {
                    self.didLogWriteFailure = true
                    bridgeLogger.error("PNG write failed: \(error.localizedDescription, privacy: .public) (further occurrences suppressed)")
                }
            }
        }
        if let coordinatorError {
            bridgeLogger.error("NSFileCoordinator write coordination failed: \(coordinatorError.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the most recently written CGImage. Returns nil when the file
    /// doesn't exist yet (first install / before main app rendered) or when
    /// PNG decoding fails. Callers should fall back to a placeholder UI.
    public func read() -> CGImage? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: CGImage?
        coordinator.coordinate(
            readingItemAt: fileURL, options: [],
            error: &coordinatorError
        ) { url in
            guard let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            result = cg
        }
        if let coordinatorError {
            bridgeLogger.error("NSFileCoordinator read coordination failed: \(coordinatorError.localizedDescription, privacy: .public)")
        }
        return result
    }

    public func clear() {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL, options: .forDeleting,
            error: &coordinatorError
        ) { url in
            try? FileManager.default.removeItem(at: url)
        }
        if let coordinatorError {
            bridgeLogger.error("NSFileCoordinator clear coordination failed: \(coordinatorError.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - PNG encoding helper

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
