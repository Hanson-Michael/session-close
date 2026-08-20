import SwiftUI

struct StatusBadge: View {
    let status: MeasurementStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.15))
        .clipShape(Capsule())
        .help(helpText)
    }

    private var helpText: String {
        if case .error(let reason) = status { return reason }
        if case .tpConstrained = status { return "Desired gain would exceed the True Peak ceiling — written short of the target instead of clipping." }
        return status.label
    }
}
