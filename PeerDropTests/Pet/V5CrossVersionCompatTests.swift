import XCTest
@testable import PeerDrop

/// Phase 7 — pins the v5-specific cross-version compat surface.
///
/// v5 deliberately changes nothing in the wire format (PetGreeting,
/// PetPayload, currentProtocolVersion, PetState, PetGenome). The whole
/// upgrade is render-side: new sprite zip layout + new SpriteService cache
/// + new PetRendererV3 overload + animator wiring. So the cross-version
/// concerns are:
///
///   • protocolVersion stays at 2 — no peer renegotiation needed; v4.0
///     and v5.0 peers exchange greetings normally.
///   • A v5 receiver renders a v4-format zip ("animations": {} in
///     metadata.json, only rotations/<dir>.png present) gracefully —
///     PR #28's bundle still has 32 of these for species we haven't
///     mass-gen'd yet.
///   • A v5 receiver decodes a v3.x peer's greeting — already pinned by
///     PetPayloadCrossVersionTests; this file just covers the v5-side
///     render path against that decoded greeting.
@MainActor
final class V5CrossVersionCompatTests: XCTestCase {

    private var testBundle: Bundle { Bundle(for: type(of: self)) }

    // MARK: - protocolVersion is unchanged

    func test_v5_currentProtocolVersion_unchanged_at2() {
        // If this test fails, v5.0 is changing the peer wire format and we
        // need a downgrade path for v4 receivers (per the M6.2 pattern).
        XCTAssertEqual(PetGreeting.currentProtocolVersion, 2,
                       "v5 must not bump protocolVersion — wire format unchanged")
    }

    // MARK: - v5 renderer renders v4-format zip (PR #28 partial coverage)

    func test_v5renderer_v4FormatZip_rendersAtAnyFrameIndex() async throws {
        // PeerDropTests/Resources/Pets/cat-tabby-adult.zip is the v4-format
        // fixture (export_version "2.0", empty animations dict). The v5
        // render(action:frameIndex:) overload must degrade to single-frame
        // static via SpriteService's fallback contract — frameIndex out of
        // bounds wraps to 0, so even frameIndex=99 returns a valid CGImage.
        let service = SpriteService(cache: SpriteCache(countLimit: 30), bundle: testBundle)
        let renderer = PetRendererV3(service: service)
        var genome = PetGenome.random()
        genome.body = .cat
        genome.subVariety = "tabby"

        let cg = try await renderer.render(
            genome: genome,
            level: .adult,
            direction: .east,
            action: .walking,
            frameIndex: 99,
            mood: .happy
        )

        XCTAssertEqual(cg.width, 68, "v4 fixture is 68×68 — render must preserve dimensions")
    }

    func test_v5renderer_v4FormatZip_idleAction_alsoRenders() async throws {
        // Same as above but for the .idle action path — same fallback,
        // different action key. Pins both render paths against v4 zips.
        let service = SpriteService(cache: SpriteCache(countLimit: 30), bundle: testBundle)
        let renderer = PetRendererV3(service: service)
        var genome = PetGenome.random()
        genome.body = .cat
        genome.subVariety = "tabby"

        let cg = try await renderer.render(
            genome: genome,
            level: .adult,
            direction: .west,
            action: .idle,
            frameIndex: 0,
            mood: .happy
        )

        XCTAssertNotNil(cg)
    }

    // MARK: - v3.x peer greeting → v5 render

    func test_v5_decodesV3xGreeting_andResolvedSpeciesRendersOnV5() async throws {
        // Bytes-for-bytes the v3.x shape (no subVariety/seed in genome,
        // level=3 maps to .adult). Sister to PetPayloadCrossVersionTests's
        // v3.x->v4 decode test, but going one step further: render the
        // decoded greeting through the v5 pipeline.
        let v3xJSON = """
        {
          "petID": "22222222-2222-2222-2222-222222222222",
          "name": "RetroCat",
          "level": 3,
          "mood": "happy",
          "genome": {
            "body": "cat",
            "eyes": "dot",
            "pattern": "stripe",
            "personalityGene": 0.42
          }
        }
        """.data(using: .utf8)!

        let greeting = try JSONDecoder().decode(PetGreeting.self, from: v3xJSON)
        XCTAssertEqual(greeting.level, .adult)
        XCTAssertNil(greeting.genome.subVariety,
                     "v3.x JSON has no subVariety — decoded as nil")

        // Render the v3.x peer's pet on this v5 receiver.
        let service = SpriteService(cache: SpriteCache(countLimit: 30), bundle: testBundle)
        let renderer = PetRendererV3(service: service)
        let cg = try await renderer.render(
            genome: greeting.genome,
            level: greeting.level,
            direction: .south,
            action: .idle,
            frameIndex: 0,
            mood: greeting.mood
        )

        XCTAssertNotNil(cg)
        XCTAssertEqual(cg.width, 68,
                       "v3.x cat genome resolves to v4 cat-tabby fallback in catalog (68×68)")
    }
}
