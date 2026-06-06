# PeerDropMac Resources

Bundled resources for the macOS app.

## `Ringtone.caf` (M3)

Incoming-call ringtone. Loopable AAC-in-CAF, mono, 44.1 kHz, ≤6s, ~50 KB target.

**Source:** human action required before Mac App Store ship. Suggested:
- Commission a short branded ring, or
- Use a CC0 source (e.g. Freesound) and convert: `afconvert -d aac -f caff Source.aiff Ringtone.caf`

Until the file is added, `MacRingtonePlayer` falls back to `NSSound(named: "Glass")` looped every ~3s so M3 dev builds remain audible. The fallback is **not** acceptable for production — sandboxed apps cannot reference `/System/Library/Sounds/`, so the Glass loop may not play at all in shipped builds depending on sandbox configuration.
