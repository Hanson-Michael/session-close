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

    // MARK: Derived-state cache (see refreshDerivedCaches())
    //
    // Backlog item "Main window #8": rowHighlight/loudestRecordID/
    // closestToAverageRecordID used to be plain computed properties,
    // recomputed from scratch (each an O(N) pass over `records`) on every
    // call to `cell(...)` — and `cell` is invoked once per column per row,
    // so a full table render was doing on the order of N rows × ~7 columns
    // × O(N) work, effectively quadratic in file count. Fine at album scale
    // (tens of files), suspected of contributing to a crash on a folder
    // with thousands. `records.sorted(using: sortOrder)` had the same
    // "recomputed every render, not just when it actually needs to change"
    // problem, just not quadratic on its own. These three now live here as
    // cached @State, refreshed explicitly by refreshDerivedCaches()
    // wherever `records`/`sortOrder` actually change, instead of being
    // recomputed implicitly on every read.
    @State private var cachedSortedRecords: [AudioFileRecord] = []
    @State private var cachedLoudestRecordID: AudioFileRecord.ID?
    @State private var cachedClosestToAverageRecordID: AudioFileRecord.ID?

    // Subfolder navigation — retained from Session Prep even though the
    // scan itself stays top-level-only, per the product decision this app
    // was scoped under: move deeper into an album's subfolders via chips
    // and Cmd+arrow shortcuts rather than scanning recursively.
    @State private var subfolders: [URL] = []
    @State private var highlightedSubfolderIndex: Int?
    @State private var folderHistory: [URL] = []

    // MARK: Pre-scan large-folder guard (Main window backlog item 8b)
    //
    // The app's whole model assumes "one album's worth of session files,"
    // not an arbitrary huge folder — a friend's scan of their (huge)
    // Downloads folder was the suspected crash trigger behind item 8. This
    // guard adds a cheap pre-count (FolderScanner.audioFiles(in:).count —
    // a single directory listing, not the expensive per-file BS.1770+FFT
    // pass) before committing to a scan, and confirms with the user above
    // `largeFolderFileCountThreshold` files instead of just diving in.
    //
    // Deliberately only wired into the four places a *new* folder gets
    // chosen (chooseFolder, navigateInto, navigateUp, resolveFolderFromDrop)
    // — not the automatic re-scan `processSelected` triggers on the same
    // folder after Process Selected finishes, since that folder was already
    // approved (or was already small) earlier in the same session, and
    // re-confirming there would just be an extra click on every single
    // process run.
    private static let largeFolderFileCountThreshold = 300

    /// Step size for the +/- nudger buttons flanking the LUFS and True
    /// Peak ceiling fields on the target bar — matches the one-decimal
    /// precision already shown in both.
    private static let nudgeStep = 0.1

    /// A folder-scan waiting on the large-folder confirm alert.
    /// `action` is whichever of "replace" or "append" beginScan already
    /// decided on (see confirmReplacingBatchIfNeeded) — fully formed and
    /// ready to run, just deferred until the user actually confirms the
    /// size, so a Cancel here leaves everything (`records`,
    /// `folderURL`/`folderHistory`, or whatever `action` would have
    /// touched) untouched rather than pointing at a folder that was never
    /// actually scanned.
    private struct PendingFolderScan {
        let fileCount: Int
        let action: () -> Void
    }
    @State private var pendingFolderScan: PendingFolderScan?
    @State private var showingLargeFolderConfirm = false

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
    @State private var showingSpectrumOverlay = false
    @State private var showingResetConfirm = false

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
                    // subfolderBar commented out, not deleted — 2026-08-18,
                    // per user request: stop clickable navigation into
                    // arbitrary subfolders from the main window now that
                    // Add Files/drag-and-drop cover getting files in.
                    // navigateInto/navigateUp/highlightNextSubfolder/
                    // highlightPreviousSubfolder/enterHighlightedSubfolder
                    // and the subfolders/highlightedSubfolderIndex/
                    // folderHistory state are all left intact below,
                    // unused — uncomment this line (and
                    // subfolderNavigationShortcuts below) to restore.
                    // subfolderBar
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
        // Sized for the 7 core columns (now including LRA) + Loudness
        // Detail (ST Max 70, M Max 70 = 140pt) — both detail groups still
        // default to hidden (see showFileDetail/showLoudnessDetail), but
        // Loudness Detail is the one worth always having room for without
        // triggering horizontal scroll. File Detail (Format/Bit
        // Depth/Sample Rate/Duration) is wider and less often needed, so
        // turning that one on can still make the table scroll horizontally
        // rather than growing the window to fit every possible
        // combination.
        .frame(minWidth: 1200, minHeight: 780)
        // The .background{} wiring up subfolderNavigationShortcuts (Cmd+
        // Left/Right/Down) is commented out alongside subfolderBar above —
        // same 2026-08-18 change, same reason. subfolderNavigationShortcuts
        // itself is left defined below, unused.
        // .background {
        //     subfolderNavigationShortcuts
        //         .frame(width: 0, height: 0)
        //         .opacity(0)
        // }
        // Reset (X), title bar — matching IngestIQ (2026-08-20 request).
        // First attempt used an NSTitlebarAccessoryViewController bridged
        // in via a zero-size NSViewRepresentable; it never actually
        // rendered. IngestIQ's own working version turned out to just be a
        // plain SwiftUI `.toolbar` item — .primaryAction places it at the
        // title bar's trailing edge automatically, no AppKit interop
        // needed, and it lives in the same view hierarchy as everything
        // else, so `.disabled` can read `records`/`folderURL` directly.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingResetConfirm = true
                } label: {
                    Label("Reset", systemImage: "xmark.circle")
                }
                .disabled(records.isEmpty && folderURL == nil)
                .help("Clear the current batch")
            }
        }
        // Native SwiftUI `.alert`, not NSAlert — matching IngestIQ. Also
        // resolves the centering complaint a different way than expected:
        // SwiftUI's own `.alert` already renders centered on macOS (no
        // left-aligned icon the way NSAlert has); a custom card was never
        // actually necessary for this one. NSAlert is still used elsewhere
        // (Replace/Append) only because that dialog needs a suppression
        // checkbox SwiftUI's `.alert` doesn't support.
        .alert("Clear the current batch?", isPresented: $showingResetConfirm) {
            Button("Reset", role: .destructive) { resetBatch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(records.count) file\(records.count == 1 ? "" : "s") from the list. Nothing is deleted from disk.")
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
        .onChange(of: sortOrder) { _ in refreshDerivedCaches() }
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
        .alert(
            "Large Folder",
            isPresented: $showingLargeFolderConfirm,
            presenting: pendingFolderScan
        ) { pending in
            Button("Cancel", role: .cancel) { pendingFolderScan = nil }
            Button("Scan Anyway") {
                let action = pending.action
                pendingFolderScan = nil
                action()
            }
        } message: { pending in
            Text("This folder has \(pending.fileCount) audio files — well beyond a typical album, and scanning may be slow. Continue?")
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

    /// Order and shape match IngestIQ's top bar (2026-08-20 request): Add
    /// Files, then Select Folder, then the current path shown as its own
    /// separate label — not, as before, one control that swaps between
    /// "Select Folder…" button and clickable path depending on state.
    /// "Select Folder…" is now a permanent button (click it again anytime
    /// to change folders); the path is purely informational. Reset used to
    /// live here too — moved to a `.toolbar` item on `body` (title bar,
    /// trailing edge), matching IngestIQ's (X) in the title bar rather
    /// than a row button.
    private var folderBar: some View {
        HStack {
            Button {
                addFilesViaPicker()
            } label: {
                Label("Add Files…", systemImage: "plus")
            }
            .help("Add individual audio files from anywhere, without replacing the current batch")

            Button {
                chooseFolder()
            } label: {
                Label("Select Folder…", systemImage: "folder")
            }
            .help("Scan a folder's audio files — replaces or appends to the current batch")

            folderPathLabel

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

    /// Purely informational now — no longer a button (see folderBar's doc
    /// comment). "No folder selected" placeholder keeps the row's height
    /// stable rather than the label disappearing entirely when empty.
    private var folderPathLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundColor(.secondary)
            Text(folderURL?.path ?? "No folder selected")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
        // .firstTextBaseline instead of the default .center — with the
        // Target:/LUFS/status text at .title3 alongside shorter controls
        // (Picker, TextField), center-aligning their bounding boxes no
        // longer reads as visually centered against the text's own
        // baseline. Aligning by first text baseline instead keeps every
        // Text in the row sitting on a common line; the nested HStack below
        // needs the same alignment so its baseline (not its own vertical
        // center) is what gets reported up to this outer stack.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Target:")
                .font(.title3)
                .foregroundColor(.secondary)

            Picker("", selection: $settings.targetMode) {
                ForEach(TargetMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .help(settings.targetMode.helpText)

            nudgedNumberField(value: $targetLUFS, step: Self.nudgeStep, suffix: "LUFS") {
                recomputeLeveling()
            }

            if settings.targetMode == .referenceTrack, !records.contains(where: { $0.isReferenceTrack }) {
                Text("Click the star on a row to flag a reference track.")
                    .font(.title3)
                    .foregroundColor(.orange)
            }

            if let forcingID = lastForcingRecordID, settings.tpConstraintHandling == .lowerBatchTarget,
               let forcingRecord = records.first(where: { $0.id == forcingID }) {
                Text("Lowered to fit \"\(forcingRecord.filename)\"'s True Peak headroom.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// A number field flanked by minus/plus nudger buttons — used for both
    /// the LUFS field (target bar) and True Peak ceiling field (bottom
    /// bar), which sit at different type scales, hence `font`. `onCommit`
    /// fires after every nudger tap and on Return/Tab out of the field
    /// (matching the field's own prior `onSubmit` behavior); pass nil when
    /// the caller already has its own reactive wiring (True Peak ceiling's
    /// `.onChange(of: settings.truePeakCeilingDBTP)` in body already
    /// recomputes leveling on every edit, nudger or typed).
    private func nudgedNumberField(value: Binding<Double>, step: Double, suffix: String, font: Font = .title3, onCommit: (() -> Void)? = nil) -> some View {
        HStack(spacing: 4) {
            Button {
                value.wrappedValue -= step
                onCommit?()
            } label: {
                Image(systemName: "minus")
                    .font(.caption.bold())
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Decrease by \(String(format: "%.1f", step))")

            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
                .onSubmit { onCommit?() }

            Button {
                value.wrappedValue += step
                onCommit?()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.bold())
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Increase by \(String(format: "%.1f", step))")

            Text(suffix)
                .font(font)
                .foregroundColor(.secondary)
        }
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
            Text("Drag a folder or files onto this window, or use Select Folder…/Add Files…")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Cohezion measures Integrated LUFS, True Peak, and tonal balance for every file in a folder, proposes a batch loudness target, and levels toward it — never past the True Peak ceiling.")
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
            Table(cachedSortedRecords, selection: $selection, sortOrder: $sortOrder) {
                coreColumns
            }
        case (true, false):
            Table(cachedSortedRecords, selection: $selection, sortOrder: $sortOrder) {
                coreColumns
                fileDetailColumns
            }
        case (false, true):
            Table(cachedSortedRecords, selection: $selection, sortOrder: $sortOrder) {
                coreColumns
                loudnessDetailColumns
            }
        case (true, true):
            Table(cachedSortedRecords, selection: $selection, sortOrder: $sortOrder) {
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
    // batch-average LUFS" (see the average calculation inside
    // refreshDerivedCaches below for what that number is and its own
    // caveats). Only shown once there's more than one measured file — with
    // a single file, "loudest vs. average" isn't a meaningful distinction.

    /// Recomputes `cachedSortedRecords` / `cachedLoudestRecordID` /
    /// `cachedClosestToAverageRecordID` in one O(N) pass over `records`.
    /// Call this after anything that mutates `records` in place (or
    /// replaces it), and on `sortOrder` change — see the cache's own doc
    /// comment above the @State declarations for why this exists. Also the
    /// single source of truth `cachedSortedRecords` is a value-type copy of
    /// `records`, so skipping this call after a mutation would leave the
    /// table showing stale field values (e.g. a stale star icon), not just
    /// stale highlighting — this must run after *every* records mutation,
    /// not only ones that could plausibly change who's loudest/closest.
    private func refreshDerivedCaches() {
        cachedSortedRecords = records.sorted(using: sortOrder)

        let measured = records.filter { $0.status.isMeasured }
        guard measured.count > 1 else {
            cachedLoudestRecordID = nil
            cachedClosestToAverageRecordID = nil
            return
        }
        cachedLoudestRecordID = measured.max(by: { ($0.integratedLUFS ?? -.infinity) < ($1.integratedLUFS ?? -.infinity) })?.id

        // Plain arithmetic mean of every measured file's Integrated LUFS —
        // the exact same number LevelingEngine.proposedTargetLUFS computes
        // for .batchAverage mode (see that function's doc comment for the
        // duration/power-weighting caveat flagged for a future revision).
        // Computed independently here so the highlight stays meaningful
        // even when a different target mode is actually selected.
        let values = measured.compactMap { $0.integratedLUFS }
        guard !values.isEmpty else {
            cachedClosestToAverageRecordID = nil
            return
        }
        let average = values.reduce(0, +) / Double(values.count)
        cachedClosestToAverageRecordID = measured.min(by: {
            abs(($0.integratedLUFS ?? .infinity) - average) < abs(($1.integratedLUFS ?? .infinity) - average)
        })?.id
    }

    /// Loudest wins if a file somehow qualifies as both (a very tight
    /// batch) — the True-Peak-risk signal is the more load-bearing one.
    private func rowHighlight(for record: AudioFileRecord) -> Color {
        if record.id == cachedLoudestRecordID { return .red.opacity(0.16) }
        if record.id == cachedClosestToAverageRecordID { return .green.opacity(0.16) }
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

    /// Target star · Status · Suggested Gain · Filename · Integrated LUFS ·
    /// True Peak · LRA — always visible, the seven columns you need to make
    /// a leveling decision. Format/Bit Depth/Sample Rate/Duration and ST
    /// Max/M Max are their own group below, folded in or out via the
    /// `table` switch above rather than a conditional inside this builder.
    /// LRA used to live in that folded group too, but is common enough to
    /// warrant always being visible, so it's pinned here as the last column
    /// instead.
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

        TableColumn("Suggested Gain", value: \.suggestedGainSortValue) { record in
            cell(
                Text(record.suggestedGainDB.map { String(format: "%+.1f dB", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(100)

        TableColumn("Filename", value: \.filename) { record in
            cell(
                HStack(spacing: 4) {
                    Text(record.filename).lineLimit(1)
                    if let writtenURL = record.writtenURL {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 11))
                            .help("Leveled this run — wrote \(writtenURL.lastPathComponent)")
                    }
                },
                for: record
            )
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

        TableColumn("LRA", value: \.lraSortValue) { record in
            cell(
                Text(record.loudnessRangeLRA.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced)),
                for: record
            )
        }
        .width(60)
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

    /// ST Max · M Max — folded in via the Columns menu's "Loudness Detail"
    /// toggle (see `table` above). Summary stats only (see
    /// Session-Close-Concept.md "Decisions #3": no per-file loudness-history
    /// graph in v1). LRA used to be the bonus stat here too, but now lives
    /// in `coreColumns` as an always-visible column instead.
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
    }

    private func toggleReferenceTrack(_ record: AudioFileRecord) {
        guard let idx = records.firstIndex(where: { $0.id == record.id }) else { return }
        let newValue = !records[idx].isReferenceTrack
        for i in records.indices { records[i].isReferenceTrack = false }
        records[idx].isReferenceTrack = newValue
        if settings.targetMode == .referenceTrack {
            refreshProposedTargetAndRecompute()
        } else {
            // refreshProposedTargetAndRecompute (via recomputeLeveling) is
            // the usual place this happens, but it's only called above in
            // .referenceTrack mode. Still need to refresh here in every
            // other mode, since cachedSortedRecords is a copy of `records`
            // — without this, the star column would show stale state.
            refreshDerivedCaches()
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

            // Moved down here from the target bar (2026-08-20) — too
            // crowded up there once nudgers were added; matches IngestIQ's
            // own bottom-bar placement for its equivalent Peak Safety
            // control. Both still feed
            // `.onChange(of: settings.truePeakCeilingDBTP/tpConstraintHandling)`
            // in body, which recomputes leveling automatically — no extra
            // wiring needed here beyond the fields themselves.
            Text("TP Ceiling:")
                .font(.callout)
                .foregroundColor(.secondary)
            nudgedNumberField(value: $settings.truePeakCeilingDBTP, step: Self.nudgeStep, suffix: "dBTP", font: .callout)
            Picker("", selection: $settings.tpConstraintHandling) {
                ForEach(TPConstraintHandling.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .help("What happens when a file's desired gain would exceed the True Peak ceiling.")

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
            if cachedLoudestRecordID != nil {
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
        refreshDerivedCaches()
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
            beginScan(folder: url) {
                self.folderURL = url
                self.folderHistory = []
            }
        }
    }

    // MARK: Add Files (Main window backlog item 9)
    //
    // Individual files from arbitrary locations, incrementally appended to
    // `records` rather than replacing it — the counterpart to a whole-
    // folder scan. Always available (no folder needs to have been scanned
    // first) since `folderBar` sits outside the `records.isEmpty` branch in
    // `body`, so this button is reachable from the empty state too.

    /// Content types built from `FolderScanner.supportedExtensions` so the
    /// picker only offers files this app can actually analyze — kept in
    /// sync with the scanner automatically rather than duplicating the
    /// extension list here.
    private var allowedAudioContentTypes: [UTType] {
        FolderScanner.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    private func addFilesViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Select audio files to add to the current batch"
        let types = allowedAudioContentTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    /// Analyzes and appends `urls` to `records` — used by both the Add
    /// Files… picker and individual-file drag-and-drop (see
    /// `resolveFolderFromDrop`). Already-present files (matched by URL) are
    /// skipped rather than added a second time; safe to call repeatedly
    /// (a second, third, fourth batch of adds all just keep appending).
    private func addFiles(_ urls: [URL]) {
        let existingURLs = Set(records.map(\.url))
        let newURLs = urls.filter { !existingURLs.contains($0) }
        guard !newURLs.isEmpty else { return }

        isScanning = true
        scanProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let analyzed = FolderScanner.analyze(files: newURLs) { completed, total in
                // Same background-thread-to-main hop as FolderScanner.scan's
                // onProgress — see that call site's comment.
                DispatchQueue.main.async {
                    self.scanProgress = total > 0 ? Double(completed) / Double(total) : 0
                }
            }
            DispatchQueue.main.async {
                self.records.append(contentsOf: analyzed)
                self.isScanning = false
                self.refreshDerivedCaches()
                self.refreshProposedTargetAndRecompute()
            }
        }
    }

    /// Clears the batch back to blank — needed as soon as files can be
    /// added incrementally, since before Add Files existed the only way to
    /// clear `records` was picking a new folder (which replaces rather than
    /// clears). Deliberately does *not* touch `settings.targetMode` — that's
    /// a standing AppSettings preference, not batch state.
    private func resetBatch() {
        records = []
        folderURL = nil
        subfolders = []
        folderHistory = []
        highlightedSubfolderIndex = nil
        selection = []
        targetLUFS = -14.0
        lastForcingRecordID = nil
        refreshDerivedCaches()
    }

    private func navigateInto(_ folder: URL) {
        guard let current = folderURL else { return }
        beginScan(folder: folder) {
            self.folderHistory.append(current)
            self.folderURL = folder
        }
    }

    private func navigateUp() {
        // Peek rather than pop — popping needs to wait until the scan is
        // actually confirmed (see beginScan/PendingFolderScan); popping
        // here unconditionally would desync folderHistory from folderURL
        // if the user cancels the large-folder alert.
        guard let previous = folderHistory.last else { return }
        beginScan(folder: previous) {
            self.folderHistory.removeLast()
            self.folderURL = previous
        }
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

    /// A dropped *folder* still triggers a full (guarded) scan of that
    /// folder — first directory found wins, matching the pre-item-9
    /// behavior. Otherwise, every dropped file with a supported audio
    /// extension is added directly via the same `addFiles` path as the Add
    /// Files… picker, instead of the old behavior of resolving to "scan the
    /// first file's parent folder" (which replaced the whole batch for
    /// what was often just one stray dropped file).
    private func resolveFolderFromDrop(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                beginScan(folder: url) {
                    self.folderURL = url
                    self.folderHistory = []
                }
                return
            }
        }
        let audioFiles = urls.filter { FolderScanner.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !audioFiles.isEmpty else { return }
        addFiles(audioFiles)
    }

    /// Gate in front of `scan(folder:)`/`addFiles(_:)` for every entry
    /// point where the user is opening a *new* folder — chooseFolder,
    /// navigateInto, navigateUp, and resolveFolderFromDrop's directory
    /// branch, i.e. "every folder-retrigger" per the user's own framing
    /// (not the post-Process-Selected re-scan, see that guard's own doc
    /// comment above the @State declarations for why). Two independent,
    /// sequential checks: first whether — and how — this should interact
    /// with files already in the table (new as of Add Files; before that,
    /// replacing was the only way folders ever worked, so it was never a
    /// choice to make), then whether the destination folder is itself
    /// large enough to warrant a second confirmation before either kind of
    /// analysis pass runs. `updateNavigationState` is the
    /// folderURL/folderHistory bookkeeping a Replace should apply — an
    /// Append leaves both alone entirely (see confirmReplacingBatchIfNeeded
    /// and addFiles's own doc comment for why: once a batch can be built
    /// from more than one folder, there's no single folder left to track).
    private func beginScan(folder: URL, updateNavigationState: @escaping () -> Void) {
        switch confirmReplacingBatchIfNeeded() {
        case .cancel:
            return
        case .replace:
            proceedWithLargeFolderGuard(folder) {
                updateNavigationState()
                scan(folder: folder)
            }
        case .append:
            proceedWithLargeFolderGuard(folder) {
                addFiles(FolderScanner.audioFiles(in: folder))
            }
        }
    }

    /// Shared by both branches of beginScan — the large-folder count check
    /// doesn't care whether the eventual action is a replace or an append,
    /// only how expensive the analysis pass about to run is.
    private func proceedWithLargeFolderGuard(_ folder: URL, action: @escaping () -> Void) {
        let fileCount = FolderScanner.audioFiles(in: folder).count
        if fileCount > Self.largeFolderFileCountThreshold {
            pendingFolderScan = PendingFolderScan(fileCount: fileCount, action: action)
            showingLargeFolderConfirm = true
        } else {
            action()
        }
    }

    private enum ReplaceBatchDecision {
        case replace
        case append
        case cancel
    }

    /// NSAlert rather than the SwiftUI `.alert` used for the large-folder
    /// guard — this one needs a native suppression checkbox ("Don't ask
    /// again"), which SwiftUI's `.alert` has no equivalent for.
    /// Blocking/synchronous like the NSOpenPanel calls already used
    /// elsewhere in this file (chooseFolder, addFilesViaPicker).
    ///
    /// When the table's already empty, or the warning's off, this decides
    /// silently (nothing to ask about, or `settings.defaultReplaceBatchAction`
    /// says what to do without asking). Otherwise it puts up a real
    /// Replace/Append/Cancel choice — Append is the first/default button
    /// (what a bare Return keypress triggers) since it's the
    /// non-destructive option; a stray Enter shouldn't be able to wipe the
    /// table. Checking the suppression checkbox on either Replace or
    /// Append remembers that specific choice as the new silent default
    /// (`defaultReplaceBatchAction`) and turns `warnBeforeReplacingBatch`
    /// off — "remember my choice," not just "always Replace." Checking it
    /// then hitting Cancel is treated as not having checked it at all,
    /// since nothing was actually confirmed.
    private func confirmReplacingBatchIfNeeded() -> ReplaceBatchDecision {
        guard !records.isEmpty else { return .replace }
        guard settings.warnBeforeReplacingBatch else {
            switch settings.defaultReplaceBatchAction {
            case .replace: return .replace
            case .append: return .append
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace or Append?"
        let fileWord = records.count == 1 ? "file" : "files"
        alert.informativeText = "The table currently has \(records.count) \(fileWord). Add this folder's files to what's already there, or replace them?"
        alert.addButton(withTitle: "Append")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again — remember my choice"

        let response = alert.runModal()
        let decision: ReplaceBatchDecision
        switch response {
        case .alertFirstButtonReturn: decision = .append
        case .alertSecondButtonReturn: decision = .replace
        default: decision = .cancel
        }

        if decision != .cancel, alert.suppressionButton?.state == .on {
            // Re-enable (or change) from Settings > General — see
            // SettingsView's "Warn before opening a folder over the
            // current batch" toggle and "When not warning, default to"
            // picker.
            settings.warnBeforeReplacingBatch = false
            settings.defaultReplaceBatchAction = decision == .append ? .append : .replace
        }
        return decision
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
                // Explicit here (not just left to recomputeLeveling, which
                // refreshDerivedCaches below in refreshProposedTargetAndRecompute
                // would call) because recomputeLeveling no-ops on an empty
                // `records` — a scan of an empty/non-audio folder needs the
                // caches cleared too, not left stale from a previous scan.
                self.refreshDerivedCaches()
                self.refreshProposedTargetAndRecompute()
            }
        }
    }

    private func processSelected(options: ProcessOptions) {
        let toProcess = toLevelRecords
        guard !toProcess.isEmpty else { return }

        isProcessing = true
        processingProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            var completed = 0
            var failures: [String] = []
            // Which records actually got a new leveled file written (not
            // every record in toProcess — a few LUFS from target no-ops
            // and write nothing, see GainProcessor's noOpGainEpsilonDB).
            // Applied back onto self.records below so rows that don't get
            // superseded by a rescan still show something changed.
            var writtenResults: [(id: UUID, url: URL)] = []

            for record in toProcess {
                do {
                    // GainProcessor derives each file's own source folder
                    // from record.url internally (Main window backlog item
                    // 9's "real design wrinkle") — no longer a single
                    // batch-wide folder, since Add Files means records can
                    // come from scattered locations.
                    if let result = try GainProcessor.process(record: record, options: options) {
                        writtenResults.append((record.id, result.leveledFileAt))
                    }
                } catch ProcessingError.desktopAccessDenied {
                    // Every remaining file in this run would fail the same
                    // way — one clear, actionable message beats N identical
                    // ones, and there's no point retrying against a folder
                    // we've already been denied access to.
                    failures = [ProcessingError.desktopAccessDenied.localizedDescription]
                    break
                } catch {
                    failures.append("\(record.filename): \(error.localizedDescription)")
                }
                completed += 1
                let progress = Double(completed) / Double(toProcess.count)
                DispatchQueue.main.async { self.processingProgress = progress }
            }

            DispatchQueue.main.async {
                self.isProcessing = false
                // Mark the successfully-written rows in place first — always,
                // regardless of what happens next. A consolidated-destination
                // scan below replaces `records` wholesale anyway (this gets
                // superseded, harmlessly), but for a non-consolidated run —
                // Leave in place, or the beside-each-file subfolder — this is
                // the *only* thing that happens: the table stays exactly the
                // list it was, with checkmarks added, rather than being
                // rescanned. Rescanning used to run here for that case too
                // (whatever folder was active when Process Selected was
                // clicked), but that silently dropped any records that had
                // been appended from elsewhere via Add Files — the rescan
                // only re-lists one folder's contents, so a mixed batch's
                // scattered-origin rows would vanish from the table even
                // though their leveled files were written correctly. Simply
                // never rescanning for this case avoids that entirely.
                if !writtenResults.isEmpty {
                    for (id, url) in writtenResults {
                        if let index = self.records.firstIndex(where: { $0.id == id }) {
                            self.records[index].writtenURL = url
                        }
                    }
                    self.refreshDerivedCaches()
                }
                if !failures.isEmpty {
                    self.processingErrors = failures
                    self.showingProcessingErrors = true
                }
                // If this run consolidated everything into one destination
                // (a chosen custom folder, or the quick dated Desktop
                // folder), that's now "the" folder to be working in —
                // regardless of where the source files were scattered
                // from — so enter it: same as picking it via Select
                // Folder, becomes the new navigation root.
                if let consolidatedDestination = self.consolidatedDestination(for: options) {
                    self.folderHistory = []
                    self.folderURL = consolidatedDestination
                    self.scan(folder: consolidatedDestination)
                }
            }
        }
    }

    /// Where a run's new leveled files all ended up, when — and only when —
    /// that's a single, consolidated place worth entering afterward.
    /// `.customFolder`/`.desktop` are consolidated by nature (one folder,
    /// chosen or dated, regardless of how scattered the sources were);
    /// `.sourceFolder`/`.defaultSubfolder` write beside each file's own
    /// source instead, so there's no single folder to enter for those.
    private func consolidatedDestination(for options: ProcessOptions) -> URL? {
        switch options.outputLocation {
        case .customFolder:
            return options.customOutputFolder
        case .desktop:
            return AppSettings.Defaults.defaultProcessedFolder
        case .sourceFolder, .defaultSubfolder:
            return nil
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

