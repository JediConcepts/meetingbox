import AppKit

/// The app, for now a menu bar item titled "meetingbox" with Quit. Later tasks
/// build the recording controls, the library and preferences on this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "meetingbox"
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit meetingbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }
}
