import Foundation

/// Common shape for the two per-run choice enums below, so the review sheet
/// can render both with one generic radio-row helper — same pattern as
/// Session Prep's ProcessOptions.
protocol OptionLabeled: Hashable, Identifiable {
    var label: String { get }
}

/// What to do with a file's original once a leveled copy's been written —
/// a per-run choice made in the pre-flight review sheet, not a standing
/// preference. Always resets to `.moveToSubfolder` (the safest behavior)
/// rather than remembering the last run's choice.
enum OriginalFilesHandling: String, CaseIterable, Identifiable, Hashable, OptionLabeled {
    case leaveInPlace
    case customFolder
    case moveToSubfolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leaveInPlace: return "Leave in place"
        case .customFolder: return "Move to a custom folder…"
        case .moveToSubfolder: return "Move to \"Source - Unleveled\" (default)"
        }
    }
}

/// Where newly-written leveled files land — also a per-run choice.
/// `.sourceFolder` writes directly into the folder being scanned, no
/// subfolder created — distinct from `.defaultSubfolder`.
enum OutputLocation: String, CaseIterable, Identifiable, Hashable, OptionLabeled {
    case sourceFolder
    case customFolder
    case defaultSubfolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sourceFolder: return "Write to source folder"
        case .customFolder: return "Move to a custom folder…"
        case .defaultSubfolder: return "Move to \"Processed - Leveled\" (default)"
        }
    }
}

/// Everything the pre-flight review sheet collects before Process Selected
/// actually runs. A fresh value each time the sheet opens — these are
/// decisions about this run, not app-wide settings. Target mode, the fixed
/// standard, the TP ceiling, and TP-constraint handling are standing
/// preferences (AppSettings) surfaced here too for convenience, same
/// relationship Session Prep's Peak Safety/Leveling controls have to their
/// own review sheet.
struct ProcessOptions {
    var originalHandling: OriginalFilesHandling = .moveToSubfolder
    var customOriginalsFolder: URL?
    var outputLocation: OutputLocation = .defaultSubfolder
    var customOutputFolder: URL?
    /// When off, new files reuse the original filename instead of the
    /// `_leveled` suffix.
    var suffixesEnabled: Bool = true
}
