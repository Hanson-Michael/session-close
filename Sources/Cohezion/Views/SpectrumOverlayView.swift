import SwiftUI

/// Batch spectral QC overlay (see Session-Close-Concept.md "Frequency
/// response comparison") — a "how close are these, really" signal, not a
/// fix. Overlaid 1/12-octave curves across the batch on a log-frequency
/// axis, the batch average drawn bold, and per-file/per-band outliers
/// (deviation from the average at or above the configured threshold)
/// picked out in the accent color. Corrective spectral matching is
/// explicitly out of scope — this view only ever displays.
struct SpectrumOverlayView: View {
    let records: [AudioFileRecord]
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    /// What's currently isolated against the batch average. `.all` shows
    /// every file at full visibility (the default). `.isolated(set)` shows
    /// only the files in `set` (multi-select — click toggles membership,
    /// emptying the set falls back to `.all`).
    private enum ViewState: Equatable {
        case all
        case isolated(Set<AudioFileRecord.ID>)
    }
    // Starts with every file dimmed into the background (an explicit empty
    // isolation set) and just the batch average showing — clicking a file
    // in the legend brings its curve up one at a time. .all (every trace at
    // full visibility) is now something you opt into via the Show All
    // button, not the default.
    @State private var viewState: ViewState = .isolated([])

    /// Independent of `viewState` — whether the bold batch-average curve
    /// itself is drawn. Used to be entangled with `ViewState.averageOnly`
    /// (which also force-hid every file trace), but the average line and
    /// "which files are visible" are two separate questions; this toggle
    /// only answers the first one.
    @State private var showBatchAverage: Bool = true

    /// When on, every *file* curve is shifted so its 1kHz-band value
    /// matches the batch average's 1kHz value — not literal 0 dB, and not
    /// each curve's own independent reference. The average is the shared
    /// anchor and, by construction, never moves (its own distance from
    /// itself is always zero) — only individual files shift to land on it
    /// at 1kHz. That cancels out overall level differences between
    /// files/mixes entirely, leaving only each one's tonal *shape* for
    /// comparison, while the average stays put as a stable visual
    /// reference for actual level too — a file that's just low in level
    /// but otherwise tonally matched will visibly slide inline with the
    /// average rather than everything jumping to a shared 0 dB line.
    /// Meant for batches that are already close in loudness (e.g.
    /// finished mixes leveled to the same target), where the raw dBFS
    /// view's level differences can otherwise dominate the picture and
    /// make shape-only problem spots harder to spot.
    @State private var alignToReference: Bool = false

    /// Raw cursor position within the chart's local coordinate space,
    /// updated on every `.onContinuousHover` event — drives the crosshair,
    /// which should track the mouse at full speed. `nil` whenever the
    /// cursor isn't hovering the chart at all.
    @State private var hoverLocation: CGPoint?

    /// Cursor readout (Hz / musical note / dB / delta vs. the batch
    /// average) shown in the header — unlike `hoverLocation`, this is
    /// deliberately throttled (see `readoutThrottleInterval`) rather than
    /// updated on every hover event, since numbers refreshing that fast
    /// read as flickery rather than useful. `nil` whenever the cursor
    /// isn't hovering the chart's plot area.
    @State private var hoverReadout: SpectrumReadout?

    /// Last time `hoverReadout` actually refreshed — paired with
    /// `readoutThrottleInterval` to cap the text update rate.
    @State private var lastReadoutUpdate: Date = .distantPast

    /// How often the header's Hz/note/dB text is allowed to refresh while
    /// hovering — `.onContinuousHover` fires on essentially every pixel of
    /// mouse movement, far faster than the text is useful to read at.
    private static let readoutThrottleInterval: TimeInterval = 0.08

    private struct SpectrumReadout {
        let hz: Double
        let db: Double
        /// How far `db` is above/below the batch average's value at this
        /// same frequency band — `nil` when there's no average to compare
        /// against yet (no spectral data) or the Batch Average trace is
        /// currently toggled off (see `showBatchAverage`).
        let deltaVsAverageDB: Double?
    }

