import SwiftUI
import AppKit

/// Custom About window (not the native panel) — kept consistent with the
/// rest of the series' About windows (same fullSizeContentView/no-title-bar
/// treatment as Session Prep) rather than the OS's default panel styling.
struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 10) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }
            Text("Session Close")
                .font(.system(size: 16, weight: .semibold))
            Text("Version \(appVersion)")
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.75))
            Text("Copyright © 2026 Michael Hanson.\nAll rights reserved.")
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34) // clears the traffic lights — see fullSizeContentView in SessionCloseApp
        .padding(.bottom, 20)
        .frame(width: 320, height: 260)
        .background(
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }
}
