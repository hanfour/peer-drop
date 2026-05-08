import Foundation
import ZIPFoundation

struct SpriteMetadata {
    let exportVersion: String
    let rotations: [String: String]
    let animations: [String: AnimationDescriptor]

    struct AnimationDescriptor {
        let fps: Int
        let frameCount: Int
        let loops: Bool
        let directions: [String: [String]]
    }

    static func parse(zipURL: URL) throws -> SpriteMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw SpriteMetadataError.zipOpenFailed(underlying: error)
        }

        guard let entry = archive["metadata.json"] else {
            throw SpriteMetadataError.metadataMissing
        }

        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
        } catch {
            throw SpriteMetadataError.metadataExtractionFailed(underlying: error)
        }

        let raw: RawMetadata
        do {
            raw = try JSONDecoder().decode(RawMetadata.self, from: data)
        } catch {
            throw SpriteMetadataError.metadataDecodeFailed(underlying: error)
        }

        return raw.toSpriteMetadata()
    }
}

enum SpriteMetadataError: Error {
    case zipOpenFailed(underlying: Error)
    case metadataMissing
    case metadataExtractionFailed(underlying: Error)
    case metadataDecodeFailed(underlying: Error)
}

private struct RawMetadata: Decodable {
    let frames: Frames
    let export_version: String

    struct Frames: Decodable {
        let rotations: [String: String]
        let animations: [String: AnimDesc]?
    }

    struct AnimDesc: Decodable {
        let fps: Int
        let frame_count: Int
        let loops: Bool
        let directions: [String: [String]]
    }

    func toSpriteMetadata() -> SpriteMetadata {
        let animations: [String: SpriteMetadata.AnimationDescriptor] =
            (frames.animations ?? [:]).mapValues { raw in
                SpriteMetadata.AnimationDescriptor(
                    fps: raw.fps,
                    frameCount: raw.frame_count,
                    loops: raw.loops,
                    directions: raw.directions
                )
            }
        return SpriteMetadata(
            exportVersion: export_version,
            rotations: frames.rotations,
            animations: animations
        )
    }
}