    /// Index of the band whose center frequency is closest to 1kHz — the
    /// alignment toggle's reference point. Computed from the shared band
    /// table (not hardcoded) so it stays correct if bandsPerOctave
    /// (SpectrumAnalyzer) ever changes.
    private var referenceBandIndex: Int? {
        SpectrumAnalyzer.bandCenterFrequenciesHz.enumerated()
            .min(by: { abs($0.element - 1000) < abs($1.element - 1000) })?.offset
    }

    /// Raw (white-referenced) per-file spectra, as measured — unaffected by
    /// the pink/white display toggle below.
    private var rawSpectraByRecord: [(record: AudioFileRecord, spectrum: [Double])] {
        records.compactMap { record in
            guard let spectrum = record.spectrumBandsDB else { return nil }
            return (record, spectrum)
        }
    }

    private var rawAverage: [Double]? {
        SpectrumAnalyzer.batchAverage(rawSpectraByRecord.map(\.spectrum))
    }

    /// Applies just the current pink/white reference correction — no
    /// alignment shift. Factored out of `displayed(_:)` so the alignment
    /// anchor below can read the batch average's reference-corrected 1kHz
    /// value directly, without going through `displayed` itself (which
    /// would be circular, since `average` is `rawAverage.map(displayed)`).
    private func referenced(_ spectrum: [Double]) -> [Double] {
        guard settings.spectrumReference == .pink else { return spectrum }
        let correction = SpectrumAnalyzer.pinkReferenceCorrectionDB
        return spectrum.enumerated().map { i, value in
            value + (i < correction.count ? correction[i] : 0)
        }
    }

    /// The batch average's own reference-corrected 1kHz-band value — the
    /// shared anchor every curve is aligned against when Align to 1kHz is
    /// on (see `alignToReference`'s doc comment). Reads `rawAverage`
    /// directly rather than the `average` computed property to avoid the
    /// same circularity `referenced(_:)` avoids.
    private var alignmentAnchorDB: Double? {
        guard let refIndex = referenceBandIndex, let rawAvg = rawAverage, refIndex < rawAvg.count else { return nil }
        return referenced(rawAvg)[refIndex]
    }

    /// Applies the current pink/white reference, then — if the 1kHz
    /// alignment toggle is on — shifts the result so its 1kHz-band value
    /// matches `alignmentAnchorDB` (the batch average's own 1kHz value,
    /// not literal 0 dB). The two corrections compose independently:
    /// pink/white reshapes the *reference tilt* everyone's compared
    /// against, alignment then removes each curve's own overall level
    /// relative to the average on top of that. Applied identically to
    /// every file's spectrum and to the batch average itself — for the
    /// average, the shift always works out to zero, since its distance
    /// from its own anchor is zero by definition, so it never visibly
    /// moves.
    private func displayed(_ spectrum: [Double]) -> [Double] {
        var result = referenced(spectrum)
        if alignToReference, let refIndex = referenceBandIndex, let anchor = alignmentAnchorDB, refIndex < result.count {
            let offset = result[refIndex] - anchor
            result = result.map { $0 - offset }
        }
        return result
    }

    /// Display-corrected per-file spectra actually plotted in the chart.
    private var spectraByRecord: [(record: AudioFileRecord, spectrum: [Double])] {
        rawSpectraByRecord.map { (record: $0.record, spectrum: displayed($0.spectrum)) }
    }

    /// Display-corrected batch average actually plotted in the chart.
    private var average: [Double]? {
        rawAverage.map(displayed)
    }

    private var isIsolating: Bool {
        if case .isolated = viewState { return true }
        return false
    }

