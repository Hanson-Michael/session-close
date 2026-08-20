import SwiftUI
import AppKit

/// Menu structure (see Session-Close-Concept.md / README):
///   Cohezion: About Cohezion, Settings… (⌘,), Services,
///            Hide/Hide Others/Show All, Quit — everything except About and
///            Settings comes for free from SwiftUI's default macOS app
///            commands, so only those two are customized below.
///   File:   Open Folder… (⌘O) — replaces the default "New Window" slot.
///   Help:   Check for Updates…, Automatically Check for Updates (checkbox).
@main
struct CohezionApp: App {
    private static var aboutWindowController: NSWindowController?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Cohezion") {
                    // Deferred a runloop tick — building/showing a brand-new
                    // NSWindow synchronously from inside a menu action can
                    // race the menu bar's own dismissal teardown
                    // (NSMenuTrackingSession is still unwinding when the
                    // action fires). Letting that finish first before we
                    // touch AppKit/SwiftUI window machinery sidesteps the
                    // reentrancy regardless of whether it's the confirmed
                    // cause of the Xcode-only About-window crash.
                    DispatchQueue.main.async { Self.showAboutWindow() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    NotificationCenter.default.post(name: .sessionCloseOpenFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Check for Updates…") {
                    UpdateChecker.shared.check(manual: true)
                }
                Toggle("Automatically Check for Updates", isOn: $settings.automaticallyCheckForUpdates)
            }
        }

        Settings {
            SettingsView()
        }
    }

    private static func showAboutWindow() {
        if let controller = aboutWindowController, let window = controller.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "About Cohezion"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: AboutView())
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        aboutWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Utility app, single main window — quit when that window closes rather
/// than lingering as a dock-only background process, matching the rest of
/// the series' behavior.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touching .shared here creates the SPUStandardUpdaterController and
        // starts Sparkle's background update-check timer — without this,
        // "Automatically Check for Updates" silently does nothing until the
        // user happens to open the Help menu first.
        _ = UpdateChecker.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
