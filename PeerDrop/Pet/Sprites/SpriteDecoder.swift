import Foundation
import ImageIO
import ZIPFoundation

enum SpriteDecoderError: Error {
    case zipOpenFailed(underlying: Error)
    case extractionFailed(direction: SpriteDirection, underlying: Error)
    case imageDecodeFailed(direction: SpriteDirection)
}

/// Decodes a species×stage zip into one CGImage per direction.
///
/// Each PixelLab zip contains `rotations/<direction-slug>.png` for the 8
/// SpriteDirection cases. Missing entries are silently skipped so a partial
/// asset (e.g. mid-generation gap) renders the directions it has rather than
/// failing the whole zip. Decode failures on present entries throw — those
/// indicate corruption, not incompleteness.
enum SpriteDecoder {

    static func decode(zipURL: URL) throws -> [SpriteDirection: CGImage] {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw SpriteDecoderError.zipOpenFailed(underlying: error)
        }

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
}
