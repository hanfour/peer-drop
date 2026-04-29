import Foundation
import ImageIO
import ZIPFoundation

enum SpikeLoaderError: Error {
    case entryNotFound(String)
    case decodeFailed
}

enum SpikeLoader {
    static func loadEast(zipURL: URL) throws -> CGImage {
        let archive = try Archive(url: zipURL, accessMode: .read)
        guard let entry = archive["rotations/east.png"] else {
            throw SpikeLoaderError.entryNotFound("rotations/east.png")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SpikeLoaderError.decodeFailed
        }
        return cg
    }
}
