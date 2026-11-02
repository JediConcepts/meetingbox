import AppKit

/// The app: the menu bar item and the floating button over `AppModel`. Later tasks add the
/// library and preferences windows.
///
/// One instance at a time: the first takes `~/.meetingbox/app.lock` and keeps it for its life. A
/// second launch cannot take it, so it asks the first to `show` and quits without a trace.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var floatingPanel: FloatingPanel?
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

        let model = AppModel(stateDir: stateDir, preferences: Preferences(defaults: Preferences.appDefaults()))
        model.onShow = { NSApp.activate(ignoringOtherApps: true) }
        self.model = model
        // The views first, so they hear every change the launch makes. The menu bar item stays
        // on for now (the setting that hides it arrives with the preferences window).
        statusItem = StatusItem(model: model)
        floatingPanel = FloatingPanel(model: model)
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
    }
}
