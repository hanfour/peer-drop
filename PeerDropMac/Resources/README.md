# PeerDropMac Resources

Bundled resources for the macOS app.

## `Ringtone.caf` (M3 / M4 Task 2 — DONE)

Incoming-call ringtone. Loopable AAC-in-CAF, mono, 44.1 kHz, 3.18 s, 17 KB.

**Provenance (keep for App Review / licensing traceability):**
- Source: "8bit Ringtone [FREE TO USE] [LOOPABLE]" by **YXMusic**,
  Freesound #423652 — <https://freesound.org/people/YXMusic/sounds/423652/>
- License: **Creative Commons 0 (CC0 1.0)** — no attribution required,
  commercial use permitted. License verified on the sound page 2026-07-03.
- Processing: original is a 12.7 s file containing the same ring phrase
  4× with gaps (period 3.178 s). One full period (ring + trailing gap,
  0.596 s → 3.774 s) was cut so `AVAudioPlayer(numberOfLoops: -1)`
  reproduces the original cadence seamlessly:
  ```bash
  ffmpeg -ss 0.596 -to 3.774 -i 423652_8481610-hq.mp3 -ac 1 -ar 44100 ring.wav
  afconvert -f caff -d aac -b 64000 ring.wav Ringtone.caf
  ```

`MacRingtonePlayer` prefers this bundled file; the `NSSound(named: "Glass")`
fallback remains only as a safety net for builds that strip resources.
