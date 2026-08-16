# Session Close (working name) — Concept Doc

Status: **idea capture only** — nothing built, nothing scheduled. Saved for
later reference. Not part of the Session Prep codebase; a possible sibling
app.

## One-line pitch

Drop a folder of finished songs in. Measure loudness and true peak on all of
them. Suggest a common loudness target that respects a true-peak ceiling
(never clip), let the user confirm or edit it, then apply the leveling. Also
show how consistent the files are tonally (frequency response) as a QC
signal, not a fix.

## Naming

- **Session Close** (leading candidate) — pairs with Session Prep as a
  bookend: prep going into a mix, close going out of one. Doesn't lock the
  name to "just loudness," which matters if frequency-comparison becomes a
  real feature rather than a QC readout.
- **Mix QC** — more literal/utilitarian, less of a paired identity with
  Session Prep.
- Other options considered: Album QC, Loudness Check, Master Check.

## Core measurement

Per ITU-R BS.1770 / EBU R128 — this replaces RMS, which doesn't reflect how
the ear perceives loudness over time or across frequencies.

- **Integrated LUFS** (gated, whole-file) — the target-setting metric. What
  streaming platforms normalize to (rough reference points: Spotify/YouTube
  ~-14 LUFS, Apple Music ~-16 LUFS, broadcast ~-23/-24 LUFS depending on
  region). This is the number a batch gets leveled against.
- **Short-term LUFS** (3s, ungated) — QC readout, not a target.
- **Momentary LUFS** (400ms, ungated) — QC readout; good for spotting a
  hot section within a track.
- **True Peak (dBTP)** — oversampled peak detection (catches inter-sample
  peaks a sample-domain meter misses — the actual clipping risk on D/A or
  lossy re-encode). Default ceiling: **-0.7 dBTP** (user's stated default;
  note common industry convention is closer to -1.0 dBTP for extra lossy-codec
  margin — worth a deliberate choice, not an oversight).
- **Loudness Range (LRA)** — not requested, but a natural companion stat
  (dynamic spread across a track, from short-term percentiles). Cheap to add
  once short-term is already being computed. Candidate for v1 bonus column.

## Leveling logic

1. Scan folder, decode each file, run a BS.1770 pass on all of them
   (Momentary, Short-term, Integrated, True Peak).
