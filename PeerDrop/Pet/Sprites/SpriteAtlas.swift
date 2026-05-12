import Foundation
import CoreGraphics
import ZIPFoundation

/// Parsed companion of `atlas.json` — the rect map produced by
/// `Scripts/build_atlas.py`. Mirrors `SpriteMetadata` in role: pure
/// data, no I/O on `CGImage`, no PNG decoding. The atlas image itself
/// (atlas.png) is decoded by `SpriteService` and sliced via `cropping(to:)`.
///
/// Schema versioning: `atlasVersion` rolls forward only on breaking
/// changes. v1 is one rect per path; future revisions might add
/// rotation / trim / nine-slice metadata.
struct SpriteAtlas: Equatable {
    let atlasVersion: Int
    let frameSize: FrameSize
    let frames: [String: Rect]

    struct FrameSize: Equatable {
        let width: Int
        let height: Int
    }

    struct Rect: Equatable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        /// Bridge to CoreGraphics for `CGImage.cropping(to:)`. The atlas
        /// PNG is decoded with integer pixel dimensions so a CGRect built
        /// from int coords slices cleanly with no interpolation.
        var cgRect: CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
    }
}

enum SpriteAtlasError: Error {
    case zipOpenFailed(underlying: Error)
    case atlasJSONExtractionFailed(underlying: Error)
    case atlasJSONDecodeFailed(underlying: Error)
    case unsupportedAtlasVersion(Int)
}

extension SpriteAtlas {

    /// Entry name of the atlas manifest inside the zip. Matches the Python
    /// generator's `ATLAS_JSON_NAME`.
    static let manifestEntry = "atlas.json"

    /// Entry name of the atlas image inside the zip. Matches the Python
    /// generator's `ATLAS_PNG_NAME`.
    static let imageEntry = "atlas.png"

    /// Parse the atlas manifest from a zip, returning `nil` when the zip
    /// contains no `atlas.json` (this is the legacy per-frame layout —
    /// callers should fall back to that path).
    ///
    /// Throws when the atlas exists but can't be parsed; an unreadable
    /// atlas is a corrupt build, not "no atlas here."
    static func parse(zipURL: URL) throws -> SpriteAtlas? {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw SpriteAtlasError.zipOpenFailed(underlying: error)
        }
        return try parse(archive: archive)
    }

    /// Variant that reuses an already-open `Archive`, so `SpriteService`
    /// can probe for the atlas and (if found) also extract `atlas.png`
    /// without re-opening the zip file twice.
    static func parse(archive: Archive) throws -> SpriteAtlas? {
        guard let entry = archive[manifestEntry] else {
            return nil
        }

        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
        } catch {
            throw SpriteAtlasError.atlasJSONExtractionFailed(underlying: error)
        }

        let raw: RawAtlas
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            raw = try decoder.decode(RawAtlas.self, from: data)
        } catch {
            throw SpriteAtlasError.atlasJSONDecodeFailed(underlying: error)
        }

        guard raw.atlasVersion == 1 else {
            // v2+ atlases would carry extra fields we don't know how to
            // interpret. Refuse rather than silently misrender.
            throw SpriteAtlasError.unsupportedAtlasVersion(raw.atlasVersion)
        }

        return raw.toAtlas()
    }

    /// Returns the rect for a frame path (e.g. "rotations/south.png" or
    /// "animations/walk/east/frame_003.png"). Same path strings the v3.0
    /// `metadata.json` already uses — atlas builder preserves them as
    /// symbolic keys so callers don't need a path-rewriting layer.
    func rect(for path: String) -> Rect? {
        frames[path]
    }
}

private struct RawAtlas: Decodable {
    let atlasVersion: Int
    let frameSize: RawFrameSize
    let frames: [String: RawRect]

    struct RawFrameSize: Decodable {
        let width: Int
        let height: Int
    }

    struct RawRect: Decodable {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
    }

    func toAtlas() -> SpriteAtlas {
        SpriteAtlas(
            atlasVersion: atlasVersion,
            frameSize: SpriteAtlas.FrameSize(width: frameSize.width, height: frameSize.height),
            frames: frames.mapValues { SpriteAtlas.Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
        )
    }
}
