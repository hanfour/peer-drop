// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PeerDropKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PeerDropPlatform", targets: ["PeerDropPlatform"]),
        .library(name: "PeerDropCore", targets: ["PeerDropCore"]),
        .library(name: "PeerDropTransport", targets: ["PeerDropTransport"]),
        .library(name: "PeerDropSecurity", targets: ["PeerDropSecurity"]),
        .library(name: "PeerDropProtocol", targets: ["PeerDropProtocol"]),
        .library(name: "PeerDropPet", targets: ["PeerDropPet"]),
        .library(name: "PeerDropPTY", targets: ["PeerDropPTY"]),
    ],
    dependencies: [
        // External SPM packages — re-declared here so PeerDropKit can be
        // built standalone via `swift build`. The PeerDrop app target also
        // depends on these (declared in project.yml `packages:` section),
        // but each declaration is independent — Xcode resolves to the same
        // pinned versions.
        .package(url: "https://github.com/stasel/WebRTC", exact: "125.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "PeerDropPlatform",
            dependencies: []  // pure leaf — Foundation/UIKit/AppKit/AVFoundation/CoreGraphics only
        ),
        .testTarget(name: "PeerDropPlatformTests", dependencies: ["PeerDropPlatform"]),
        // PeerDropCore is the keystone — depends on all 4 leaf modules.
        // Per spec §1: "Core consumes Transport/Security/Protocol/Pet";
        // strict single-direction (no cycles).
        .target(
            name: "PeerDropCore",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropTransport",
                "PeerDropSecurity",
                "PeerDropProtocol",
                "PeerDropPet",
            ]
        ),
        .target(
            name: "PeerDropTransport",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropProtocol",
                "PeerDropSecurity",
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        // PeerDropSecurity carries PeerIdentity (which builds itself via
        // `PlatformDependencies.shared.deviceName()`) and the PeerMessage
        // hello/secureHandshake factories — hence dependencies on
        // PeerDropPlatform and PeerDropProtocol. PeerDropProtocol stays
        // dependency-free; the extension is declared from the Security
        // side so Protocol need not import Security.
        .target(
            name: "PeerDropSecurity",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropProtocol",
            ]
        ),
        .target(name: "PeerDropProtocol"),
        .target(
            name: "PeerDropPet",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropProtocol",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                // Task 7 moved 324 species×stage zips into Resources/Pets/.
                // `.copy("Resources/Pets")` preserves the Pets/ subdirectory
                // in the module bundle so SpriteAssetResolver can use
                // `bundle.url(forResource:withExtension:subdirectory: "Pets")`.
                // `.process` would flatten the tree to the bundle root, making
                // the subdirectory: lookup return nil for every zip.
                .copy("Resources/Pets"),
            ]
        ),
        // Test targets — one per product module. Each tests its corresponding
        // module via `@testable import`. Empty in M1d-1; real tests migrate
        // here in M1d-2 onwards alongside production source files.
        .testTarget(name: "PeerDropCoreTests", dependencies: ["PeerDropCore"]),
        .testTarget(name: "PeerDropTransportTests", dependencies: ["PeerDropTransport"]),
        .testTarget(
            name: "PeerDropSecurityTests",
            dependencies: [
                "PeerDropSecurity",
                "PeerDropProtocol",
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(name: "PeerDropProtocolTests", dependencies: ["PeerDropProtocol"]),
        .testTarget(
            name: "PeerDropPetTests",
            dependencies: [
                "PeerDropPet",
                "PeerDropPlatform",
                "PeerDropProtocol",
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(name: "PeerDropPTY"),
        .testTarget(name: "PeerDropPTYTests", dependencies: ["PeerDropPTY"]),
        .executableTarget(
            name: "peerdrop-cli",
            dependencies: [
                "PeerDropCore",
                "PeerDropSecurity",
                "PeerDropTransport",
                "PeerDropProtocol",
                "PeerDropPTY",
            ]
        ),
        .testTarget(
            name: "PeerDropCLITests",
            dependencies: [
                "peerdrop-cli",
                "PeerDropCore",
                "PeerDropProtocol",
            ]
        ),
    ]
)
