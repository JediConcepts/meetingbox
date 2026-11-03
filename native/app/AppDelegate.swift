import AppKit

/// The app: the menu bar item, the floating button and the meetingbox window over `AppModel`. The
/// preferences window is a later task.
///
/// One instance at a time: the first takes `~/.meetingbox/app.lock` and keeps it for its life. A
/// second launch cannot take it, so it asks the first to `show` and quits without a trace.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var floatingPanel: FloatingPanel?
    private var libraryWindow: LibraryWindow?
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
        model.onOpenLibrary = { [weak self] in self?.showLibrary() }
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

    /// Closing the meetingbox window leaves the app running: the menu bar item and the recorder are the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon (or opening the app again from Finder) opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return false
    }

    /// The window is made the first time it is wanted, then brought forward.
    private func showLibrary() {
        guard let model = model else { return }
        if libraryWindow == nil { libraryWindow = LibraryWindow(model: model) }
        libraryWindow?.show()
    }
}
