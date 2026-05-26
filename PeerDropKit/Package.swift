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
                "PeerDropTransport",
                "PeerDropSecurity",
                "PeerDropProtocol",
                "PeerDropPet",
            ]
        ),
        .target(
            name: "PeerDropTransport",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
        .target(name: "PeerDropSecurity"),
        .target(name: "PeerDropProtocol"),
        .target(
            name: "PeerDropPet",
            dependencies: [
                "PeerDropPlatform",
                "PeerDropProtocol",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                // Task 7 will populate Resources/ with the 324 species×stage
                // zips. The Resources/ directory is declared now so SPM
                // generates Bundle.module for this target (needed at compile
                // time in SpriteAssetResolver, SpriteService, SpriteSheetLoader,
                // AccessoryOverlay). Only a placeholder.txt lives here
                // until Task 7 moves the Pets/ folder into this subtree.
                .process("Resources"),
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
        .testTarget(name: "PeerDropPetTests", dependencies: ["PeerDropPet"]),
    ]
)
