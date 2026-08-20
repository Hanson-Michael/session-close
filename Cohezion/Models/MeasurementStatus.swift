import SwiftUI

/// Per-file state through the scan → measure → propose pipeline. Unlike
/// Session Prep's FileStatus (a classification with many buckets), Session
/// Close doesn't classify files — every readable file gets measured and
/// leveled the same way, so this is just where it is in that pipeline.
enum MeasurementStatus: Equatable {
    /// Queued, not yet measured (briefly, during an async batch scan).
    case pending
    /// BS.1770 pass + True Peak + spectrum all completed successfully.
    case measured
    /// Desired gain would exceed this file's True Peak headroom, and
    /// TPConstraintHandling is set to .flagAndLeaveShort — this file will
    /// be written short of the confirmed target rather than clipping.
    case tpConstrained
    /// Couldn't be decoded/read at all.
    case error(String)

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .measured: return "Measured"
        case .tpConstrained: return "TP-Limited"
        case .error: return "Error"
        }
    }

    var isMeasured: Bool {
        if case .measured = self { return true }
        if case .tpConstrained = self { return true }
        return false
    }

    var color: Color {
        switch self {
        case .pending: return .gray
        case .measured: return .blue
        case .tpConstrained: return .orange
        case .error: return .red
        }
    }
}
