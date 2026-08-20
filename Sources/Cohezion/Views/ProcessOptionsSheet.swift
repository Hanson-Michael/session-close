import SwiftUI
import AppKit

/// Pre-flight review shown when "Process Selected…" is tapped — surfaces
/// every per-run choice (original-file handling, output location,
/// suffixes) in one place, same shape as Session Prep's own review sheet.
/// Resets to the safe defaults every time it's opened. True Peak ceiling /
/// constraint handling used to be surfaced here too (as an acknowledged
/// exception, since they're standing AppSettings preferences rather than
/// per-run choices) but moved to the main window's target bar instead
/// (Main window backlog item 4) — always visible there rather than only
/// right before processing, so this sheet no longer touches AppSettings
/// directly at all.
struct ProcessOptionsSheet: View {
    let toLevelCount: Int
    let targetLUFS: Double
    let targetModeLabel: String
    @Binding var options: ProcessOptions
    let onCancel: () -> Void
    let onProcess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Process Selected Files")
                .font(.title3.bold())

            Text(summaryText)
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Original Files").font(.headline)
                ForEach(OriginalFilesHandling.allCases) { choice in
                    radioRow(choice, selection: $options.originalHandling)
                    if choice == .customFolder {
                        folderRow(path: options.customOriginalsFolder?.path, isEnabled: options.originalHandling == .customFolder) {
                            options.customOriginalsFolder = pickFolder()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("New Leveled Files").font(.headline)
                ForEach(OutputLocation.allCases) { choice in
                    radioRow(choice, selection: $options.outputLocation)
                    if choice == .customFolder {
                        folderRow(path: options.customOutputFolder?.path, isEnabled: options.outputLocation == .customFolder) {
                            options.customOutputFolder = pickFolder()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Add suffixes", isOn: $options.suffixesEnabled)
                    .font(.headline)
                Text("e.g. _leveled — flagging which files were touched. Existing BWF/broadcast metadata is always retained, never fabricated.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Process") { onProcess() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canProcess)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var canProcess: Bool {
        guard toLevelCount > 0 else { return false }
        if options.originalHandling == .customFolder && options.customOriginalsFolder == nil { return false }
        if options.outputLocation == .customFolder && options.customOutputFolder == nil { return false }
        return true
    }

    private var summaryText: String {
        let targetString = String(format: "%.1f LUFS", targetLUFS)
        return "\(toLevelCount) file\(toLevelCount == 1 ? "" : "s") to level toward \(targetString) (\(targetModeLabel))."
    }

    private func radioRow<T: OptionLabeled>(_ choice: T, selection: Binding<T>) -> some View {
        Button {
            selection.wrappedValue = choice
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection.wrappedValue == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selection.wrappedValue == choice ? Color.accentColor : Color.secondary)
                Text(choice.label)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func folderRow(path: String?, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(path ?? "No folder chosen")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Choose…", action: action)
        }
        .padding(.leading, 22)
        .disabled(!isEnabled)
    }

    private func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
