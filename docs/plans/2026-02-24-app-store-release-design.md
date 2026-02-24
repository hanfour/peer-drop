# App Store Release Preparation — Design Document

**Date:** 2026-02-24
**Version:** 1.0.0
**Status:** Approved

## Overview

Prepare PeerDrop for its initial App Store submission. The app is feature-complete with 169 passing tests, comprehensive Fastlane setup, and 5-language App Store metadata. This plan covers the remaining gaps before submission.

## Current State

- **Ready:** Privacy Manifest, Launch Screen, Fastlane config, 72+ screenshots, version 1.0.0, iOS 16.0+ deployment target, 169 tests passing
- **Partial:** Localizable.xcstrings has 120/~194 strings across 5 languages (en, zh-Hant, zh-Hans, ja, ko)
- **Missing:** ~70 unlocalised UI strings, onboarding flow, code signing setup

## Scope

### 1. App Icon — Auto-scaling verification

Confirm the existing 1024x1024 icon in `AppIcon.appiconset` is correctly configured for Xcode 15+ automatic scaling. Update `Contents.json` if needed to ensure iOS 16 compatibility.

**Files:** `PeerDrop/App/Assets.xcassets/AppIcon.appiconset/Contents.json`

### 2. Localisation Completion (~70 strings)

Scan all SwiftUI views for hardcoded string literals not present in `Localizable.xcstrings`. Add missing entries with translations for all 5 languages.

**Approach:** SwiftUI `Text("...")` automatically uses `LocalizedStringKey`, so most changes are xcstrings-only — no Swift code changes needed unless strings are constructed programmatically.

**Files:** `PeerDrop/App/Localizable.xcstrings`, potentially some .swift files where strings bypass LocalizedStringKey

### 3. Onboarding Flow

A 3-4 page TabView-style onboarding shown on first launch:

1. **Welcome** — App logo + tagline "Secure peer-to-peer sharing"
2. **Discover** — How to find nearby devices on the same network
3. **Transfer** — File, photo, video sharing capabilities
4. **Get Started** — CTA button to enter the main app

**Technical:**
- New file: `PeerDrop/UI/OnboardingView.swift`
- `@AppStorage("hasCompletedOnboarding")` flag
- Gate in `ContentView` to show onboarding vs main app
- All onboarding strings added to xcstrings (5 languages)

### 4. Code Signing Guide

Document the manual Xcode steps for code signing setup:
- Apple Developer account enrollment
- Team ID configuration
- Automatic signing setup
- Provisioning profile generation
- Archive and upload workflow

**File:** `docs/code-signing-guide.md`

### 5. Final Verification Checklist

1. `xcodebuild build` succeeds
2. Full test suite passes (169+ tests)
3. Archive build succeeds (post code-signing)
4. Fastlane metadata validation
5. Privacy manifest matches actual API usage
6. All 5 language localisations render correctly
7. Onboarding flow works on first launch and doesn't reappear

## Out of Scope (v1.1+)

- App Store review prompt (SKStoreReviewController)
- Crash reporting / analytics
- Localised screenshots for non-English languages
- Additional onboarding pages

## Languages

| Code | Language |
|------|----------|
| en | English |
| zh-Hant | Traditional Chinese |
| zh-Hans | Simplified Chinese |
| ja | Japanese |
| ko | Korean |
