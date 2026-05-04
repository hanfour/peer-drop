import Foundation
import CoreGraphics

enum SpriteServiceError: Error {
    case assetNotFound(SpriteRequest)
    case directionMissing(SpriteRequest)
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
}
