# Session Close

Sibling app to Session Prep — pairs as a bookend: Prep going into a mix,
Close going out of one. Drop a folder of finished songs in, measure Integrated
LUFS / True Peak / tonal balance on all of them, propose a batch loudness
target that respects a True Peak ceiling (never clip), let you confirm or
edit it, then apply the leveling. See `Session-Close-Concept.md` (in the
project's knowledge folder) for the full design spec this was built from.

## Opening this in Xcode

The real app lives in **`Session Close.xcodeproj`** — open that (not
`Package.swift`) to build and run:

1. Open `Session Close.xcodeproj` in Xcode.
2. Pick the **Session Close** scheme and "My Mac" as the destination.
3. Hit **Run** (⌘R).

The Xcode project already has code signing, App Sandbox settings, and its
own generated Info.plist wired in via build settings — no separate setup
step needed. Code signing is set to Automatic under team `9MP82ALK4M`; if
you're building under a different Apple Developer team, update
`DEVELOPMENT_TEAM` in the project's build settings and `Scripts/
ExportOptions.plist` first.

`Package.swift` and `Sources/SessionClose/` are a secondary, reference-only
mirror of the same source kept in sync for diffing purposes; they aren't
part of the shipped app and don't need to be opened to build or run it.

## Status of this build

This was scaffolded end-to-end from the concept doc, mirroring Session
Prep's architecture and reusing several of its components directly
(`AudioPreviewPlayer`, `GoniometerBuffer`/`GoniometerView`, `TruePeakMeter`,
`BroadcastMetadata`, the folder-scan + subfolder-navigation pattern, the
Sparkle/About-window/color-palette chrome). **It has not been compiled or
run** — the environment this was built in has no macOS/Xcode toolchain, so
there was no way to build-check it before handing it over. Open it in Xcode
and treat the first build as the real first pass; if anything doesn't
compile, paste the error and it'll get fixed directly.

A few spots worth a second look first, roughly in order of how likely they
are to need adjustment:

- **`Engine/SpectrumAnalyzer.swift`** — the Accelerate/vDSP real-FFT setup
  (`vDSP_ctoz` / `vDSP_fft_zrip` split-complex prep) is the one block of code
  in this pass that leans on Accelerate's C-interop API surface most
  heavily. The pattern follows Apple's standard real-FFT idiom, but this is
  the single most likely spot for a build error or an off-by-factor-of-two
  in the magnitude scaling if something doesn't match up exactly.
- **`Engine/LoudnessMeter.swift`** — the K-weighting filter coefficients
  (the two biquad stages' analog-prototype parameters) and the BS.1770
  gating algorithm follow the published spec/well-known open-source
  approach, but weren't validated against a reference LUFS meter. Worth
  spot-checking Integrated LUFS on a file you already know the loudness of
  in another tool (e.g. a DAW's own loudness meter) before trusting it for
  real leveling decisions.
- **Assets** — `AppIcon.appiconset` and `WatermarkMark.imageset` have empty
  `Contents.json` placeholders (no image files) since you mentioned working
  on a new logo/watermark separately. Drop the PNGs in when ready; the
  catalog slots are already wired up (`ASSETCATALOG_COMPILER_APPICON_NAME`
  in the project build settings, `Image("WatermarkMark")` in ContentView's
  empty state).
- **Sparkle signing key** — done. `SUPublicEDKey` is set to a real key,
  deliberately shared with Session Prep rather than a separate one — see
  `RELEASING.md`'s "One-time setup" section for why that's an acceptable
  tradeoff here.

## Open follow-ups (flagged, not forgotten)

- **Batch Average target computation.** `LevelingEngine.proposedTargetLUFS`'s
  `.batchAverage` case is currently a plain arithmetic mean of each file's
  Integrated LUFS — not duration-weighted, not power/energy-averaged before
  converting back to LUFS. Left as-is deliberately (see the comment right
  above that line in the code), but flagged for a real discussion on
  whether duration-weighting or energy-domain averaging would better match
  what "the album's average loudness" should mean.

## Deliberately not in this pass

- Recursive subfolder scanning (matches Session Prep — move deeper via the
  subfolder chips/Cmd+arrow shortcuts instead, which *are* carried over).
- In-app revert/undo (originals are always preserved via move-not-delete).
- Limiter-assisted leveling, the DAW-plugin form factor, and track-to-track
  level continuity — all flagged in the concept doc as later/bigger ideas,
  not v1 scope.

## Try it

1. Run the app.
2. **File > Open Folder…**, pick a folder of finished WAV/AIFF mixes.
3. Check the measured Integrated LUFS / True Peak numbers, try switching
   target modes, and confirm a small test batch before trusting it on real
   masters.
4. Tell me what's wrong and we'll fix it from there.
