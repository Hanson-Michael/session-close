import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let sessionCloseOpenFolder = Notification.Name("sessionCloseOpenFolder")
}

struct ContentView: View {
    @State private var folderURL: URL?
    @State private var records: [AudioFileRecord] = []
    @State private var selection: Set<AudioFileRecord.ID> = []
    @State private var sortOrder: [KeyPathComparator<AudioFileRecord>] = []

    // Subfolder navigation — retained from Session Prep even though the
    // scan itself stays top-level-only, per the product decision this app
    // was scoped under: move deeper into an album's subfolders via chips
    // and Cmd+arrow shortcuts rather than scanning recursively.
    @State private var subfolders: [URL] = []
    @State private var highlightedSubfolderIndex: Int?
    @State private var folderHistory: [URL] = []

    @State private var isScanning = false
    @State private var showScanningOverlay = false
    @State private var scanningOverlayWorkItem: DispatchWorkItem?
    /// Real progress (not indeterminate) — a full BS.1770 + FFT pass per
    /// file is genuine CPU work, not a quick metadata read, so a
    /// several-minute album can take a noticeable amount of wall-clock
    /// time even with FolderScanner analyzing files concurrently across
    /// cores. See FolderScanner.scan's onProgress callback.
    @State private var scanProgress: Double = 0
    @State private var isProcessing = false
    @State private var processingProgress: Double = 0

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var previewPlayer = AudioPreviewPlayer.shared
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    @State private var showingProcessOptions = false
    @State private var processOptions = ProcessOptions()
    @State private var isDropTargeted = false
    @State private var processingErrors: [String] = []
    @State private var showingProcessingErrors = false
    @State private var isHoveringFolderPath = false
    @State private var showingSpectrumOverlay = false

    // MARK: Column visibility
    //
    // Both groups start hidden — Format/Bit Depth/Sample Rate/Duration and
    // ST Max/M Max/LRA are useful QC/reference detail, but not what you
    // need to look at to make a leveling decision, so the table opens as
    // lean as possible (Target · Status · Filename · Integrated LUFS ·
    // True Peak · Suggested Gain) and you opt into more via the Columns
    // menu. Session-only state, not persisted — resets to hidden each
    // launch by construction.
    @State private var showLoudnessDetail = false
    @State private var showFileDetail = false

    // MARK: Target / leveling

