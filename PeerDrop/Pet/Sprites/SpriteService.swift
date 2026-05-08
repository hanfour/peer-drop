import Foundation
import CoreGraphics
import ImageIO
import ZIPFoundation

enum SpriteServiceError: Error {
    case assetNotFound(SpriteRequest)
    case directionMissing(SpriteRequest)
    case framePathMissing(String)
    case framePNGDecodeFailed(String)
}

/// Public façade for the v4.0 PNG sprite pipeline.
///
/// Wires SpriteAssetResolver → SpriteDecoder → SpriteCache. The actor
/// guarantees thread-safe state; in-flight task dedup ensures concurrent
/// requests for the same key trigger exactly one decode.
///
/// Bulk-fill optimisation: each zip carries all 8 directions, and decoding
/// touches all of them anyway. So `image(for:)` populates the cache with
/// every direction it decoded, not just the requested one. Subsequent
/// requests for other directions of the same species×stage hit cache.
actor SpriteService {

    static let shared = SpriteService()

    private let cache: SpriteCache
    private let bundle: Bundle
    private var inflightTasks: [SpriteRequest: Task<CGImage, Error>] = [:]
    private var animationFrames: [AnimationRequest: AnimationFrames] = [:]
    private(set) var decodeCount: Int = 0

    init(cache: SpriteCache = .shared, bundle: Bundle = .main) {
        self.cache = cache
        self.bundle = bundle
    }

    func image(for request: SpriteRequest) async throws -> CGImage {
        if let cached = cache.image(for: request) {
            return cached
        }

        if let existing = inflightTasks[request] {
            return try await existing.value
        }

        let task = Task<CGImage, Error> { [bundle, cache] in
            try await self.decodeAndCache(request: request, bundle: bundle, cache: cache)
        }
        inflightTasks[request] = task
        defer { inflightTasks[request] = nil }

        return try await task.value
    }

    private func decodeAndCache(
        request: SpriteRequest,
        bundle: Bundle,
        cache: SpriteCache
    ) async throws -> CGImage {
        guard let zipURL = SpriteAssetResolver.url(for: request, in: bundle) else {
            throw SpriteServiceError.assetNotFound(request)
        }

        // Decode off-actor: SpriteDecoder is sync (ZIPFoundation extract +
        // CGImageSourceCreate). Running it on the actor's executor would block
        // every other concurrent request to a *different* SpriteRequest until
        // we finish — the inflight-task dedup only handles same-key collisions.
        // Task.detached lets the heavy work run on a background thread; control
        // resumes back on the actor for cache fill + decodeCount mutation.
        // Revisit during M11/M12 perf gate (<16ms/frame on iPhone-8 floor).
        let images = try await Task.detached(priority: .userInitiated) {
            try SpriteDecoder.decode(zipURL: zipURL)
        }.value

        decodeCount += 1

        // Bulk-fill the cache for all decoded directions. Cache under BOTH the
        // resolved species ID (catalog fallback target) and the original
        // request's SpeciesID when they differ — otherwise repeated direction
        // requests under an unresolved ID (e.g. a typo'd subVariety pin) would
        // re-decode the same zip per direction.
        let resolvedSpecies = SpeciesCatalog.resolve(request.species) ?? request.species
        for (direction, cg) in images {
            cache.setImage(
                cg,
                for: SpriteRequest(species: resolvedSpecies, stage: request.stage, direction: direction))
            if resolvedSpecies != request.species {
                cache.setImage(
                    cg,
                    for: SpriteRequest(species: request.species, stage: request.stage, direction: direction))
            }
        }

        guard let cg = images[request.direction] else {
            // Defensive: SpriteDecoder silently skips missing entries (a
            // partial-asset zip can return <8 directions). The
            // SpriteDecoderTests.test_decode_partialZip_skipsMissingEntries
            // test pins that contract; this throw is the SpriteService-level
            // surface for it.
            throw SpriteServiceError.directionMissing(request)
        }
        return cg
    }

    // MARK: - v5 multi-frame animations

    /// Returns the decoded animation frames for one (species, stage, direction,
    /// action) tuple. v3.0 zip with the requested action → full frame array.
    /// v2.0 zip (or v3 zip lacking the action) → 1-frame static fallback from
    /// the rotation PNG, so callers don't need to special-case missing data.
    func frames(for request: AnimationRequest) async throws -> AnimationFrames {
        guard let zipURL = SpriteAssetResolver.url(for: request.spriteRequest, in: bundle) else {
            throw SpriteServiceError.assetNotFound(request.spriteRequest)
        }
        return try await loadFrames(at: zipURL, for: request)
    }

    /// Cache check + decode + cache fill. Private to keep the URL-direct
    /// shape from leaking to production callers (which must go through
    /// SpriteAssetResolver via `frames(for:)`).
    private func loadFrames(at zipURL: URL, for request: AnimationRequest) async throws -> AnimationFrames {
        if let cached = animationFrames[request] { return cached }

        let frames = try await Self.decodeAnimationFrames(
            zipURL: zipURL,
            direction: request.direction,
            action: request.action
        )
        animationFrames[request] = frames
        return frames
    }

    #if DEBUG
    /// Test seam: callers that already know the zip URL (e.g. unit tests
    /// against hand-crafted fixtures whose species isn't in SpeciesCatalog)
    /// bypass the asset resolver. Compiled out of release builds so production
    /// code physically can't reach this path.
    func framesInternal(at zipURL: URL, for request: AnimationRequest) async throws -> AnimationFrames {
        return try await loadFrames(at: zipURL, for: request)
    }
    #endif

    nonisolated static func decodeAnimationFrames(
        zipURL: URL,
        direction: SpriteDirection,
        action: PetAction
    ) async throws -> AnimationFrames {
        try await Task.detached(priority: .userInitiated) {
            let metadata = try SpriteMetadata.parse(zipURL: zipURL)
            let dirKey = direction.rawValue

            if let actionKey = action.animationKey,
               let anim = metadata.animations[actionKey],
               let paths = anim.directions[dirKey],
               !paths.isEmpty {
                let images = try paths.map { try Self.decodePNG(zipURL: zipURL, path: $0) }
                return AnimationFrames(images: images, fps: anim.fps, loops: anim.loops)
            }

            // Fallback path covers three real shapes:
            //  - v2 zip (no animations block at all)
            //  - v3 zip lacking the requested action (e.g. only walk shipped)
            //  - v3 zip with the action but missing this direction
            //    (Phase 3 ships partial coverage — production cat-tabby-adult
            //    has walk/south/ only; east/west/etc must degrade gracefully
            //    instead of throwing animationDirectionMissing all the way to
            //    PetEngine, where try? would swallow it and the pet would
            //    vanish on direction change).
            // All three degrade to a 1-frame "animation" backed by the
            // direction's rotation PNG. fps=1 so animator timer doesn't
            // advance through nothing; loops=false because there's no cycle.
            guard let path = metadata.rotations[dirKey] else {
                throw SpriteServiceError.framePathMissing("rotations/\(dirKey).png")
            }
            let image = try Self.decodePNG(zipURL: zipURL, path: path)
            return AnimationFrames(images: [image], fps: 1, loops: false)
        }.value
    }

    nonisolated private static func decodePNG(zipURL: URL, path: String) throws -> CGImage {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw SpriteServiceError.framePNGDecodeFailed(path)
        }
        guard let entry = archive[path] else {
            throw SpriteServiceError.framePathMissing(path)
        }
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
        } catch {
            throw SpriteServiceError.framePNGDecodeFailed(path)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SpriteServiceError.framePNGDecodeFailed(path)
        }
        return cg
    }
}
