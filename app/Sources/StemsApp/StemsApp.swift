import AppKit
import SwiftUI

/// Closing the only window quits the app. Without this the process stays alive with no
/// window (and "New Window" is removed below), so the app looked dead until force-quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single shared state for the main window and Settings. Created on first
    /// access, which always happens on the main thread.
    private var _state: AppState?
    var state: AppState {
        if let s = _state { return s }
        let s: AppState = MainActor.assumeIsolated { AppState() }
        _state = s
        return s
    }

    override init() {
        super.init()
        // Dark window chrome from the first frame: without this the NSWindow
        // itself paints light before SwiftUI content arrives (white flash).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Touch the bundled Barlow faces before the first window renders, so
        // text doesn't flash once when the fallback font swaps out.
        for name in ["Barlow-Regular", "Barlow-Medium", "Barlow-SemiBold",
                     "BarlowCondensed-SemiBold", "BarlowCondensed-Bold"] {
            _ = NSFont(name: name, size: 12)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StemsCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("StemsCraft") {
            ContentView()
                .environmentObject(appDelegate.state)
                .preferredColorScheme(.dark)
        }
        // Opens at exactly the size where every element (top bar, transport, original
        // + 4 stems) is visible. Content extends under the hidden title bar.
        .defaultSize(width: Layout.defaultWidth, height: Layout.height)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            SettingsView()
                .environmentObject(appDelegate.state)
        }
    }
}