    private func isFileVisible(_ id: AudioFileRecord.ID) -> Bool {
        switch viewState {
        case .all: return true
        case .isolated(let set): return set.contains(id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Batch Spectral QC")
                    .font(.title2.bold())
                Spacer()
                cursorReadoutText
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Long-term averaged spectrum per file, banded to 1/12-octave, calibrated to true dBFS. A QC signal, not a fix — nothing here changes a file's tone.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if spectraByRecord.isEmpty {
                Text("No spectral data yet — scan a folder first.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
                controlsRow
                Divider()
                legendGrid
            }
        }
        .padding(20)
        .frame(width: 1000, height: 780)
        // Esc still closes the sheet via the system default; this button is
        // the visible, discoverable way to do the same thing.
    }

    /// Big, centered Hz / note / dB readout that tracks the cursor while
    /// it's over the chart — reserves a fixed-height row even when empty
    /// so the header doesn't reflow as the mouse enters/leaves the chart.
    /// Monospaced so the digits don't visibly jitter in width as the
    /// cursor moves.
    @ViewBuilder
    private var cursorReadoutText: some View {
        Group {
            if let hoverReadout {
                let base = "\(formattedHz(hoverReadout.hz))   ·   \(Self.noteName(forHz: hoverReadout.hz))   ·   \(String(format: "%.1f dB", hoverReadout.db))"
                if let delta = hoverReadout.deltaVsAverageDB {
                    Text(base + String(format: "   ·   %+.1f dB vs BA", delta))
                } else {
                    Text(base)
                }
            } else {
                Text(" ")
            }
        }
        .font(.system(.title2, design: .monospaced).bold())
        .foregroundColor(.secondary)
    }

    private func formattedHz(_ hz: Double) -> String {
        String(format: "%.0f Hz", hz)
    }

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Nearest musical note (12-tone equal temperament, A4 = 440Hz) for a
    /// given frequency — standard MIDI-number formula, rounded to the
    /// nearest semitone.
    private static func noteName(forHz hz: Double) -> String {
        guard hz > 0 else { return "—" }
        let midi = Int((69 + 12 * log2(hz / 440)).rounded())
        let octave = midi / 12 - 1
        let index = ((midi % 12) + 12) % 12
        return "\(noteNames[index])\(octave)"
    }

    // MARK: Controls

    /// Shared active/inactive background for the toggle-style chip buttons
    /// (Batch Average, Align to 1kHz). A translucent accent-color fill on
    /// its own read as nearly invisible in dark mode, and too subtle in
    /// light mode — adding a full-opacity accent stroke ring on top of a
    /// slightly stronger fill keeps the "on" state clearly legible in both.
    private func chipBackground(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(active ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
    }

    /// Batch Average swatch/toggle + the two quick-action buttons. Kept
    /// separate from the per-file legend grid below since "the average"
    /// isn't a file and deserves its own visual slot.
    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                showBatchAverage.toggle()
            } label: {
                HStack(spacing: 5) {
                    Rectangle().fill(Color.primary).frame(width: 14, height: 2)
                    Text("Batch Average").font(.subheadline.bold())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(chipBackground(active: showBatchAverage))
            }
            .buttonStyle(.plain)
            .help("Show or hide the batch average curve, independent of which files' traces are visible")

            Divider().frame(height: 16)

            // Single toggle, not disabled-when-already-shown — mirrors the
            // Pink/White toggle's shape. From .all, hides every file trace
            // (an explicit empty isolation set — the batch average toggle
            // above is fully independent and keeps drawing regardless of
            // this state). From any isolated state, it jumps straight back
            // to showing everything.
            Button {
                viewState = (viewState == .all) ? .isolated([]) : .all
            } label: {
                Text(viewState == .all ? "Hide All" : "Show All")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Show or hide every file's curve at once.")

            Spacer()

            if isIsolating {
                Text("Click a file to add/remove it from the comparison.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider().frame(height: 16)

            // Single toggle, not two separate buttons — click cycles
            // pink↔white. See SpectrumReference's doc comment for what the
            // two modes mean.
            Button {
                settings.spectrumReference = (settings.spectrumReference == .pink) ? .white : .pink
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .bold))
                    // Fixed width, left-aligned — "Pink" and "White" are
                    // different lengths, and without a fixed width the
                    // button (and everything laid out relative to it) would
                    // shift horizontally every time you switch, which was
                    // dragging the "Click a file…" hint around with it.
                    Text(settings.spectrumReference == .pink ? "Pink" : "White")
                        .font(.subheadline.bold())
                        .frame(width: 40, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help("Reference: Pink (flat for typical music) or White (flat for white noise). Click to switch.")

            Divider().frame(height: 16)

            // Composes with Pink/White (applied after it in `displayed(_:)`)
            // rather than replacing it — you can align *and* pick a tilt
            // reference at the same time.
            Button {
                alignToReference.toggle()
            } label: {
                Text("Align to 1kHz")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(chipBackground(active: alignToReference))
            }
            .buttonStyle(.plain)
            .help("Shift every file's curve to match the batch average's level at 1kHz instead of literal 0 dB — the average itself never moves, only the other curves slide to meet it. Useful when comparing mixes that are already close in loudness.")
        }
    }

    // MARK: Chart

    // Fixed Y-axis range rather than auto-fit from whatever's plotted (a
    // real zoom/pan feature is a separate, not-yet-built backlog item —
    // this is just a fixed default range for now). Depends only on the
    // Pink/White reference — white noise's flat-per-Hz (not flat-per-
    // octave) spectrum reads much lower at the top end than pink, so it
    // needs a taller window to avoid clipping a normal-looking curve.
    // Align to 1kHz does NOT change these bounds: since the average curve
    // is the alignment anchor and never moves (see `alignmentAnchorDB`),
    // every curve stays in the same absolute dBFS domain the axis is
    // already in — only the axis *labels* change when aligned (see
    // `drawGrid`'s `labelReferenceDB`), not the bounds themselves.
    private var axisRange: (minDB: Double, maxDB: Double) {
        switch settings.spectrumReference {
        case .pink: return (-60, -10)
        case .white: return (-90, -10)
        }
    }

    /// Shared between the Canvas drawing closure and the hover-readout math
    /// below, so the two stay in lockstep — the readout has to invert
    /// exactly the same rect the traces are plotted against, or the cursor
    /// and what it reports would drift apart.
    private func plotRect(for size: CGSize) -> CGRect {
        CGRect(x: 48, y: 8, width: size.width - 60, height: size.height - 36)
    }

    /// Cursor X → nearest band index, shared by the readout math below and
    /// the crosshair's vertical line (so the line snaps to exactly the
    /// band the readout is reporting, not just wherever the pixel is).
    private func bandIndex(forX x: CGFloat, in rect: CGRect, bandCount: Int) -> Int {
        let fraction = Double((x - rect.minX) / rect.width)
        let rawIndex = fraction * Double(max(1, bandCount - 1))
        return min(max(Int(rawIndex.rounded()), 0), bandCount - 1)
    }

    /// Inverts `plotPoint`'s mapping: cursor position → nearest band's Hz
    /// (for the note-name lookup too) and → dB against whichever axis
    /// range is currently active, plus the delta against the batch
    /// average's value at that same band (see `SpectrumReadout`). `nil`
    /// outside the plot rect itself (the chart's frame includes label
    /// margins around it where a readout wouldn't correspond to anything
    /// on the grid).
    private func readout(at location: CGPoint, size: CGSize, bandCount: Int, minDB: Double, maxDB: Double) -> SpectrumReadout? {
        let rect = plotRect(for: size)
        guard rect.contains(location), rect.width > 0, rect.height > 0 else { return nil }

        let index = bandIndex(forX: location.x, in: rect, bandCount: bandCount)
        let hz = SpectrumAnalyzer.bandCenterFrequenciesHz[index]

        let normalized = Double((rect.maxY - location.y) / rect.height)
        let db = minDB + normalized * (maxDB - minDB)

        var deltaVsAverageDB: Double?
        if showBatchAverage, let average, index < average.count {
            deltaVsAverageDB = db - average[index]
        }

        return SpectrumReadout(hz: hz, db: db, deltaVsAverageDB: deltaVsAverageDB)
    }

    private var chart: some View {
        GeometryReader { geo in
            let bandCount = SpectrumAnalyzer.bandCenterFrequenciesHz.count
            let maxDB = axisRange.maxDB
            let minDB = axisRange.minDB

            Canvas { context, size in
                let plotRect = plotRect(for: size)

                // When aligned, labels read relative to the batch
                // average's 1kHz value (the alignment anchor) instead of
                // absolute dBFS — e.g. if the average's 1kHz value is
                // -30dB on Pink (-60...-10 axis), the top gridline (-10
                // absolute) labels as "+20" and the bottom (-60 absolute)
                // as "-30". The gridlines' actual Y positions are
                // unaffected, still every 10dB in absolute terms.
                drawGrid(context: &context, rect: plotRect, minDB: minDB, maxDB: maxDB, bandCount: bandCount, labelReferenceDB: alignToReference ? alignmentAnchorDB : nil)

                // Grid/labels are drawn above, so this only affects the
                // traces below — a fixed axis range means a value outside
                // minDB...maxDB would otherwise plot past the grid
                // entirely; clip it to the plot rect instead of letting it
                // bleed into the rest of the window.
                context.clip(to: Path(plotRect))

                for (record, spectrum) in spectraByRecord {
                    let visible = isFileVisible(record.id)
                    let color = colorFor(record.id)
                    let points = spectrum.enumerated().map { i, value in
                        plotPoint(bandIndex: i, bandCount: bandCount, value: value, rect: plotRect, minDB: minDB, maxDB: maxDB)
                    }
                    let path = smoothPath(through: points)
                    // Plain, solid traces — no per-band outlier dots
                    // cluttering the line. Slightly heavier/more opaque
                    // than before so a visible (non-dimmed) file reads
                    // as a clean line closer to the average's own
                    // weight, just still clearly thinner/colored so the
                    // average stands out as the reference curve.
                    context.stroke(path, with: .color(color.opacity(visible ? 0.9 : 0.08)), lineWidth: 1.5)
                }

                if showBatchAverage, let average {
                    let points = average.enumerated().map { i, value in
                        plotPoint(bandIndex: i, bandCount: bandCount, value: value, rect: plotRect, minDB: minDB, maxDB: maxDB)
                    }
                    let path = smoothPath(through: points)
                    context.stroke(path, with: .color(.primary.opacity(0.8)), lineWidth: 2)
                }

                // Crosshair — drawn last so it sits on top of every trace.
                // Vertical line snaps to the same band the text readout is
                // reporting (matches `readout(at:...)`'s band lookup);
                // horizontal line follows the raw cursor Y so it points at
                // exactly the dB value being read out, not a rounded one.
                if let hoverLocation, plotRect.contains(hoverLocation) {
                    let index = bandIndex(forX: hoverLocation.x, in: plotRect, bandCount: bandCount)
                    let snappedX = plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(max(1, bandCount - 1))
                    let crosshairStyle = StrokeStyle(lineWidth: 1, dash: [4, 3])
                    var vertical = Path()
                    vertical.move(to: CGPoint(x: snappedX, y: plotRect.minY))
                    vertical.addLine(to: CGPoint(x: snappedX, y: plotRect.maxY))
                    context.stroke(vertical, with: .color(.secondary.opacity(0.7)), style: crosshairStyle)

                    var horizontal = Path()
                    horizontal.move(to: CGPoint(x: plotRect.minX, y: hoverLocation.y))
                    horizontal.addLine(to: CGPoint(x: plotRect.maxX, y: hoverLocation.y))
                    context.stroke(horizontal, with: .color(.secondary.opacity(0.7)), style: crosshairStyle)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    // Crosshair tracks every event for smooth motion; the
                    // text readout only refreshes at most every
                    // readoutThrottleInterval (except the very first
                    // event, so it doesn't feel laggy when you first move
                    // onto the chart).
                    hoverLocation = location
                    let now = Date()
                    if hoverReadout == nil || now.timeIntervalSince(lastReadoutUpdate) >= Self.readoutThrottleInterval {
                        hoverReadout = readout(at: location, size: geo.size, bandCount: bandCount, minDB: minDB, maxDB: maxDB)
                        lastReadoutUpdate = now
                    }
                case .ended:
                    hoverLocation = nil
                    hoverReadout = nil
                }
            }
        }
        .frame(minHeight: 420)
    }

    private func plotPoint(bandIndex: Int, bandCount: Int, value: Double, rect: CGRect, minDB: Double, maxDB: Double) -> CGPoint {
        let x = rect.minX + rect.width * CGFloat(bandIndex) / CGFloat(max(1, bandCount - 1))
        let normalized = (value - minDB) / max(1, (maxDB - minDB))
        let y = rect.maxY - rect.height * CGFloat(normalized)
        return CGPoint(x: x, y: y)
    }

    /// Smooths a polyline into a curve through every point (a proper
    /// interpolating spline, not an approximating one — the curve still
    /// hits each band-center value exactly). Catmull-Rom → cubic Bezier is
    /// the standard conversion: each segment's control points are derived
    /// from its neighbors with the usual 1/6-tension formula, using edge
    /// points as their own neighbor at the ends. Pure rendering — doesn't
    /// touch the underlying banded measurement data.
    private func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }

    /// `labelReferenceDB`, when non-nil, relabels the dB gridlines relative
    /// to that value instead of showing absolute dBFS — used when Align to
    /// 1kHz is on, passing the batch average's 1kHz value so the labels
    /// read as "distance from the average" rather than raw dBFS. Purely a
    /// label change: gridline Y-positions are always computed from the
    /// absolute `db`, in the same fixed 10dB steps either way.
    private func drawGrid(context: inout GraphicsContext, rect: CGRect, minDB: Double, maxDB: Double, bandCount: Int, labelReferenceDB: Double? = nil) {
        let gridColor = Color.secondary.opacity(0.2)
        // Looked up by nearest actual center frequency rather than a fixed
        // index — the band table's size depends on bandsPerOctave
        // (SpectrumAnalyzer), so hardcoded indices would silently drift out
        // of place if that ever changes again.
        let labelTargets: [(hz: Double, label: String)] = [(20, "20"), (200, "200"), (1000, "1k"), (5000, "5k"), (20000, "20k")]
        for target in labelTargets {
            guard let index = SpectrumAnalyzer.bandCenterFrequenciesHz.enumerated()
                .min(by: { abs($0.element - target.hz) < abs($1.element - target.hz) })?.offset else { continue }
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(max(1, bandCount - 1))
            var line = Path()
            line.move(to: CGPoint(x: x, y: rect.minY))
            line.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)
            context.draw(Text(target.label).font(.system(size: 12)).foregroundColor(.secondary), at: CGPoint(x: x, y: rect.maxY + 13))
        }

        let dbStep = 10.0
        var db = ceil(minDB / dbStep) * dbStep
        while db <= maxDB {
            let normalized = (db - minDB) / max(1, (maxDB - minDB))
            let y = rect.maxY - rect.height * CGFloat(normalized)
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(line, with: .color(gridColor), lineWidth: 1)
            let label: String
            if let labelReferenceDB {
                let relative = Int((db - labelReferenceDB).rounded())
                label = relative == 0 ? "0" : String(format: "%+d", relative)
            } else {
                label = "\(Int(db))"
            }
            context.draw(Text(label).font(.system(size: 12)).foregroundColor(.secondary), at: CGPoint(x: rect.minX - 20, y: y))
            db += dbStep
        }
    }

    // MARK: Legend

    /// Fixed 4-column grid, fills horizontally (row-major — the same
    /// default LazyVGrid behavior) rather than a long horizontal scroll:
    /// 5 files makes 2 rows, 10 files makes 3 rows, and so on.
    private var legendGrid: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), alignment: .leading, spacing: 6) {
                ForEach(spectraByRecord.map(\.record)) { record in
                    legendRow(for: record)
                }
            }
        }
    }

    private func legendRow(for record: AudioFileRecord) -> some View {
        let selected = isIsolating && isFileVisible(record.id)
        return Button {
            toggleIsolate(record.id)
        } label: {
            HStack(spacing: 5) {
                Circle().fill(colorFor(record.id)).frame(width: 9, height: 9)
                Text(record.filename).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func toggleIsolate(_ id: AudioFileRecord.ID) {
        switch viewState {
        case .isolated(var set):
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            // Stays on .isolated even once the set empties back out —
            // unselecting your last file goes back to "everything dimmed,"
            // not a jump to every trace suddenly appearing.
            viewState = .isolated(set)
        case .all:
            viewState = .isolated([id])
        }
    }

    /// Stable per-record color cycling through a fixed palette — indexed by
    /// position in the batch rather than anything content-derived, so
    /// colors stay put as long as the scan order doesn't change.
    private func colorFor(_ id: AudioFileRecord.ID) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .indigo, .mint, .cyan]
        guard let index = records.firstIndex(where: { $0.id == id }) else { return .gray }
        return palette[index % palette.count]
    }
}
