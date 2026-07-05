import XCTest
@testable import PeerDropPet

/// Pins that the Pet model enums resolve their `displayName` through the module
/// String Catalog (`Localizable.xcstrings` → per-language `Localizable.strings`
/// in `Bundle.module`) instead of the old hard-coded zh-Hant literals.
///
/// Two guarantees:
///  1. **Every case is translated in every shipped language** — a new enum case
///     added without a catalog entry fails `testEveryCaseHasEntryInAllLanguages`.
///  2. **The catalog is actually wired** — `displayName` never leaks the raw key
///     (`pet.body.cat`) and matches the expected per-language text.
///
/// Locale-independent: instead of relying on the test host's language, we open
/// each `<lang>.lproj` sub-bundle directly and look strings up there.
final class EnumLocalizationTests: XCTestCase {

    private let shippedLanguages = ["en", "zh-Hant", "zh-Hans", "ja", "ko"]

    // MARK: Key derivation (mirrors the production `displayName` implementations)

    private func allKeys() -> [String] {
        var keys: [String] = []
        keys += BodyGene.allCases.map { "pet.body.\($0.rawValue)" }
        keys += EyeGene.allCases.map { "pet.eye.\($0.rawValue)" }
        keys += PatternGene.allCases.map { "pet.pattern.\($0.rawValue)" }
        keys += FoodType.allCases.map { "pet.food.\($0.rawValue)" }
        keys += PetMood.allCases.map { "pet.mood.\($0.rawValue)" }
        keys += PetLevel.allCases.map { "pet.level.\($0.assetSlug)" }
        return keys
    }

    /// Resolve a `<lang>.lproj` sub-bundle of the PeerDropPet module bundle.
    /// (`Bundle.module` here would resolve to the *test* target's bundle, so we
    /// go through the module's own public accessor.) Robust to SwiftPM
    /// lowercasing the region (`zh-Hant` → `zh-hant.lproj`) and to case-sensitive
    /// volumes.
    private func bundle(for language: String) -> Bundle? {
        let root = SpriteAssetResolver.moduleBundle
        if let path = root.path(forResource: language, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        let target = "\(language.lowercased()).lproj"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.bundlePath),
              let match = entries.first(where: { $0.lowercased() == target }) else {
            return nil
        }
        return Bundle(path: (root.bundlePath as NSString).appendingPathComponent(match))
    }

    private let sentinel = "\u{1}__MISSING__"

    private func localized(_ key: String, _ language: String,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let b = bundle(for: language) else {
            XCTFail("No \(language).lproj bundle inside Bundle.module", file: file, line: line)
            return sentinel
        }
        return b.localizedString(forKey: key, value: sentinel, table: nil)
    }

    // MARK: Coverage — every case translated in every language

    func testEveryCaseHasEntryInAllLanguages() {
        for language in shippedLanguages {
            for key in allKeys() {
                let value = localized(key, language)
                XCTAssertNotEqual(value, sentinel,
                                  "Missing translation for '\(key)' in \(language)")
                XCTAssertNotEqual(value, key,
                                  "Translation for '\(key)' in \(language) is the raw key")
                XCTAssertFalse(value.isEmpty, "Empty translation for '\(key)' in \(language)")
            }
        }
    }

    // MARK: displayName is wired to the catalog (not the raw key)

    func testDisplayNamesResolveFromCatalogUnderProcessLocale() {
        // Under whatever language the test host runs, displayName must be a
        // resolved translation, never the raw catalog key.
        XCTAssertFalse(BodyGene.cat.displayName.hasPrefix("pet."),
                       "BodyGene.displayName leaked the raw key: \(BodyGene.cat.displayName)")
        XCTAssertFalse(EyeGene.round.displayName.hasPrefix("pet."))
        XCTAssertFalse(PatternGene.none.displayName.hasPrefix("pet."))
        XCTAssertFalse(FoodType.rice.displayName.hasPrefix("pet."))
        XCTAssertFalse(PetMood.happy.displayName.hasPrefix("pet."))
        XCTAssertFalse(PetLevel.baby.displayName.hasPrefix("pet."))
    }

    // MARK: Representative exact per-language values

    func testEnglishExactValues() {
        XCTAssertEqual(localized("pet.body.cat", "en"), "Cat")
        XCTAssertEqual(localized("pet.body.redpanda", "en"), "Red Panda")
        XCTAssertEqual(localized("pet.eye.round", "en"), "Round Eyes")
        XCTAssertEqual(localized("pet.pattern.none", "en"), "Solid")
        XCTAssertEqual(localized("pet.food.rice", "en"), "Rice Ball")
        XCTAssertEqual(localized("pet.mood.happy", "en"), "Happy")
        XCTAssertEqual(localized("pet.level.baby", "en"), "Baby")
    }

    func testTraditionalChineseExactValues() {
        // zh-Hant台灣用語 — must match the previously hard-coded literals so the
        // Chinese experience is unchanged.
        XCTAssertEqual(localized("pet.body.cat", "zh-Hant"), "貓咪")
        XCTAssertEqual(localized("pet.body.slime", "zh-Hant"), "史萊姆")
        XCTAssertEqual(localized("pet.eye.round", "zh-Hant"), "圓滾眼")
        XCTAssertEqual(localized("pet.pattern.none", "zh-Hant"), "純色")
        XCTAssertEqual(localized("pet.food.fish", "zh-Hant"), "小魚乾")
        XCTAssertEqual(localized("pet.mood.startled", "zh-Hant"), "嚇到")
        XCTAssertEqual(localized("pet.level.elder", "zh-Hant"), "老年")
    }

    func testOtherLanguagesResolveDistinctly() {
        // Sanity: ja / ko / zh-Hans each provide their own text for a sample key.
        XCTAssertEqual(localized("pet.mood.happy", "ja"), "ごきげん")
        XCTAssertEqual(localized("pet.mood.happy", "ko"), "행복")
        XCTAssertEqual(localized("pet.mood.happy", "zh-Hans"), "开心")
    }
}
