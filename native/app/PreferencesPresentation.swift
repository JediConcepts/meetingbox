import Foundation

// What the Preferences window, the Dock icon and quitting decide, in plain values so each can be
// tested without AppKit. `AppModel` applies them; `PreferencesWindow` and `AppDelegate` only draw
// and ask. Foundation only.

/// The Dock icon and the menu bar item. Without a Dock icon the menu bar item is the way into the
/// app, so it is shown then whatever the setting says, and the setting is written back on.
struct Visibility: Equatable {
    let dockIcon: Bool
    let menuBarItem: Bool
    /// Both were off: `showMenuBar` is written back to true, so the checkbox shows what is on screen.
    let writeBackMenuBar: Bool

    /// The menu bar checkbox cannot be turned off while there is no Dock icon.
    var menuBarLocked: Bool { !dockIcon }
}

/// The three answers to "A recording is running.", in the order of their buttons.
enum QuitChoice: Equatable, CaseIterable { case stopAndQuit, keepRecordingAndQuit, cancel }

/// `NSApplication.TerminateReply` in Foundation terms: quit now, quit once told to, or do not quit.
enum QuitReply: Equatable { case now, later, cancel }

/// What a quit does: whether Stop is sent first, and how `applicationShouldTerminate` answers.
struct QuitPlan: Equatable {
    let stop: Bool
    let reply: QuitReply
}

/// One entry of the microphone menu. `name` is what is saved: nil for the system default.
struct MicrophoneOption: Equatable {
    let title: String
    let name: String?
}

struct MicrophoneChoice: Equatable {
    let options: [MicrophoneOption]
    /// The index in `options` of the saved setting.
    let selected: Int
}

enum PreferencesPresentation {
    // MARK: the Dock icon and the menu bar item

    static func visibility(showInDock: Bool, showMenuBar: Bool) -> Visibility {
        let menuBar = showMenuBar || !showInDock
        return Visibility(dockIcon: showInDock, menuBarItem: menuBar, writeBackMenuBar: menuBar && !showMenuBar)
    }

    static func floatingTitle(_ mode: FloatingMode) -> String {
        switch mode {
        case .always: return "Always"
        case .whileRecording: return "While recording"
        case .never: return "Never"
        }
    }

    // MARK: quitting

    static let quitMessage = "A recording is running."
    static let quitInformation = "Stop and quit finishes the recording first. Keep recording and quit leaves it running, and meetingbox picks it up when it opens again."
    /// In `QuitChoice.allCases` order.
    static let quitButtons = ["Stop and quit", "Keep recording and quit", "Cancel"]

    /// The choice for the alert's button `index` (0 is the first). Anything else, such as Escape, is Cancel.
    static func quitChoice(button index: Int) -> QuitChoice {
        QuitChoice.allCases.indices.contains(index) ? QuitChoice.allCases[index] : .cancel
    }

    /// Asked while a recording is running or paused; a start still in its grace is already recording.
    /// Idle has nothing to lose, and a recording that is finalising finishes on its own: the recorder
    /// outlives the app, and the next launch takes up what it leaves.
    static func asksToQuit(_ phase: Session.Phase) -> Bool {
        switch phase {
        case .recording, .paused: return true
        case .idle, .finalising: return false
        }
    }

    /// The `keyAEQuitReason` values of a quit sent by log out, restart or shut down (AERegistry.h):
    /// kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart,
    /// kAEShutDown and kAEQuitAll. Asking then would hold up the Mac.
    static let systemQuitReasons: Set<UInt32> = Set(["logo", "rlgo", "rrst", "rsdn", "rest", "shut", "quia"].map(fourCharCode))

    static func isSystemQuit(_ reason: UInt32?) -> Bool {
        reason.map(systemQuitReasons.contains) ?? false
    }

    /// Stop and quit sends Stop and answers later, once the session is idle; Keep recording and quit
    /// quits now and touches nothing; Cancel does not quit.
    static func quitPlan(_ choice: QuitChoice) -> QuitPlan {
        switch choice {
        case .stopAndQuit: return QuitPlan(stop: true, reply: .later)
        case .keepRecordingAndQuit: return QuitPlan(stop: false, reply: .now)
        case .cancel: return QuitPlan(stop: false, reply: .cancel)
        }
    }

    /// The one quit guard: nothing running quits at once; log out, restart or shut down keeps
    /// recording and quits without asking; anything else asks (`ask` is called only then).
    static func quit(phase: Session.Phase, reason: UInt32?, ask: () -> QuitChoice) -> QuitPlan {
        guard asksToQuit(phase) else { return quitPlan(.keepRecordingAndQuit) }
        if isSystemQuit(reason) { return quitPlan(.keepRecordingAndQuit) }
        return quitPlan(ask())
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: the microphone

    static let systemDefault = "System default"
    static let notConnected = " (not connected)"

    /// The device names in the recorder's `--record -l` output: one indented line per device, the
    /// system default marked " (default)". Anything else ("No audio input devices found.") is not a
    /// device. Each name once, in order.
    static func microphoneNames(_ listing: String) -> [String] {
        var names: [String] = []
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("  ") {
            var name = line.dropFirst(2)
            if name.hasSuffix(" (default)") { name = name.dropLast(" (default)".count) }
            let text = String(name).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty && !names.contains(text) { names.append(text) }
        }
        return names
    }

    /// Runs `helper --record -l` and reads its devices. Nil when it cannot be run or does not exit 0.
    /// Waits for the helper: call it off the main queue.
    static func listMicrophones(helper: URL) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        let process = Process()
        let out = Pipe()
        process.executableURL = helper
        process.arguments = ["--record", "-l"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return microphoneNames(String(decoding: data, as: UTF8.self))
    }

    /// "System default" first, then each device. A saved microphone that is not among them still
    /// shows, and stays chosen: as "<name> (not connected)" when the devices are known, or plainly
    /// when they are not (`devices` nil: not listed yet, or the listing failed).
    static func microphoneChoice(devices: [String]?, saved: String?) -> MicrophoneChoice {
        var options = [MicrophoneOption(title: systemDefault, name: nil)]
        options += (devices ?? []).map { MicrophoneOption(title: $0, name: $0) }
        guard let saved = saved else { return MicrophoneChoice(options: options, selected: 0) }
        if let index = options.firstIndex(where: { $0.name == saved }) {
            return MicrophoneChoice(options: options, selected: index)
        }
        options.append(MicrophoneOption(title: devices == nil ? saved : saved + notConnected, name: saved))
        return MicrophoneChoice(options: options, selected: options.count - 1)
    }

    // MARK: the meetings folder

    static let folderRefused = "meetingbox cannot use that folder"
    static let folderBusy = "The folder can be changed once the recording has finished"

    /// Choose… is offered only while nothing is recording, paused or finalising: the library follows
    /// the folder, and the recording in progress must stay in it.
    static func canChooseFolder(_ phase: Session.Phase) -> Bool { phase == .idle }

    /// Nil for an existing folder this user can write to (and so make meeting folders in); else why not.
    static func folderProblem(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              access(url.path, W_OK | X_OK) == 0 else { return folderRefused }
        return nil
    }
}
