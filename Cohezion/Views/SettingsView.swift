import SwiftUI
import AppKit

/// Backing content for the Settings scene (⌘,). Update-check controls live
/// on the Help menu already (see CohezionApp), so there's no separate
/// Updates tab here.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            processingTab
                .tabItem { Label("Processing", systemImage: "folder.badge.gearshape") }
            targetTab
                .tabItem { Label("Target", systemImage: "target") }
            spectralTab
                .tabItem { Label("Spectral QC", systemImage: "waveform.path.ecg") }
            goniometerTab
                .tabItem { Label("Goniometer", systemImage: "waveform") }
        }
        .frame(width: 480, height: 420)
        .background(
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Warn before opening a folder over the current batch", isOn: $settings.warnBeforeReplacingBatch)
                Picker("When not warning, default to", selection: $settings.defaultReplaceBatchAction) {
                    ForEach(ReplaceBatchAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .disabled(settings.warnBeforeReplacingBatch)
            } header: {
                Text("Main Window")
            } footer: {
                Text("Shown before opening a folder (Select Folder…, File > Open Folder…, or dropping a folder onto the window) would interact with files already in the table — not shown when the table's already empty. Choose Replace or Append each time it appears; checking its own \"Don't ask again\" remembers whichever you picked and turns this toggle off. The picker above is what's used silently once the toggle's off, whether you turned it off here or from the alert.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var processingTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Original files default to", selection: $settings.defaultOriginalHandling) {
                        ForEach(OriginalFilesHandling.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    Picker("New leveled files default to", selection: $settings.defaultOutputLocation) {
                        ForEach(OutputLocation.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                } header: {
                    Text("Process Selected Defaults")
                } footer: {
                    Text("Which choice is pre-selected each time the Process Selected review sheet opens — always freely changeable there for that one run without touching this. \"Move to a custom folder…\" starts with no folder chosen, so Process Selected stays disabled until one's picked (or the choice is switched to something that doesn't need one).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Text("The Desktop option writes into \"\(AppSettings.Defaults.desktopSessionFolder.lastPathComponent)\", a folder named from the app and today's date so each day's output lands somewhere fresh. After a run that consolidates everything into one folder — a custom folder or this Desktop folder — Cohezion opens that folder in the table automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var targetTab: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    Picker("Default target mode", selection: $settings.targetMode) {
                        ForEach(TargetMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    LabeledContent("Fixed standard") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.fixedStandardLUFS, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                                .disabled(settings.targetMode != .fixedStandard)
                            Text("LUFS")
                        }
                    }
                } header: {
                    Text("Target Mode")
                } footer: {
                    Text("Pre-selected when a folder's just been scanned — you can still switch modes or edit the proposed target number directly before confirming a run.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    LabeledContent("True Peak ceiling") {
                        HStack(spacing: 4) {
                            TextField("", value: ceilingBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text("dBTP")
                        }
                    }
                    Picker("When gain would exceed the ceiling", selection: $settings.tpConstraintHandling) {
                        ForEach(TPConstraintHandling.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                } header: {
                    Text("True Peak")
                } footer: {
                    Text("Never clip, TP always wins. -0.1 dBTP is the maximum this field will ever allow, even though 0.0 dBTP mastering is common practice for some engineers — a deliberate stance, not an oversight.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            resetButton { settings.resetTargetDefaults() }
        }
    }

    private var spectralTab: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    Picker("Reference", selection: $settings.spectrumReference) {
                        ForEach(SpectrumReference.allCases) { reference in
                            Text(reference.label).tag(reference)
                        }
                    }
                } header: {
                    Text("Batch Spectrum Overlay")
                } footer: {
                    Text("Pink is the conventional RTA/mastering-meter reference — flat for typical music. White is flat for white noise instead, which reads as a downward tilt for most music (the default in some other tools, e.g. iZotope Insight). Also switchable directly from the Spectrum window.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    LabeledContent("Outlier threshold") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.spectralOutlierThresholdDB, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text("dB")
                        }
                    }
                } header: {
                    Text("Batch Spectral QC")
                } footer: {
                    Text("A per-band deviation from the batch average spectrum at or above this flags that file/band as an outlier in the overlay — a QC signal only, never used to alter a file's tone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            resetButton { settings.resetSpectralDefaults() }
        }
    }

    private var goniometerTab: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    ColorPicker("Trace color", selection: goniometerColorBinding, supportsOpacity: false)
                } header: {
                    Text("Display")
                } footer: {
                    Text("The top-right stereo scope shows the raw file's L/R while previewing — a quick sanity check, not a mixing tool. Blank until you press play.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            resetButton { settings.resetGoniometerDefaults() }
        }
    }

    /// TextField writes straight to AppSettings, whose own didSet already
    /// clamps to the -0.1 dBTP hard cap — this binding just re-reads the
    /// (possibly clamped) value back out so the field reflects it.
    private var ceilingBinding: Binding<Double> {
        Binding(
            get: { settings.truePeakCeilingDBTP },
            set: { settings.truePeakCeilingDBTP = $0 }
        )
    }

    private var goniometerColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.goniometerColorHex) },
            set: { settings.goniometerColorHex = $0.hexString }
        )
    }

    private func resetButton(action: @escaping () -> Void) -> some View {
        Button("Reset to Defaults", action: action)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
    }
}
