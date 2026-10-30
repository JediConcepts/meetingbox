import AppKit

/// The app, for now a menu bar item titled "meetingbox" with Quit, over `AppModel`. Later tasks
/// build the recording controls, the library and preferences on this.
///
/// One instance at a time: the first takes `~/.meetingbox/app.lock` and keeps it for its life. A
/// second launch cannot take it, so it asks the first to `show` and quits without a trace.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var lock: AppLock?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meetingbox", isDirectory: true)
        guard let lock = AppLock.take(stateDir.appendingPathComponent("app.lock")) else {
            let socket = stateDir.appendingPathComponent("control.sock")
            DispatchQueue.global(qos: .userInitiated).async {
                _ = ControlClient.send("show", to: socket, timeout: 2)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        self.lock = lock

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "meetingbox"
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit meetingbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        let model = AppModel(stateDir: stateDir, preferences: Preferences(defaults: Preferences.appDefaults()))
        model.onShow = { NSApp.activate(ignoringOtherApps: true) }
        self.model = model
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
    }
}
