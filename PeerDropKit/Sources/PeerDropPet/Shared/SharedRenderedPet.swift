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

    /// Default App Group suite. nil on macOS: the bridge exists only for the
    /// iOS widget + Live Activity, neither of which exists on the Mac, so
    /// touching the App Group container there is pointless AND triggers a
    /// "wants to access other apps' data" privacy prompt on every launch
    /// (audit round 24). nil routes to the temp-dir fallback — no prompt.
    public static var defaultSuiteName: String? {
        #if os(macOS)
        return nil
        #else
        return appGroupID
        #endif
    }

    private let containerURL: URL
    /// Write-failure log dedup flag (see write(_:)). Reset on success.
    private var didLogWriteFailure = false

    /// - Parameter minWriteInterval: throttle window for `write(_:)`.
    ///   Tests pass 0 so consecutive writes aren't dropped.
    public init(suiteName: String? = defaultSuiteName, minWriteInterval: TimeInterval = 1.0) {
        self.minWriteInterval = minWriteInterval
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

    /// Serial queue for encode + coordinated I/O. write(_:) is called from
    /// the render loop on the main actor at animation rate (~6–12 Hz);
    /// doing the PNG encode and NSFileCoordinator write synchronously there
    /// saturated the main thread and starved ConnectionManager — incoming
    /// connections were never serviced (audit round 16 live finding, after
    /// the container-directory fix made the writes actually happen).
    private let writeQueue = DispatchQueue(label: "com.peerdrop.sharedrenderedpet", qos: .utility)

    /// Last accepted write (checked on the caller's thread — write(_:) is
    /// only invoked from the main actor). The widget consumes this file on
    /// a 15-minute timeline, so once per second is already generous.
    private var lastWriteAt = Date.distantPast
    private let minWriteInterval: TimeInterval

    /// Writes the CGImage as PNG bytes to the App Group container.
    /// Coordinated so the widget never reads a half-written file.
    /// Throttled and asynchronous — see `writeQueue`.
    public func write(_ image: CGImage) {
        let now = Date()
        guard now.timeIntervalSince(lastWriteAt) >= minWriteInterval else { return }
        lastWriteAt = now

        writeQueue.async { [self] in
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
                    didLogWriteFailure = false
                } catch {
                    // Dedup: a persistent failure (e.g. missing entitlement in
                    // dev builds) would otherwise flood the log once per second.
                    if !didLogWriteFailure {
                        didLogWriteFailure = true
                        bridgeLogger.error("PNG write failed: \(error.localizedDescription, privacy: .public) (further occurrences suppressed)")
                    }
                }
            }
            if let coordinatorError {
                bridgeLogger.error("NSFileCoordinator write coordination failed: \(coordinatorError.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Blocks until all writes enqueued so far have completed. Test seam —
    /// write(_:) is asynchronous, so a write-then-read sequence needs this
    /// barrier to be deterministic.
    public func flushPendingWrites() {
        writeQueue.sync {}
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