2. Present results in a table (reusing Session Prep's table pattern).
3. Propose a batch target Integrated LUFS. Candidate strategies (pick one as
   default, keep as an open question — see below):
   - Match everyone to one **user-flagged reference track** (repurpose the
     True Stereo/Mono tag column into a "Target" marker — click a row to
     make it the reference).
   - Match to the **batch average** Integrated LUFS.
   - Match to the **loudest file** (gain-down-only for the rest — avoids
     ever needing makeup gain, which is otherwise the safer default absent
     a flagged reference track).
   - Match to a **fixed external standard** (e.g. -14 LUFS for streaming),
     independent of what's in the batch.
4. User can edit/confirm the proposed target before anything is applied —
   same measure-then-suggest-then-confirm pattern as Session Prep's
   classification step.
5. Compute required gain per file: `gain_dB = target_LUFS - measured_LUFS`.
6. **Never clip, TP always wins — but direction doesn't matter.** Raising a
   file's level is just as valid as lowering one; the only constraint is
   whether the result stays under the TP ceiling. (This is why "match to the
   loudest file, gain-down-only" isn't actually the safer default it first
   looks like — it's just one strategy among the modes below, not a
   philosophy the whole tool should be built around.) A flat gain change
   moves LUFS and True Peak by the same number of dB, so the maximum gain
   any file can take before hitting the TP ceiling is exactly
   `TP_ceiling - measured_TP`, in either direction.
   - If a file's desired gain exceeds its TP headroom, that file is the
     constraint. **Toggle between two behaviors** (decided — see Decisions):
     lower the whole batch's target LUFS until every file fits, surfacing
     which file forced it; or let that one file fall short/flag it and leave
     the rest at the confirmed target.
   - No limiting/compression in v1 — gain-only. See "Limiter-assisted
     leveling" below for the bigger version of this idea.

## Frequency response comparison

- Goal is a QC signal ("how close are these, really"), not a fix.
- Forward FFT only for v1 — no iFFT needed for pure analysis/display.
- Per file: compute a long-term average spectrum (windowed/STFT, averaged
  over the whole file), likely banded to 1/3-octave for a readable overlay
  rather than raw bin-by-bin noise.
- Display as overlaid curves across the batch, log-frequency axis. Optional:
  flag per-file/per-band outliers relative to the batch average (e.g. "Track
  4 is +3dB in the 2-5kHz band vs. the rest of the album").
- Corrective spectral matching (actually adjusting a file's tonal balance,
  which would need iFFT resynthesis) is explicitly **out of scope** — a
  separate, higher-risk feature to consider only if this becomes real.

## Limiter-assisted leveling (bigger feature, later)

Static gain is capped by a file's own crest factor — headroom to the TP
ceiling is whatever it is, and gain-only leveling can't create more. Hosting
a real limiter in the processing path would let a file be pushed louder than
plain gain allows, as long as the limiter's own output still respects the TP
ceiling (a good true-peak-aware limiter is doing exactly that job).

- **Audio Unit (AU), not VST3, for the hosting target.** AVFoundation/
  AudioToolbox have first-class native APIs for hosting AU plugins on macOS
  (`AVAudioUnitComponent` discovery, `AUAudioUnit` instantiation,
  `AVAudioEngine.attach`, offline rendering for batch/file-based processing).
  VST3 has no equivalent native hosting path — it would mean linking
  Steinberg's VST3 SDK directly (C++, its own licensing considerations, much
  heavier lift). Since essentially every major limiter vendor (FabFilter,
  Waves, iZotope, etc.) ships AU alongside VST3 on Mac, AU-only hosting loses
  little real-world capability while staying entirely within Apple's
  supported, sandboxable plugin API.
- Real engineering weight here: browsing/selecting installed AU plugins,
  presenting the plugin's native UI (`requestViewController`), offline
  rendering a file through an inserted AU, latency/lookahead compensation
  from the limiter itself, and plugin state save/recall per project. This is
  a v2+ feature, not a starting point.

## DAW plugin form factor (related idea, longer-term, separate codebase)

A different packaging of the same underlying measurement: instead of a
standalone app that processes a folder of bounced files, an AU/VST3 insert
plugin — informational only, no processing — that sits on tracks inside a
DAW session (Pro Tools, etc.) during mixing/mastering, giving a live
goniometer + LUFS/True-Peak readout per track while still tweaking mixes,
without needing to bounce anything first.

- This would almost certainly be a **separate codebase in JUCE/C++**,
  matching the toolchain already used for the existing VST plugins (the
  Goniometer.cpp/.h this app's own goniometer was ported from) — not the
  Swift/SwiftUI standalone app. The underlying algorithms (BS.1770 loudness
  calculation, True Peak oversampling, the 45°-rotated goniometer math) are
  portable as *math*, even though the code wouldn't be literally shared
  across a Swift app and a JUCE plugin.
- Explicitly a longer-term idea, not scoped further here.

## Reused from Session Prep

- Audio preview player + goniometer — near-verbatim reuse (same real-time
  matrix-mix player, same raw-buffer goniometer tap). Good candidate for
  actually extracting into a shared package between the two apps if both
  end up maintained long-term, rather than copy-pasting.
- Folder drop / scan / recursive audio file discovery.
- Sparkle auto-update, same appcast + unified `YY.MM.Dxx` version scheme.
- Main table UI — extend rather than replace: add Integrated LUFS, max
  Momentary, True Peak, and suggested-gain columns; repurpose the
  True Stereo/Mono/Dual Mono tag column as the "Target" marker.

## Decisions (resolved)

1. **Target philosophy** — ship as selectable modes (flagged reference
   track, batch average, loudest-file-anchor, fixed external standard)
   rather than picking a single hard-coded default.
2. **TP-constrained file handling** — a toggle: lower the whole batch's
   target so everyone matches, or leave that one file flagged/short while
   the rest hit the confirmed target. Not a fixed default either way.
3. **Momentary/Short-term display** — max-value summary stats in the table
   only, no per-file loudness-history graph. A history view makes sense for
   one song at a time, but is too messy for comparing a whole batch at once.
4. **"Folder" mental model** — just a folder, order not inferred or forced.
   If files are named `1- song 1`, `2- song 2`, etc., that ordering is
   whatever the user intended — the tool shouldn't try to be clever about
   it. (Track sequencing raised a related but genuinely different idea — see
   "Raised but not yet scoped" below.)
5. **Writes files** — yes, same shape as Session Prep: measure, propose,
   confirm, then apply and write.
6. **Output format policy** — same as Session Prep: WAV only, no other
   containers expected at this stage. Existing BEXT metadata must be
   *retained* through the gain-processing pipeline, not fabricated — same
   principle Session Prep already follows (never inventing BEXT data), just
   applied to preserving what's already there rather than not creating new).
7. **True Peak default** — **-0.7 dBTP**, user-editable. But the editable
   range itself should be hard-capped: **-0.1 dBTP is the maximum the field
   will ever allow**, even though 0.0 dBTP mastering is common practice for
   some engineers. This is a deliberate product stance, not an oversight —
   the app should not be a tool that enables true 0 dBTP masters.
8. **Whole-album-as-one-programme LUFS** — nice-to-have as an on-demand
   button/computation, not part of the default starting display.

## Raised but not yet scoped

- **Track-to-track level continuity.** How loud does track N start relative
  to how track N-1 ends? A genuinely different measurement from each
  track's overall Integrated LUFS — more about the *transition* than the
  file as a whole. Worth thinking about separately if/when sequencing
  matters (e.g. a gapless album), not part of the core leveling logic above.
