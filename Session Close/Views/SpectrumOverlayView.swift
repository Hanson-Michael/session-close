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
    /// emptying the set falls back to `.all`). `.averageOnly` hides every
    /// file line entirely, showing just the average curve on its own.
    private enum ViewState: Equatable {
        case all
        case isolated(Set<AudioFileRecord.ID>)
        case averageOnly
    }
    @State private var viewState: ViewState = .all

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

    /// Applies the current pink/white reference to a raw spectrum for
    /// display only — see SpectrumReference's doc comment. A no-op for
    /// .white (returns values unchanged).
    private func displayed(_ spectrum: [Double]) -> [Double] {
        guard settings.spectrumReference == .pink else { return spectrum }
        let correction = SpectrumAnalyzer.pinkReferenceCorrectionDB
        return spectrum.enumerated().map { i, value in
            value + (i < correction.count ? correction[i] : 0)
        }
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
        case .averageOnly: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Batch Spectral QC")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Long-term averaged spectrum per file, banded to 1/12-octave. A QC signal, not a fix — nothing here changes a file's tone.")
                .font(.caption)
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
        .frame(width: 700, height: 560)
        // Esc still closes the sheet via the system default; this button is
        // the visible, discoverable way to do the same thing.
    }

    // MARK: Controls

    /// Batch Average swatch/toggle + the two quick-action buttons. Kept
    /// separate from the per-file legend grid below since "the average"
    /// isn't a file and deserves its own visual slot.
    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                viewState = (viewState == .averageOnly) ? .all : .averageOnly
            } label: {
                HStack(spacing: 5) {
                    Rectangle().fill(Color.primary).frame(width: 14, height: 2)
                    Text("Batch Average").font(.caption.bold())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(viewState == .averageOnly ? Color.accentColor.opacity(0.18) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .help("Show only the batch average, hiding every file's curve")

            Divider().frame(height: 16)

            Button("Show All") { viewState = .all }
                .font(.caption)
                .disabled(viewState == .all)

            Spacer()

            if isIsolating {
                Text("Click a file to add/remove it from the comparison.")
                    .font(.caption)
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
                    Text(settings.spectrumReference == .pink ? "Pink" : "White")
                        .font(.caption.bold())
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
        }
    }

    // MARK: Chart

    private var chart: some View {
        GeometryReader { geo in
            let bandCount = SpectrumAnalyzer.bandCenterFrequenciesHz.count
            let allValues = spectraByRecord.flatMap(\.spectrum) + (average ?? [])
            let maxDB = (allValues.max() ?? 0) + 3
            let minDB = (allValues.min() ?? -60) - 3

            Canvas { context, size in
                let plotRect = CGRect(x: 40, y: 8, width: size.width - 50, height: size.height - 30)

                drawGrid(context: &context, rect: plotRect, minDB: minDB, maxDB: maxDB, bandCount: bandCount)

                if viewState != .averageOnly {
                    for (record, spectrum) in spectraByRecord {
                        let visible = isFileVisible(record.id)
                        let color = colorFor(record.id)
                        var path = Path()
                        for (i, value) in spectrum.enumerated() {
                            let point = plotPoint(bandIndex: i, bandCount: bandCount, value: value, rect: plotRect, minDB: minDB, maxDB: maxDB)
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        // Plain, solid traces — no per-band outlier dots
                        // cluttering the line. Slightly heavier/more opaque
                        // than before so a visible (non-dimmed) file reads
                        // as a clean line closer to the average's own
                        // weight, just still clearly thinner/colored so the
                        // average stands out as the reference curve.
                        context.stroke(path, with: .color(color.opacity(visible ? 0.9 : 0.08)), lineWidth: 1.5)
                    }
                }

                if let average {
                    var path = Path()
                    for (i, value) in average.enumerated() {
                        let point = plotPoint(bandIndex: i, bandCount: bandCount, value: value, rect: plotRect, minDB: minDB, maxDB: maxDB)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(.primary.opacity(0.8)), lineWidth: 2)
                }
            }
        }
        .frame(minHeight: 260)
    }

    private func plotPoint(bandIndex: Int, bandCount: Int, value: Double, rect: CGRect, minDB: Double, maxDB: Double) -> CGPoint {
        let x = rect.minX + rect.width * CGFloat(bandIndex) / CGFloat(max(1, bandCount - 1))
        let normalized = (value - minDB) / max(1, (maxDB - minDB))
        let y = rect.maxY - rect.height * CGFloat(normalized)
        return CGPoint(x: x, y: y)
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect, minDB: Double, maxDB: Double, bandCount: Int) {
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
            context.draw(Text(target.label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x, y: rect.maxY + 10))
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
            context.draw(Text("\(Int(db))").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: rect.minX - 16, y: y))
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
            HStack(spacing: 4) {
                Circle().fill(colorFor(record.id)).frame(width: 7, height: 7)
                Text(record.filename).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
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
            viewState = set.isEmpty ? .all : .isolated(set)
        case .all, .averageOnly:
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
