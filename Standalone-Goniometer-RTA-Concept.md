# Standalone Goniometer + RTA (working idea) — Concept Doc

Status: **idea capture only** — nothing built, nothing scheduled. Distinct
from Session Close — this is a real-time monitoring tool, not a batch file
processor. Captured for a teaching context (students), not mastering
production use.

## One-line pitch

A standalone app that taps whatever audio is currently playing on the Mac
(e.g. out of Pro Tools) and shows it live: goniometer, high-resolution RTA
(spectrum analyzer) with good low-frequency detail, and a loudness meter
(K-System and/or LUFS). Built for teaching — clarity over density.

## Capturing the audio stream

The stated problem — "hard with Pro Tools" — has two real approaches on
macOS:

- **Core Audio process taps** (`AudioHardwareCreateProcessTap` /
  `CATapDescription`), introduced in macOS 14.2, refined in 14.4. Lets you
  tap a specific process's (or the whole system's) audio output directly,
  fed into an aggregate device, without installing a virtual driver. Needs
  audio-recording permission from the user as of 14.4. This is the more
  elegant path if the target OS version is comfortably 14.4+.
- **Virtual loopback driver** (e.g. BlackHole-style) — the long-standing,
  universally compatible fallback. Requires the user to install a driver and
  route Pro Tools' output to it, more setup friction, but works across a
  wider OS range and has years of real-world reliability behind it.

Worth confirming current minimum-macOS-version target before committing to
one approach over the other — the process-tap API is the nicer answer if
14.4+ is an acceptable floor.

## Goniometer

Same 45°-rotated Lissajous approach as Session Prep's, but live from the
captured stream instead of a decoded file — the real-time-safety lessons
already learned there (lock only around bulk copies, never per-sample;
strong `self` capture in the render path; careful RunLoop mode for the
display timer) carry over directly.

## RTA (spectrum analyzer)

- **High-resolution, with good low-frequency detail specifically — MTW
  (Multiple Time Window) FFT is the confirmed approach.** A single
  fixed-size FFT trades resolution against latency — a window long enough
  for fine low-end resolution gets slow to update. MTW runs several window
  lengths in parallel (short windows for highs, long windows for lows) and
  stitches the results together, which is how pro analysis tools (Smaart,
  SIM3, and similar) and analyzer plugins get detailed bass resolution
  without sluggish overall response.
- **Peak with peak-hold-and-fallback** — standard RTA convention: track each
  band's peak, hold the indicator, then decay it at a defined rate.
- **RMS/average line or fill, alongside the peak line** — the averaged
  (time-smoothed) spectrum shown together with the instantaneous peak, the
  usual pairing in pro RTAs.
- **Channel/summation options**: L / R / Mid / Side / a plain stereo
  sum distinct from Mid. Worth being precise here when this gets built —
  "Mid" in an M/S context is typically a scaled derivation (e.g. `(L+R)/2`
  or `(L+R)/√2` depending on convention), which is a different thing from a
  plain unscaled mono fold-down (`L+R`), even though the two are easy to
  conflate. Decide the exact convention for each option explicitly rather
  than assuming they're interchangeable.
- **Reference noise: white vs. pink, confirmed requirement.** Built-in
  generator for both, usable as a test signal and/or an overlay reference
  curve on the RTA display itself.
  - **White noise** — equal energy per Hz (flat power spectral density).
    On a log-frequency RTA, this reads as a curve rising at +3 dB/octave —
    a genuinely useful teaching moment on its own (why "equal energy" isn't
    "flat-looking" once the display is log-frequency).
  - **Pink noise** — equal energy per octave (-3 dB/octave power spectral
    density). Reads as flat on a log-frequency RTA — the standard reference
    for room/speaker response checks, and the one most students will
    associate with "reference noise."
  - Other reference signals (e.g. brown/red noise, a house-curve/target
    overlay) are open — flagged as possible additions, not committed to.

## Loudness meter

- **K-System metering** (Bob Katz's K-12/K-14/K-20 reference scales) and/or
  a **LUFS meter** — both are candidates, not mutually exclusive. Worth
  deciding whether one is primary and the other secondary, or both are
  simultaneously visible.

## Audience shapes the priorities

Built for students, not for the user's own mastering work — favors clarity
and pedagogical value (e.g. being able to point at the goniometer and
explain stereo correlation, or at the RTA and explain spectral balance)
over power-user density. Worth keeping in mind if this and Session Close's
metering ever get compared for feature parity — they're optimizing for
different things.

## Relationship to other ideas in this project

- Shares DNA with Session Close's proposed DAW-plugin form factor (both are
  "live readout" tools rather than batch/offline ones), but this one is
  system-audio-capture-based and standalone, not a DAW insert plugin. Worth
  revisiting whether these end up as one product or two once either gets
  closer to real scoping.
