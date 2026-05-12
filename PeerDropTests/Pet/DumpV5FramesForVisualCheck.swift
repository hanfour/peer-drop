import XCTest
import UIKit
@testable import PeerDrop

/// One-shot visual verification: dumps every cat-tabby-adult walk frame from
/// the SOUTH, EAST, WEST directions (the three that have multi-frame v5 data
/// per `cat-tabby-adult.zip`) into /tmp/cat-tabby-frames/ as PNGs. Intended
/// to be run manually:
///
///     xcodebuild test -only-testing:PeerDropTests/DumpV5FramesForVisualCheck …
///
/// Outputs:
///   /tmp/cat-tabby-frames/walk-south-0.png … walk-south-7.png
///   /tmp/cat-tabby-frames/walk-east-0.png  … walk-east-7.png
///   /tmp/cat-tabby-frames/walk-west-0.png  … walk-west-7.png
///   /tmp/cat-tabby-frames/idle-south-0.png … idle-south-4.png
///
/// The test always passes — its purpose is the on-disk output, not assertion.
@MainActor
final class DumpV5FramesForVisualCheck: XCTestCase {

    func test_dumpAllCatTabbyAdultFrames() async throws {
        let outDir = URL(fileURLWithPath: "/tmp/cat-tabby-frames")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let service = SpriteService(cache: SpriteCache(countLimit: 32), bundle: .main)
        let species = SpeciesID("cat-tabby")
        let stage: PetLevel = .adult

        for action in [PetAction.walking, PetAction.idle] {
            for direction in SpriteDirection.allCases {
                let req = AnimationRequest(species: species, stage: stage,
                                           direction: direction, action: action)
                let frames: AnimationFrames
                do {
                    frames = try await service.frames(for: req)
                } catch {
                    print("⚠️  skipped \(action) \(direction): \(error)")
                    continue
                }

                for (i, cg) in frames.images.enumerated() {
                    let url = outDir.appendingPathComponent("\(action.rawValue)-\(direction)-\(i).png")
                    guard let pngData = UIImage(cgImage: cg).pngData() else {
                        XCTFail("png encode failed for \(url.lastPathComponent)")
                        continue
                    }
                    try pngData.write(to: url)
                }
                print("✅ \(action.rawValue) \(direction): \(frames.images.count) frames @ \(frames.fps)fps")
            }
        }

        // List the result so the test log surfaces what landed on disk.
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path))?.sorted() ?? []
        print("Wrote \(written.count) files to \(outDir.path):")
        for f in written.prefix(20) { print("  \(f)") }
        if written.count > 20 { print("  … and \(written.count - 20) more") }
    }
}
