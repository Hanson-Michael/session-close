import Foundation

/// How the batch's target Integrated LUFS is chosen. Shipped as selectable
/// modes rather than one hard-coded default — see Session-Close-Concept.md
/// "Decisions (resolved) #1". The user can switch modes any time before
/// confirming; switching modes recomputes the proposed target and every
/// file's suggested gain, but never applies anything by itself.
enum TargetMode: String, CaseIterable, Identifiable {
    /// Match everyone to a single user-flagged reference track (see
    /// AudioFileRecord.isReferenceTrack). Falls back to "no target" if
    /// nothing's flagged yet.
    case referenceTrack = "Reference Track"
    /// Match everyone to the batch's average Integrated LUFS.
    case batchAverage = "Batch Average"
    /// Match everyone to the loudest file's Integrated LUFS (gain-down-only
    /// for the rest, absent a TP constraint forcing otherwise).
    case loudestFile = "Loudest File"
    /// Match everyone to a fixed external standard (e.g. -14 LUFS for
    /// streaming), independent of what's actually in the batch.
    case fixedStandard = "Fixed Standard"

    var id: String { rawValue }

    var helpText: String {
        switch self {
        case .referenceTrack:
            return "Every file is leveled to match the LUFS of whichever track is flagged as the reference."
        case .batchAverage:
            return "Target is the average Integrated LUFS across every scanned file."
        case .loudestFile:
            return "Target is the loudest file's Integrated LUFS — every other file is gained down toward it."
        case .fixedStandard:
            return "Target is a fixed LUFS value you set, independent of what's in the batch."
        }
    }
}

/// What happens when a file's desired gain would push it past the True Peak
/// ceiling. Neither behavior is a fixed default — see Session-Close-Concept.md
/// "Decisions (resolved) #2" — this is a standing, user-editable toggle.
enum TPConstraintHandling: String, CaseIterable, Identifiable {
    /// Lower the whole batch's target LUFS until every file fits under the
    /// TP ceiling at the (now-lower) target, surfacing which file forced it.
    case lowerBatchTarget = "Lower Batch Target"
    /// Leave the constrained file short of the confirmed target (flagged in
    /// the table) while every other file still hits it.
    case flagAndLeaveShort = "Flag and Leave Short"

    var id: String { rawValue }
}
