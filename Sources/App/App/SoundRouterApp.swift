import AppKit
import SwiftUI

@main
struct SoundRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("SoundRouter", id: MainWindow.id) {
            MainWindow()
                .environment(delegate.state)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
        // When started at login/always-on, come up quietly in the menu bar.
        .defaultLaunchBehavior(delegate.state.config.settings.launchMode == .manual ? .presented : .suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Restart Core Audio") { delegate.state.restartAudio() }
                Button("Rebuild Routes") { delegate.state.rebuildRoutes() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(delegate.state)
        } label: {
            if delegate.state.panicMuted {
                Image(systemName: "speaker.slash.fill")
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The always-on LaunchAgent and a manual launch can race; keep a single instance.
        let me = NSRunningApplication.current
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0 != me }) {
            other.activate()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }
}
