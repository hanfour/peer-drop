// PeerDrop/Core/Platform/PlatformDependencies.swift
import Foundation

/// Process-wide injection point for platform-specific dependencies. iOS
/// implementations are wired in `PeerDropApp` at launch; tests substitute mocks
/// in `setUp`. Each property is added incrementally as M0 introduces the
/// corresponding protocol (see docs/superpowers/plans/2026-05-25-m0-core-uikit-decoupling.md).
public struct PlatformDependencies {
    // Properties added in subsequent tasks. Empty for now so the file
    // compiles standalone.

    public init() {}

    /// Mutable singleton. App startup replaces this with iOS-wired
    /// implementations; tests replace with mocks.
    public static var shared = PlatformDependencies()
}
