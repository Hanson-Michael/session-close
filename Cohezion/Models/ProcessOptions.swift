import Foundation

/// Common shape for the two per-run choice enums below, so the review sheet
/// can render both with one generic radio-row helper — same pattern as
/// Session Prep's ProcessOptions.
protocol OptionLabeled: Hashable, Identifiable {
    var label: String { get }
}

/// What to do with a file's original once a leveled copy's been written —
/// a per-run choice made in the pre-flight review sheet, seeded each time
/// from the standing preference `AppSettings.defaultOriginalHandling`
/// (Settings > Processing) rather than a hardcoded literal, so which choice
/// starts selected is user-configurable instead of fixed in code. (Doc
/// comment above used to claim this always reset to `.moveToSubfolder`
/// "the safest behavior" — that was already stale/wrong before this
/// change, since the actual default had been `.leaveInPlace` for a while;
/// fixed here along with making it a real, changeable setting instead of
/// either hardcoded value.)
enum OriginalFilesHandling: String, CaseIterable, Identifiable, Hashable, OptionLabeled {
    case leaveInPlace
    case moveToSubfolder
    case customFolder
    /// The quick, no-picker-needed option — see
    /// AppSettings.Defaults.defaultOriginalsFolder for exactly where this
    /// points and why it's named the way it is.
    case desktop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leaveInPlace: return "Leave in place"
        case .moveToSubfolder: return "Move to \"Source - Unleveled\""
        case .customFolder: return "Move to a custom folder…"
        case .desktop: return "Move to Desktop (\"\(AppSettings.Defaults.desktopSessionFolder.lastPathComponent)\")"
        }
    }
}

/// Where newly-written leveled files land — also a per-run choice, seeded
/// from `AppSettings.defaultOutputLocation`. `.sourceFolder` writes
/// directly into wherever that file's own source folder is, no subfolder
/// created — distinct from `.defaultSubfolder`. Labeled "Leave in place"
/// (matching OriginalFilesHandling's naming) rather than its older "Write
/// to source folder" wording, since "the source folder" isn't one shared
/// place anymore now that Add Files/append can pull records in from
/// scattered locations — "leave in place" describes what actually happens
/// per file more accurately than "source folder" does.
enum OutputLocation: String, CaseIterable, Identifiable, Hashable, OptionLabeled {
    case sourceFolder
    case defaultSubfolder
    case customFolder
    /// The quick, no-picker-needed option — see
    /// AppSettings.Defaults.defaultProcessedFolder for exactly where this
    /// points and why it's named the way it is.
    case desktop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sourceFolder: return "Leave in place"
        case .defaultSubfolder: return "Move to \"Processed - Leveled\""
        case .customFolder: return "Move to a custom folder…"
        case .desktop: return "Move to Desktop (\"\(AppSettings.Defaults.desktopSessionFolder.lastPathComponent)\")"
        }
    }
}

/// Everything the pre-flight review sheet collects before Process Selected
/// actually runs. A fresh value each time the sheet opens. `originalHandling`
/// and `outputLocation` seed from the standing AppSettings defaults below —
/// still freely changeable for this one run without touching that standing
/// preference. `customOriginalsFolder`/`customOutputFolder` deliberately
/// start nil (not pre-filled with the Desktop path) even when the seeded
/// strategy is `.customFolder` — that option means "you pick one," so
/// Process Selected stays disabled (see ProcessOptionsSheet.canProcess)
/// until a folder's actually chosen or the strategy's switched to something
/// that doesn't need one (Leave in place, the beside-each-file subfolder,
/// or the quick Desktop option). Target mode, the fixed standard, the TP
/// ceiling, and TP-constraint handling are standing preferences (AppSettings)
/// surfaced here too for convenience, same relationship Session Prep's Peak
/// Safety/Leveling controls have to their own review sheet.
struct ProcessOptions {
    var originalHandling: OriginalFilesHandling = AppSettings.shared.defaultOriginalHandling
    var customOriginalsFolder: URL?
    var outputLocation: OutputLocation = AppSettings.shared.defaultOutputLocation
    var customOutputFolder: URL?
    /// When off, new files reuse the original filename instead of the
    /// `_leveled` suffix.
    var suffixesEnabled: Bool = true
}
