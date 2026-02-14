fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios screenshots

```sh
[bundle exec] fastlane ios screenshots
```

Capture App Store screenshots

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload screenshots to App Store Connect

### ios screenshots_and_upload

```sh
[bundle exec] fastlane ios screenshots_and_upload
```

Capture screenshots and upload to App Store Connect

### ios add_frames_frameit

```sh
[bundle exec] fastlane ios add_frames_frameit
```

Add device frames and titles to screenshots (frameit - requires supported devices)

### ios add_frames

```sh
[bundle exec] fastlane ios add_frames
```

Add background and titles to screenshots (custom script - works with all devices)

### ios screenshots_framed

```sh
[bundle exec] fastlane ios screenshots_framed
```

Capture screenshots and add frames

### ios download_metadata

```sh
[bundle exec] fastlane ios download_metadata
```

Download existing metadata from App Store Connect

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload metadata to App Store Connect

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
