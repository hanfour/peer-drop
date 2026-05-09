import CoreGraphics
import Foundation

/// Single source of truth for v5 sprite-asset constants.
///
/// Background: before this file existed, "68×68 v3.0 schema" was scattered
/// across PetRendererV3 tests (hardcoded `XCTAssertEqual(cg.width, 68)`),
/// the bash normalize script (heuristic `>= 6 frames = walk`), and STATUS.md
/// operator instructions. Bumping any constant required a grep + multi-edit.
///
/// All v5 callers should read from `AssetSpec` rather than hardcoding. The
/// normalize script reads the JSON-exported version (`Scripts/normalize_pixellab/asset_spec.json`)
/// for cross-language consistency — running `Scripts/regenerate-asset-spec-json.sh`
/// after editing this file keeps them in sync.
enum AssetSpec {

    // MARK: - Canvas

    /// Canonical sprite canvas size (width = height for the v4/v5 design).
    /// PixelLab character creation: select Character Size 48px → ~40% larger
    /// canvas = 68px (per their UI hint). Test-fixture zips at this size.
    static let canonicalCanvas: CGSize = CGSize(width: 68, height: 68)

    /// Number of rotation directions PixelLab generates per character.
    /// Maps onto the `SpriteDirection` enum (south, south-east, east,
    /// north-east, north, north-west, west, south-west).
    static let directions = 8

    // MARK: - Per-action animation params

    /// Frame counts and timing per action. Used by:
    /// • `Scripts/normalize-pixellab-zip.sh` injects these into the
    ///   normalized metadata.json (PixelLab raw export omits these fields).
    /// • `PetEngine.dispatchActionToAnimator` reads from the normalized
    ///   metadata via `SpriteService.frames(for:)`.
    /// • Tests pin expected behavior against these values.
    enum Action {
        static let walkFrameCount = 8        // PixelLab "Walk (8 frames)" preset
        static let walkFps = 6               // ~1.3 sec full cycle
        static let walkLoops = true

        static let idleFrameCountPixelLabDefault = 5  // PixelLab default for Idle preset
        static let idleFps = 2               // ~2.5 sec full cycle
        static let idleLoops = true
    }

    // MARK: - Heuristic for normalize script

    /// Frame-count threshold dividing "walk-class" from "idle-class" anim
    /// slots. PixelLab exports use UUID-keyed slots without semantic names;
    /// the normalize script uses this threshold to map UUID → "walk" or
    /// "idle". `>= 6` covers Walk (8) and Walk (6); `< 6` covers Idle (5),
    /// Breathing Idle (4), and other short cycles.
    ///
    /// Rationale for the cutoff at 6: there's no PixelLab preset between 5
    /// and 6 frames (idle = 4 or 5; walk = 4, 6, or 8). The 6-frame walk
    /// variant is rare enough that classifying it as walk is safe.
    static let actionHeuristicWalkMinFrames = 6

    // MARK: - Schema version

    /// Normalized metadata.json `export_version` value. v3.0 = post-normalize
    /// schema with semantic action keys ("walk", "idle"), explicit fps /
    /// frame_count / loops fields, and `v5_compatible: true`. v2.0 = raw
    /// PixelLab export (UUID keys, no fps/loops metadata).
    static let normalizedSchemaVersion = "3.0"
    static let rawPixelLabSchemaVersion = "2.0"
}
