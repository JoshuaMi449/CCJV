import SwiftUI
import AppKit

@main
struct ClaudeRecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowRegistrar {
                ContentView()
                    .frame(minWidth: 1080, minHeight: 720)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
    }
}

/// Captures the SwiftUI window-opening action for the app delegate, so a
/// closed window can be recreated when the user clicks the Dock icon.
private struct WindowRegistrar<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.onAppear {
            AppDelegate.openMainWindow = { openWindow(id: "main") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Clicking the Dock icon after the window was closed used to leave the
    /// app running with no visible window. Bring it back, or create it again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            restoreWindow(sender)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    private func restoreWindow(_ sender: NSApplication) {
        if let window = sender.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        Self.openMainWindow?()
    }
}
