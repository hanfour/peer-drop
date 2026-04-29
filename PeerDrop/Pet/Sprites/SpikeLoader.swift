// TODO(M3): delete this file once SpriteService supersedes it.
// Spike-only loader that proves the zip → PNG → CGImage pipeline. Production
// code should go through SpriteService (M3.5), not this.
import Foundation
import ImageIO
import ZIPFoundation

enum SpikeLoaderError: Error {
    case entryNotFound(String)
    case imageSourceCreationFailed
    case imageDecodeFailed
}

enum SpikeLoader {
    static func loadEast(zipURL: URL) throws -> CGImage {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = archive["rotations/east.png"] else {
            throw SpikeLoaderError.entryNotFound("rotations/east.png")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw SpikeLoaderError.imageSourceCreationFailed
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SpikeLoaderError.imageDecodeFailed
        }
        return cg
    }
}
