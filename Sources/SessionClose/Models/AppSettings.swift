import Foundation
import Combine

/// User-editable settings, backed by UserDefaults so they persist across
/// launches — same pattern as Session Prep's AppSettings. Every value here
/// is exposed in SettingsView.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Target / leveling

    /// Pre-selected when a folder's just been scanned (user can still
    /// switch before confirming) — Batch Average per the product decision
    /// made when this app was scoped.
    @Published var targetMode: TargetMode {
        didSet { UserDefaults.standard.set(targetMode.rawValue, forKey: Keys.targetMode) }
    }
    /// Only used when targetMode == .fixedStandard.
    @Published var fixedStandardLUFS: Double {
        didSet { UserDefaults.standard.set(fixedStandardLUFS, forKey: Keys.fixedStandardLUFS) }
    }
    /// What happens when a file's desired gain would exceed its True Peak
    /// headroom. Defaults to flagging that one file short rather than
    /// quietly pulling the whole batch's target down to accommodate it —
    /// one outlier file shouldn't dictate the loudness of the rest of the
    /// album by default, though either behavior is a legitimate choice
    /// (see TPConstraintHandling), so this is fully editable.
    @Published var tpConstraintHandling: TPConstraintHandling {
        didSet { UserDefaults.standard.set(tpConstraintHandling.rawValue, forKey: Keys.tpConstraintHandling) }
    }

    // MARK: True Peak ceiling
    //
    // Never clip, TP always wins. -0.7 dBTP default per the app's stated
    // product stance (see Session-Close-Concept.md "Decisions #7"); the
    // field itself is hard-capped at -0.1 dBTP maximum even though 0.0 dBTP
    // mastering is common practice for some engineers — deliberate, not an
    // oversight. Clamp is enforced both here (in code) and by the Settings
    // UI's control bounds.

    @Published var truePeakCeilingDBTP: Double {
        didSet {
            let clamped = min(truePeakCeilingDBTP, Defaults.truePeakCeilingHardCapDBTP)
            if clamped != truePeakCeilingDBTP {
                truePeakCeilingDBTP = clamped // re-enters didSet once, then settles
                return
            }
            UserDefaults.standard.set(truePeakCeilingDBTP, forKey: Keys.truePeakCeiling)
        }
    }

    // MARK: Spectral QC

    /// A per-file/per-band deviation from the batch average spectrum at or
    /// above this (dB) gets flagged as an outlier in the spectrum overlay
    /// (e.g. "Track 4 is +3dB in the 2-5kHz band vs. the rest of the
    /// album").
    @Published var spectralOutlierThresholdDB: Double {
        didSet { UserDefaults.standard.set(spectralOutlierThresholdDB, forKey: Keys.spectralOutlierThreshold) }
    }

    /// Which reference convention the batch spectrum overlay displays
    /// against — see SpectrumReference's own doc comment for what "pink"
    /// vs. "white" means here. Defaults to pink: the conventional reference
    /// for RTAs/mastering meters (flat for typical program material),
    /// versus tools like iZotope Insight that default to white (which reads
    /// as a downward tilt for most music).
    @Published var spectrumReference: SpectrumReference {
        didSet { UserDefaults.standard.set(spectrumReference.rawValue, forKey: Keys.spectrumReference) }
    }

    // MARK: Updates

    @Published var automaticallyCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheckForUpdates, forKey: Keys.autoCheckUpdates) }
    }

    // MARK: Goniometer

    @Published var goniometerColorHex: String {
        didSet { UserDefaults.standard.set(goniometerColorHex, forKey: Keys.goniometerColorHex) }
    }

    private enum Keys {
        static let targetMode = "targetMode"
        static let fixedStandardLUFS = "fixedStandardLUFS"
        static let tpConstraintHandling = "tpConstraintHandling"
        static let truePeakCeiling = "truePeakCeilingDBTP"
        static let spectralOutlierThreshold = "spectralOutlierThresholdDB"
        static let spectrumReference = "spectrumReference"
        static let autoCheckUpdates = "automaticallyCheckForUpdates"
        static let goniometerColorHex = "goniometerColorHex"
    }

    /// v1 starting-point values, named here so the Settings window's
    /// "Reset to Defaults" buttons have a single source of truth.
    enum Defaults {
        static let targetMode = TargetMode.batchAverage
        static let fixedStandardLUFS = -14.0
        static let tpConstraintHandling = TPConstraintHandling.flagAndLeaveShort
        static let truePeakCeilingDBTP = -0.7
        /// Hard ceiling on how permissive truePeakCeilingDBTP is ever
        /// allowed to be — a deliberate product stance, see the doc comment
        /// above truePeakCeilingDBTP.
        static let truePeakCeilingHardCapDBTP = -0.1
        static let spectralOutlierThresholdDB = 3.0
        static let spectrumReference = SpectrumReference.pink
        static let goniometerColorHex = "a855f7"
    }

    private init() {
        let d = UserDefaults.standard
        targetMode = (d.string(forKey: Keys.targetMode)).flatMap(TargetMode.init(rawValue:)) ?? Defaults.targetMode
        fixedStandardLUFS = (d.object(forKey: Keys.fixedStandardLUFS) as? Double) ?? Defaults.fixedStandardLUFS
        tpConstraintHandling = (d.string(forKey: Keys.tpConstraintHandling)).flatMap(TPConstraintHandling.init(rawValue:)) ?? Defaults.tpConstraintHandling
        truePeakCeilingDBTP = (d.object(forKey: Keys.truePeakCeiling) as? Double) ?? Defaults.truePeakCeilingDBTP
        spectralOutlierThresholdDB = (d.object(forKey: Keys.spectralOutlierThreshold) as? Double) ?? Defaults.spectralOutlierThresholdDB
        spectrumReference = (d.string(forKey: Keys.spectrumReference)).flatMap(SpectrumReference.init(rawValue:)) ?? Defaults.spectrumReference
        automaticallyCheckForUpdates = (d.object(forKey: Keys.autoCheckUpdates) as? Bool) ?? true
        goniometerColorHex = (d.object(forKey: Keys.goniometerColorHex) as? String) ?? Defaults.goniometerColorHex
    }

    /// Resets just the Target/Leveling tab's fields.
    func resetTargetDefaults() {
        targetMode = Defaults.targetMode
        fixedStandardLUFS = Defaults.fixedStandardLUFS
        tpConstraintHandling = Defaults.tpConstraintHandling
        truePeakCeilingDBTP = Defaults.truePeakCeilingDBTP
    }

    /// Resets just the Spectral QC tab's fields.
    func resetSpectralDefaults() {
        spectralOutlierThresholdDB = Defaults.spectralOutlierThresholdDB
        spectrumReference = Defaults.spectrumReference
    }

    /// Resets just the Goniometer tab's fields.
    func resetGoniometerDefaults() {
        goniometerColorHex = Defaults.goniometerColorHex
    }
}
