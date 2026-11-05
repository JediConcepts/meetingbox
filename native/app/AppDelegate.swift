import AppKit

/// The app: the menu bar item, the floating button, the meetingbox window and the Preferences window
/// over `AppModel`; the Dock icon; the main menu; and the one guard every quit goes through.
///
/// One instance at a time: the first takes `~/.meetingbox/app.lock` and keeps it for its life. A
/// second launch cannot take it, so it asks the first to `show` and quits without a trace.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var floatingPanel: FloatingPanel?
    private var libraryWindow: LibraryWindow?
    private var preferencesWindow: PreferencesWindow?
    /// The main menu's Recording menu and the Dock menu.
    private var recordingMenu: RecordingMenu?
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
        model.onOpenPreferences = { [weak self] in self?.showPreferences() }
        model.onVisibilityChange = { [weak self] in self?.applyVisibility() }
        self.model = model
        let recordingMenu = RecordingMenu(model: model)
        self.recordingMenu = recordingMenu
        NSApp.mainMenu = makeMainMenu(recording: recordingMenu.menu)
        // The views first, so they hear every change the launch makes.
        statusItem = StatusItem(model: model)
        floatingPanel = FloatingPanel(model: model)
        // Info.plist keeps LSUIElement, so the recorder and recovery never show in the Dock: only the
        // app, holding the lock, becomes a Dock app, and only when the setting says so.
        applyVisibility()
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown() // the socket only: a recorder still running is left to run
    }

    /// Closing the meetingbox or Preferences window leaves the app running: the menu bar item and the recorder are the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon (or opening the app again from Finder) opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return false
    }

    /// The Dock menu: the recording entries that apply now, so recording never depends on the menu
    /// bar item being shown. Asked for each time it opens.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        recordingMenu?.dockMenu()
    }

    // MARK: quitting

    /// The one guard: the menu's Quit, Cmd-Q, the Dock menu's Quit and a quit Apple event all come
    /// through `terminate`, and so here. `PreferencesPresentation.quit` decides: nothing recording
    /// quits at once; log out, restart or shut down keeps recording and quits without asking (asking
    /// would hold up the Mac); otherwise "A recording is running." is asked.
    ///
    /// Stop and quit sends Stop through `AppModel.perform` and answers `.terminateLater`; the answer
    /// comes once the session is idle again. Keep recording and quit touches nothing.
    ///
    /// While the alert is up, and while AppKit waits for the answer, the main run loop runs in the
    /// modal panel mode, which is a common mode, so the main queue (the session's tick queue) and the
    /// main actor are still served. That holds because a quit always arrives from an event (a menu,
    /// a key, an Apple event), never from inside a block on the main queue, where a modal loop would
    /// stall the queue (hence `AppModel.perform` never waits).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = model else { return .terminateNow }
        let reason = PreferencesPresentation.quitReason(NSAppleEventManager.shared().currentAppleEvent)
        let plan = PreferencesPresentation.quit(phase: model.session.phase, reason: reason) {
            AppDelegate.askToQuit()
        }
        if plan.stop {
            model.stopForQuit { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        switch plan.reply {
        case .now: return .terminateNow
        case .later: return .terminateLater
        case .cancel: return .terminateCancel
        }
    }

    /// "A recording is running.", with Stop and quit, Keep recording and quit, and Cancel (Escape).
    private static func askToQuit() -> QuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = PreferencesPresentation.quitMessage
        alert.informativeText = PreferencesPresentation.quitInformation
        for title in PreferencesPresentation.quitButtons { alert.addButton(withTitle: title) }
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        // Quit can come from the menu bar item while another app is in front: the question comes forward.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return PreferencesPresentation.quitChoice(button: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }

    // MARK: windows, the Dock icon and the main menu

    /// The window is made the first time it is wanted, then brought forward.
    private func showLibrary() {
        guard let model = model else { return }
        if libraryWindow == nil { libraryWindow = LibraryWindow(model: model) }
        libraryWindow?.show()
    }

    private func showPreferences() {
        guard let model = model else { return }
        if preferencesWindow == nil { preferencesWindow = PreferencesWindow(model: model) }
        preferencesWindow?.show()
    }

    @objc private func openPreferences(_ sender: Any?) { showPreferences() }

    /// The Dock icon and the menu bar item as `AppModel.visibility` says, at once. Only the app runs
    /// this, never the recorder or recovery.
    private func applyVisibility() {
        guard let model = model else { return }
        let shown = model.visibility
        statusItem?.isShown = shown.menuBarItem
        let policy: NSApplication.ActivationPolicy = shown.dockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Leaving the Dock can send the app behind the others: the Preferences window that did it stays in front.
        if policy == .accessory { preferencesWindow?.keepInFront() }
    }

    /// The app menu (Preferences… on Cmd-comma, Hide, and Quit on Cmd-Q, which goes through the quit
    /// guard); the Recording menu (`RecordingMenu`, the recording entries that apply now); and Edit and
    /// Window menus so text fields and windows take the usual keys.
    private func makeMainMenu(recording: NSMenu) -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = modifiers
            return menuItem
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }
        let preferences = item("Preferences…", #selector(openPreferences(_:)), ",")
        preferences.target = self
        let main = NSMenu()
        main.addItem(submenu("meetingbox", [
            preferences, .separator(),
            item("Hide meetingbox", #selector(NSApplication.hide(_:)), "h"), .separator(),
            item("Quit meetingbox", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        let recordingHolder = NSMenuItem(title: recording.title, action: nil, keyEquivalent: "")
        recordingHolder.submenu = recording
        main.addItem(recordingHolder)
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu("Window", [
            item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}
