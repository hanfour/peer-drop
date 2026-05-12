import Foundation
import ImageIO
import ZIPFoundation

enum SpriteDecoderError: Error {
    case zipOpenFailed(underlying: Error)
    case extractionFailed(direction: SpriteDirection, underlying: Error)
    case imageDecodeFailed(direction: SpriteDirection)
    case atlasImageMissing
    case atlasImageDecodeFailed
}

/// Decodes a species×stage zip into one CGImage per direction.
///
/// Each PixelLab zip contains `rotations/<direction-slug>.png` for the 8
/// SpriteDirection cases. Missing entries are silently skipped so a partial
/// asset (e.g. mid-generation gap) renders the directions it has rather than
/// failing the whole zip. Decode failures on present entries throw — those
/// indicate corruption, not incompleteness.
///
/// As of v5.1+, zips may also carry an atlas (single `atlas.png` + `atlas.json`
/// — see `SpriteAtlas`). When present, `decode` slices each direction from the
/// atlas via zero-copy `CGImage.cropping(to:)` instead of extracting per-frame
/// PNGs. Atlas zips that drop their per-frame PNGs (via `build_atlas.py
/// --strip-frames`) shrink the bundle by ~40% per asset.
enum SpriteDecoder {

    static func decode(zipURL: URL) throws -> [SpriteDirection: CGImage] {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw SpriteDecoderError.zipOpenFailed(underlying: error)
        }

        if let atlas = try SpriteAtlas.parse(archive: archive) {
            return try decodeFromAtlas(archive: archive, atlas: atlas)
        }
        return try decodeFromPerFramePNGs(archive: archive)
    }

    private static func decodeFromAtlas(
        archive: Archive,
        atlas: SpriteAtlas
    ) throws -> [SpriteDirection: CGImage] {
        let atlasImage = try loadAtlasImage(archive: archive)

        var result: [SpriteDirection: CGImage] = [:]
        for direction in SpriteDirection.allCases {
            let path = "rotations/\(direction.rawValue).png"
            guard let rect = atlas.rect(for: path) else {
                // Atlas can legitimately omit a direction (e.g. partial PixelLab
                // export) — mirror the per-frame path's silent-skip contract.
                continue
            }
            guard let cg = atlasImage.cropping(to: rect.cgRect) else {
                throw SpriteDecoderError.imageDecodeFailed(direction: direction)
            }
            result[direction] = cg
        }
        return result
    }

    private static func decodeFromPerFramePNGs(
        archive: Archive
    ) throws -> [SpriteDirection: CGImage] {
        var result: [SpriteDirection: CGImage] = [:]
        for direction in SpriteDirection.allCases {
            let path = "rotations/\(direction.rawValue).png"
            guard let entry = archive[path] else { continue }

            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
            } catch {
                throw SpriteDecoderError.extractionFailed(direction: direction, underlying: error)
            }

            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw SpriteDecoderError.imageDecodeFailed(direction: direction)
            }
            result[direction] = cg
        }
        return result
    }

    /// Extract and decode `atlas.png` from an open archive. Shared between
    /// `SpriteDecoder` (rotations) and `SpriteService` (animations) via the
    /// `loadAtlasImage(zipURL:)` overload.
    static func loadAtlasImage(archive: Archive) throws -> CGImage {
        guard let entry = archive[SpriteAtlas.imageEntry] else {
            throw SpriteDecoderError.atlasImageMissing
        }
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
        } catch {
            throw SpriteDecoderError.atlasImageDecodeFailed
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SpriteDecoderError.atlasImageDecodeFailed
        }
        return cg
    }

    /// Overload used when the caller only knows the zip URL (`SpriteService`'s
    /// animation path). Re-opens the archive — cheap because ZIPFoundation
    /// just maps the central directory.
    static func loadAtlasImage(zipURL: URL) throws -> CGImage {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw SpriteDecoderError.zipOpenFailed(underlying: error)
        }
        return try loadAtlasImage(archive: archive)
    }
}