    /// The proposed-then-editable batch target — seeded from the current
    /// TargetMode on scan/mode-change, freely user-editable afterward (see
    /// Session-Close-Concept.md "Leveling logic" step 4).
    @State private var targetLUFS: Double = -14.0
    @State private var lastForcingRecordID: AudioFileRecord.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                VStack(spacing: 0) {
                    folderBar
                    subfolderBar
                    Divider()
                    targetBar
                    Divider()
                    previewBar
                }
                Divider()
                GoniometerView()
                    .padding(12)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            if records.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            bottomBar
        }
        // Sized for the 6 core columns + Loudness Detail (ST Max 70, M Max
        // 70, LRA 60 = 200pt) — both detail groups still default to hidden
        // (see showFileDetail/showLoudnessDetail), but Loudness Detail is
        // the one worth always having room for without triggering
        // horizontal scroll. File Detail (Format/Bit Depth/Sample
        // Rate/Duration) is wider and less often needed, so turning that
        // one on can still make the table scroll horizontally rather than
        // growing the window to fit every possible combination.
        .frame(minWidth: 1200, minHeight: 780)
        .background {
            subfolderNavigationShortcuts
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .overlay {
            if showScanningOverlay || isProcessing {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    BusyOverlayView(
                        message: isProcessing ? "Communicating with aliens…" : "Communicating with aliens…\nabout Spectrums and Loudness…",
                        progress: isProcessing ? processingProgress : (isScanning ? scanProgress : nil)
                    )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 20)
                }
            }
        }
        .onChange(of: isScanning) { scanning in
            scanningOverlayWorkItem?.cancel()
            if scanning {
                let workItem = DispatchWorkItem { showScanningOverlay = true }
                scanningOverlayWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            } else {
                showScanningOverlay = false
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFolderDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionCloseOpenFolder)) { _ in
            chooseFolder()
        }
        .onChange(of: selection) { _ in
            updatePreviewLoad()
        }
        .onChange(of: settings.targetMode) { _ in refreshProposedTargetAndRecompute() }
        .onChange(of: settings.fixedStandardLUFS) { _ in
            if settings.targetMode == .fixedStandard { refreshProposedTargetAndRecompute() }
        }
        .onChange(of: settings.truePeakCeilingDBTP) { _ in recomputeLeveling() }
        .onChange(of: settings.tpConstraintHandling) { _ in recomputeLeveling() }
        .sheet(isPresented: $showingProcessOptions) {
            ProcessOptionsSheet(
                toLevelCount: toLevelRecords.count,
                targetLUFS: targetLUFS,
                targetModeLabel: settings.targetMode.rawValue,
                options: $processOptions,
                settings: settings,
                onCancel: { showingProcessOptions = false },
                onProcess: {
                    showingProcessOptions = false
                    processSelected(options: processOptions)
                }
            )
        }
        .sheet(isPresented: $showingSpectrumOverlay) {
            SpectrumOverlayView(records: records, settings: settings)
        }
        .alert("Some files couldn't be processed", isPresented: $showingProcessingErrors) {
            Button("OK") {}
        } message: {
            Text(processingErrors.joined(separator: "\n"))
        }
    }

    private func updatePreviewLoad() {
        if let record = selectedSingleRecord, record.channelCount == 1 || record.channelCount == 2 {
            previewPlayer.load(url: record.url)
        } else {
            previewPlayer.unload()
        }
    }

    // MARK: Folder bar

    private var folderBar: some View {
        HStack {
            folderPathControl
            Spacer()
            Menu {
                Toggle("Loudness Detail (ST Max, M Max, LRA)", isOn: $showLoudnessDetail)
                Toggle("File Detail (Format, Bit Depth, Sample Rate, Duration)", isOn: $showFileDetail)
            } label: {
                Label("Columns", systemImage: "slider.horizontal.3")
            }
            .disabled(records.isEmpty)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                showingSpectrumOverlay = true
            } label: {
                Label("Spectrum", systemImage: "waveform.path.ecg")
            }
            .disabled(records.isEmpty)
        }
        .padding(12)
    }

    @ViewBuilder
    private var folderPathControl: some View {
        if let folderURL {
            Button {
                chooseFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundColor(.secondary)
                    Text(folderURL.path)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(isHoveringFolderPath ? 0.08 : 0))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringFolderPath = hovering
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        } else {
            Button {
                chooseFolder()
            } label: {
                Label("Select Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var subfolderBar: some View {
        HStack(spacing: 6) {
            Text("Sub Folders:")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 12)

            Button {
                navigateUp()
            } label: {
                Label("Up", systemImage: "arrow.up")
                    .font(.caption)
            }
            .buttonStyle(folderChipStyle)
            .disabled(folderHistory.isEmpty)
            .opacity(folderHistory.isEmpty ? 0.4 : 1)
            .keyboardShortcut(.upArrow, modifiers: .command)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(subfolders.indices, id: \.self) { index in
                        Button {
                            navigateInto(subfolders[index])
                        } label: {
                            Label(subfolders[index].lastPathComponent, systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(folderChipStyle)
                        .overlay {
                            if highlightedSubfolderIndex == index {
                                Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var folderChipStyle: FolderChipButtonStyle { FolderChipButtonStyle() }

    // MARK: Target bar

    /// Mode picker + the editable proposed target number + a read-only note
    /// on which file forced the target down (only ever populated in
    /// .lowerBatchTarget mode).
    private var targetBar: some View {
        HStack(spacing: 12) {
            Text("Target:")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("", selection: $settings.targetMode) {
                ForEach(TargetMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help(settings.targetMode.helpText)

            HStack(spacing: 4) {
                TextField("", value: $targetLUFS, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit { recomputeLeveling() }
                Text("LUFS")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if settings.targetMode == .referenceTrack, !records.contains(where: { $0.isReferenceTrack }) {
                Text("Click the star on a row to flag a reference track.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if let forcingID = lastForcingRecordID, settings.tpConstraintHandling == .lowerBatchTarget,
               let forcingRecord = records.first(where: { $0.id == forcingID }) {
                Text("Lowered to fit \"\(forcingRecord.filename)\"'s True Peak headroom.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image("WatermarkMark")
                .resizable()
                .frame(width: 128, height: 128)
                .opacity(0.2)
            Text("Select a folder to scan")
                .font(.title3)
            Text("Drag a folder onto this window, or use Select Folder…")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Session Close measures Integrated LUFS, True Peak, and tonal balance for every file in a folder, proposes a batch loudness target, and levels toward it — never past the True Peak ceiling.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Table

    /// Conditionally *including/excluding* a TableColumn inside a single
    /// @TableColumnBuilder body (`if showFileDetail { TableColumn(...) }`)
    /// needs macOS 14.4's TableColumnBuilder.buildOptional — this project
    /// targets 13.5 (matching Session Prep), so that's not available.
    /// Instead: three always-unconditional column groups (coreColumns,
    /// fileDetailColumns, loudnessDetailColumns — see below) get combined
    /// into four complete, statically-built Table instances, and a plain
    /// `@ViewBuilder switch` (ordinary View-level branching, supported
    /// since SwiftUI's original release, unrelated to the 14.4 gap above)
    /// picks the right one for the current toggle state.
    @ViewBuilder
    private var table: some View {
        switch (showFileDetail, showLoudnessDetail) {
        case (false, false):
            Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                coreColumns
            }
        case (true, false):
            Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                coreColumns
                fileDetailColumns
            }
        case (false, true):
            Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                coreColumns
                loudnessDetailColumns
            }
        case (true, true):
            Table(records.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                coreColumns
                fileDetailColumns
                loudnessDetailColumns
            }
        }
    }

    // MARK: Loudest / batch-average row highlighting
    //
    // Purely informational QC markers, distinct from the Target star
    // (which drives .referenceTrack mode) — always on, regardless of which
    // target mode is currently selected. "Average" has no single file that
    // literally *is* the average, so this reads as "closest to the plain
    // batch-average LUFS" (see batchAverageLUFS below for what that number
    // is and its own caveats). Only shown once there's more than one
    // measured file — with a single file, "loudest vs. average" isn't a
    // meaningful distinction.

    private var loudestRecordID: AudioFileRecord.ID? {
        let measured = records.filter { $0.status.isMeasured }
        guard measured.count > 1 else { return nil }
        return measured.max(by: { ($0.integratedLUFS ?? -.infinity) < ($1.integratedLUFS ?? -.infinity) })?.id
    }

    /// Plain arithmetic mean of every measured file's Integrated LUFS — the
    /// exact same number LevelingEngine.proposedTargetLUFS computes for
    /// .batchAverage mode (see that function's doc comment for the
    /// duration/power-weighting caveat flagged for a future revision).
    /// Computed independently here so the highlight stays meaningful even
    /// when a different target mode is actually selected.
    private var batchAverageLUFS: Double? {
        let values = records.compactMap { $0.status.isMeasured ? $0.integratedLUFS : nil }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var closestToAverageRecordID: AudioFileRecord.ID? {
        let measured = records.filter { $0.status.isMeasured }
        guard measured.count > 1, let average = batchAverageLUFS else { return nil }
        return measured.min(by: {
            abs(($0.integratedLUFS ?? .infinity) - average) < abs(($1.integratedLUFS ?? .infinity) - average)
        })?.id
    }

    /// Loudest wins if a file somehow qualifies as both (a very tight
    /// batch) — the True-Peak-risk signal is the more load-bearing one.
    private func rowHighlight(for record: AudioFileRecord) -> Color {
        if record.id == loudestRecordID { return .red.opacity(0.16) }
        if record.id == closestToAverageRecordID { return .green.opacity(0.16) }
        return .clear
    }

    /// SwiftUI's Table (the plain data-driven initializer used here) has no
    /// List-style `.listRowBackground` — there's no single "whole row"
    /// background hook. This fakes it by tinting every column's own cell
    /// with the same color and letting it fill the full cell width, which
    /// reads as a tinted row in practice. Every TableColumn body below
    /// routes through this so the tint lines up across the whole row.
    private func cell<V: View>(_ content: V, for record: AudioFileRecord, alignment: Alignment = .leading) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(rowHighlight(for: record))
    }

    /// Target star · Status · Filename · Integrated LUFS · True Peak ·
    /// Suggested Gain — always visible, the six columns you need to make a
    /// leveling decision. Format/Bit Depth/Sample Rate/Duration and ST
    /// Max/M Max/LRA are their own groups below, folded in or out via the
    /// `table` switch above rather than a conditional inside this builder.
    @TableColumnBuilder<AudioFileRecord, KeyPathComparator<AudioFileRecord>>
    private var coreColumns: some TableColumnContent<AudioFileRecord, KeyPathComparator<AudioFileRecord>> {
        TableColumn("") { record in
            cell(
                Button {
                    toggleReferenceTrack(record)
                } label: {
                    Image(systemName: record.isReferenceTrack ? "star.fill" : "star")
                        .foregroundColor(record.isReferenceTrack ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Flag as the reference track for Reference Track target mode"),
                for: record, alignment: .center
            )
        }
        .width(24)

        TableColumn("Status", value: \.status.label) { record in
            cell(StatusBadge(status: record.status), for: record)
        }
        .width(110)

        TableColumn("Filename", value: \.filename) { record in
            cell(Text(record.filename).lineLimit(1), for: record)
        }
        .width(min: 180, ideal: 260)

        TableColumn("Integrated LUFS", value: \.integratedLUFSSortValue) { record in
            cell(
                Text(record.integratedLUFS.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(110)

        TableColumn("True Peak", value: \.truePeakSortValue) { record in
            cell(
                Text(record.truePeakDBTP.map { String(format: "%.1f dBTP", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(record.status == .tpConstrained ? .orange : .primary),
                for: record
            )
        }
        .width(100)

        TableColumn("Suggested Gain", value: \.suggestedGainSortValue) { record in
            cell(
                Text(record.suggestedGainDB.map { String(format: "%+.1f dB", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(100)
    }

    /// Format · Bit Depth · Sample Rate · Duration — folded in via the
    /// Columns menu's "File Detail" toggle (see `table` above).
    @TableColumnBuilder<AudioFileRecord, KeyPathComparator<AudioFileRecord>>
    private var fileDetailColumns: some TableColumnContent<AudioFileRecord, KeyPathComparator<AudioFileRecord>> {
        TableColumn("Format", value: \.fileExtension) { record in
            cell(Text(record.fileExtension.uppercased()), for: record)
        }
        .width(60)

        TableColumn("Bit Depth", value: \.bitDepthSortValue) { record in
            cell(Text(record.bitDepth.map { "\($0)-bit" } ?? "—"), for: record)
        }
        .width(70)

        TableColumn("Sample Rate", value: \.sampleRate) { record in
            cell(Text(formattedSampleRate(record.sampleRate)), for: record)
        }
        .width(80)

        TableColumn("Duration", value: \.duration) { record in
            cell(Text(formattedDuration(record.duration)), for: record)
        }
        .width(60)
    }

    /// ST Max · M Max · LRA — folded in via the Columns menu's "Loudness
    /// Detail" toggle (see `table` above). Short-Term/Momentary max are
    /// summary stats only (see Session-Close-Concept.md "Decisions #3": no
    /// per-file loudness-history graph in v1), LRA is the bonus stat.
    @TableColumnBuilder<AudioFileRecord, KeyPathComparator<AudioFileRecord>>
    private var loudnessDetailColumns: some TableColumnContent<AudioFileRecord, KeyPathComparator<AudioFileRecord>> {
        TableColumn("ST Max", value: \.shortTermMaxSortValue) { record in
            cell(
                Text(record.shortTermMaxLUFS.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(70)

        TableColumn("M Max", value: \.momentaryMaxSortValue) { record in
            cell(
                Text(record.momentaryMaxLUFS.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(70)

        TableColumn("LRA", value: \.lraSortValue) { record in
            cell(
                Text(record.loudnessRangeLRA.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(60)
    }

    private func toggleReferenceTrack(_ record: AudioFileRecord) {
        guard let idx = records.firstIndex(where: { $0.id == record.id }) else { return }
        let newValue = !records[idx].isReferenceTrack
        for i in records.indices { records[i].isReferenceTrack = false }
        records[idx].isReferenceTrack = newValue
        if settings.targetMode == .referenceTrack {
            refreshProposedTargetAndRecompute()
        }
    }

    // MARK: Preview bar

    private var selectedSingleRecord: AudioFileRecord? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return records.first(where: { $0.id == id })
    }

    private var previewBar: some View {
        let record = selectedSingleRecord
        let canPreview = record != nil && (record!.channelCount == 1 || record!.channelCount == 2)

        return VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    previewPlayer.togglePlayPause()
                } label: {
                    Image(systemName: previewPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPreview)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    previewPlayer.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!canPreview || (!previewPlayer.isPlaying && previewPlayer.currentTime == 0))

                Button {
                    previewPlayer.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .frame(width: 16)
                }
                .foregroundStyle(previewPlayer.isLooping ? Color.accentColor : Color.secondary)
                .disabled(!canPreview)
                .help("Loop")

                Text(record?.filename ?? "Select a file to preview it")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 120, alignment: .leading)

                Spacer(minLength: 8)

                if previewPlayer.sourceChannelCount == 1 {
                    Text("Mono — single channel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 320, height: 22)
                } else {
                    Picker("", selection: $previewPlayer.mode) {
                        ForEach(AudioPreviewPlayer.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320, height: 22)
                    .disabled(!canPreview)
                }
            }
            .frame(height: 22)

            HStack(spacing: 8) {
                Text(formattedDuration(isScrubbing ? scrubTime : previewPlayer.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : previewPlayer.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(previewPlayer.duration, 0.01),
                    onEditingChanged: { editing in
                        if editing { scrubTime = previewPlayer.currentTime }
                        isScrubbing = editing
                        if !editing { previewPlayer.seek(to: scrubTime) }
                    }
                )
                .disabled(!canPreview)

                Text(formattedDuration(previewPlayer.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            summaryCounts
            Spacer()
            Button("Process Selected…") {
                processOptions = ProcessOptions()
                showingProcessOptions = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(toLevelRecords.isEmpty || isProcessing)
        }
        .padding(12)
    }

    private var summaryCounts: some View {
        HStack(spacing: 14) {
            countLabel("Total", records.count)
            countLabel("Measured", count { $0.status.isMeasured })
            countLabel("TP-Limited", count { $0.status == .tpConstrained })
            countLabel("To Level", toLevelRecords.count)
            countLabel("Errors", count { if case .error = $0.status { return true }; return false })
            if loudestRecordID != nil {
                legendSwatch(color: .red, label: "Loudest")
                legendSwatch(color: .green, label: "Closest to average")
            }
        }
        .font(.caption)
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.5)).frame(width: 10, height: 10)
            Text(label).foregroundColor(.secondary)
        }
    }

    private func count(_ predicate: (AudioFileRecord) -> Bool) -> Int {
        records.filter(predicate).count
    }

    private func countLabel(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 13, weight: .semibold))
            Text(label).foregroundColor(.secondary)
        }
    }

    /// Files with a non-trivial gain queued — GainProcessor itself also
    /// no-ops per-file on an ~0dB gain, this is just the up-front count for
    /// the summary bar / review sheet.
    private var toLevelRecords: [AudioFileRecord] {
        records.filter { $0.status.isMeasured && ($0.suggestedGainDB.map { abs($0) >= 0.01 } ?? false) }
    }

    // MARK: Leveling

    private func refreshProposedTargetAndRecompute() {
        if let proposed = LevelingEngine.proposedTargetLUFS(records: records, mode: settings.targetMode, settings: settings) {
            targetLUFS = proposed
        }
        recomputeLeveling()
    }

    private func recomputeLeveling() {
        guard !records.isEmpty else { return }
        let proposal = LevelingEngine.apply(to: &records, targetLUFS: targetLUFS, settings: settings)
        lastForcingRecordID = proposal.forcingRecordID
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select a folder containing audio files"
        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
            folderHistory = []
            scan(folder: url)
        }
    }

    private func navigateInto(_ folder: URL) {
        guard let current = folderURL else { return }
        folderHistory.append(current)
        folderURL = folder
        scan(folder: folder)
    }

    private func navigateUp() {
        guard let previous = folderHistory.popLast() else { return }
        folderURL = previous
        scan(folder: previous)
    }

    @ViewBuilder
    private var subfolderNavigationShortcuts: some View {
        Button("", action: highlightPreviousSubfolder)
            .keyboardShortcut(.leftArrow, modifiers: .command)
        Button("", action: highlightNextSubfolder)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        Button("", action: enterHighlightedSubfolder)
            .keyboardShortcut(.downArrow, modifiers: .command)
    }

    private func highlightNextSubfolder() {
        guard !subfolders.isEmpty else { return }
        if let current = highlightedSubfolderIndex {
            if current < subfolders.count - 1 { highlightedSubfolderIndex = current + 1 }
        } else {
            highlightedSubfolderIndex = 0
        }
    }

    private func highlightPreviousSubfolder() {
        guard !subfolders.isEmpty else { return }
        if let current = highlightedSubfolderIndex {
            if current > 0 { highlightedSubfolderIndex = current - 1 }
        } else {
            highlightedSubfolderIndex = subfolders.count - 1
        }
    }

    private func enterHighlightedSubfolder() {
        guard let index = highlightedSubfolderIndex, subfolders.indices.contains(index) else { return }
        navigateInto(subfolders[index])
    }

    private func handleFolderDrop(providers: [NSItemProvider]) -> Bool {
        let loadable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loadable.isEmpty else { return false }

        let group = DispatchGroup()
        var droppedURLs: [URL] = []
        let lock = NSLock()

        for provider in loadable {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.resolveFolderFromDrop(droppedURLs)
        }
        return true
    }

    private func resolveFolderFromDrop(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                folderURL = url
                folderHistory = []
                scan(folder: url)
                return
            }
        }
        if let firstFile = urls.first {
            let parent = firstFile.deletingLastPathComponent()
            folderURL = parent
            folderHistory = []
            scan(folder: parent)
        }
    }

    private func scan(folder: URL) {
        isScanning = true
        scanProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = FolderScanner.scan(folder: folder) { completed, total in
                // Fires on whichever background analysis thread just
                // finished a file — hop to main before touching @State.
                DispatchQueue.main.async {
                    self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
                }
            }
            let childFolders = FolderScanner.listSubfolders(of: folder)
            DispatchQueue.main.async {
                self.records = scanned
                self.subfolders = childFolders
                self.highlightedSubfolderIndex = nil
                self.isScanning = false
                self.refreshProposedTargetAndRecompute()
            }
        }
    }

    private func processSelected(options: ProcessOptions) {
        guard let folderURL else { return }
        let toProcess = toLevelRecords
        guard !toProcess.isEmpty else { return }

        isProcessing = true
        processingProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var completed = 0
            var failures: [String] = []

            for record in toProcess {
                do {
                    _ = try GainProcessor.process(record: record, sourceFolder: folderURL, options: options)
                } catch {
                    failures.append("\(record.filename): \(error.localizedDescription)")
                }
                completed += 1
                let progress = Double(completed) / Double(toProcess.count)
                DispatchQueue.main.async { self.processingProgress = progress }
            }

            DispatchQueue.main.async {
                self.isProcessing = false
                if !failures.isEmpty {
                    self.processingErrors = failures
                    self.showingProcessingErrors = true
                }
                self.scan(folder: folderURL)
            }
        }
    }

    // MARK: Formatting

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formattedSampleRate(_ rate: Double) -> String {
        guard rate > 0 else { return "—" }
        return String(format: "%.1fk", rate / 1000)
    }
}

private struct FolderChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(configuration.isPressed ? 0.30 : 0.18))
            .clipShape(Capsule())
    }
}
