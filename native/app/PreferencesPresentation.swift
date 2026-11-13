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

    /// kCoreEventClass, kAEQuitApplication and keyAEQuitReason (AERegistry.h).
    private static let coreEventClass = fourCharCode("aevt")
    private static let quitApplication = fourCharCode("quit")
    private static let quitReasonKeyword = fourCharCode("why?")

    /// The reason a quit Apple event gives, from an attribute or a parameter, read as an enumeration
    /// or as a type code, whichever form it carries. Nil for no event (Cmd-Q, the menus), an event
    /// that is not a quit, or a quit that gives no reason.
    static func quitReason(_ event: NSAppleEventDescriptor?) -> UInt32? {
        guard let event = event, event.eventClass == coreEventClass, event.eventID == quitApplication,
              let why = event.attributeDescriptor(forKeyword: quitReasonKeyword) ?? event.paramDescriptor(forKeyword: quitReasonKeyword)
              else { return nil }
        for code in [why.enumCodeValue, why.typeCodeValue] where code != 0 { return code }
        return nil
    }

    // MARK: recording entries

    /// The recording entries of the menu bar item's menu that apply now (Start recording, or Pause or
    /// Resume, and Stop, or while the last recording is saved a disabled line in Start's place), in its
    /// order: what the Dock menu and the main menu's Recording menu offer, and what New meeting in the
    /// window follows. One source, so they never disagree.
    static func recordingEntries(_ menu: [MenuEntry]) -> [MenuEntry] {
        menu.filter { [MenuAction.start, .pause, .resume, .stop].contains($0.action) }
    }

    /// New meeting's words: what the menus put in Start's place while it cannot be chosen (Saving the
    /// last recording…), else New meeting.
    static func newMeetingTitle(_ entries: [MenuEntry]) -> String {
        entries.first { $0.action == .start && !$0.enabled }?.title ?? "New meeting"
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

    /// Runs `helper --record -l` and reads its devices. Nil when it cannot be run, does not exit 0, or
    /// has not finished within `timeout`; then it is ended with SIGKILL (the recorder ignores SIGTERM
    /// from its first line), from a background queue. Waits for the helper: call it off the main queue.
    static func listMicrophones(helper: URL, timeout: TimeInterval = 5) -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        let process = Process()
        let out = Pipe()
        process.executableURL = helper
        process.arguments = ["--record", "-l"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let giveUp = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: giveUp)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        giveUp.cancel()
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

    /// Under the meetings folder: a new folder is where new recordings go and what the window lists.
    static let folderMovesNothing = "Choosing a new folder moves nothing: meetings already recorded stay where they are, and the window lists only the folder chosen here."
    static let folderRefused = "meetingbox cannot use that folder"
    static let folderBusy = "The folder can be changed once the recording has finished"
    static let folderStillFinishing = "Some meetings in the current folder are still being finished. Try again when they are done."

    /// A meeting in the folder is in progress: queued, processing, recording or finalising. Moving away
    /// then would leave it where neither the queue nor recovery looks. A recording the recorder never
    /// finished that is failed or never processed does not count: nothing finishes it on its own, in
    /// this folder or any other (`meetingbox recover` does), so waiting would not help.
    static func stillFinishing(_ meetings: [Meeting]) -> Bool {
        meetings.contains { [MeetingState.queued, .processing, .recording, .finalising].contains($0.state) }
    }

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

// MARK: - transcripts: the transcriber, tidying and the user's voice

/// One line of `meetingbox engines` about something the engine needs: ready, unavailable with its
/// reason, or not said (yet).
enum EngineAvailability: Equatable {
    case unknown
    case ready
    case unavailable(String)
}

/// The voice print as `engines` reports it: not said (yet), none, or its whole seconds, the meetings
/// that made it, and whether it began from a recorded sample.
enum VoiceState: Equatable {
    case unknown
    case none
    case print(seconds: Int, meetings: Int, sample: Bool)
}

/// What `meetingbox engines` said. Everything is unknown until it answers.
struct EngineStatus: Equatable {
    var parakeet: EngineAvailability = .unknown
    var apple: EngineAvailability = .unknown
    var voice: VoiceState = .unknown
    var outsideRuntime: EngineAvailability = .unknown
}

extension PreferencesPresentation {
    static let transcriberNote = "Applies to the next meeting processed."
    static let parakeetMissing = "Parakeet is not set up, so Apple's transcriber is used. Run meetingbox setup."
    static let tidyTitle = "Tidy transcript lines (drop 'um' and 'uh', keep short replies inline)"
    static let voiceNotLearnt = "Not learnt yet: meetingbox learns it from your video calls, or record a sample"
    static let recordSampleTitle = "Record a voice sample…"
    static let forgetVoiceTitle = "Forget my voice"
    static let sampleStopTitle = "Stop"
    static let sampleDoneTitle = "Done"
    static let sampleBuilding = "Finding your voice in the sample…"
    static let sampleMicrophoneRefused = "meetingbox is not allowed to use the microphone. Allow it in System Settings, under Privacy & Security, Microphone."
    static let sampleStoppedForMeeting = "Stopped because a meeting started recording."
    static let sampleNeedsParakeet = "Parakeet is not set up, so a voice sample cannot be used. Run meetingbox setup."
    static let sampleTookTooLong = "Finding your voice in the sample took too long, so it was not used."
    static let sampleNoFolder = "The voice sample could not be recorded: meetingbox could not make a folder for it."
    static let sampleNoMicrophone = "The voice sample could not be recorded: no microphone was found."

    static func transcriberTitle(_ transcriber: Transcriber) -> String {
        switch transcriber {
        case .parakeet: return "Parakeet (more accurate)"
        case .apple: return "Apple"
        }
    }

    /// The Parakeet line, only when Parakeet is chosen and `engines` says it is unavailable.
    static func parakeetNotSetUp(transcriber: Transcriber, engines: EngineStatus) -> String? {
        guard transcriber == .parakeet, case .unavailable = engines.parakeet else { return nil }
        return parakeetMissing
    }

    /// Reads `meetingbox engines`: the `parakeet`, `apple`, `voice` and `outside-runtime` lines. A line
    /// it cannot read, or one that is not there, leaves what it would say unknown.
    static func parseEngines(_ output: String) -> EngineStatus {
        var status = EngineStatus()
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = words.first else { continue }
            let rest = words.count > 1 ? words[1] : ""
            switch name {
            case "parakeet": status.parakeet = availability(rest) ?? status.parakeet
            case "apple": status.apple = availability(rest) ?? status.apple
            case "outside-runtime": status.outsideRuntime = availability(rest) ?? status.outsideRuntime
            case "voice": status.voice = voice(rest) ?? status.voice
            default: continue
            }
        }
        return status
    }

    /// `ready`, or `unavailable <reason>`.
    private static func availability(_ text: Substring) -> EngineAvailability? {
        if text == "ready" { return .ready }
        guard text.hasPrefix("unavailable") else { return nil }
        return .unavailable(text.dropFirst("unavailable".count).trimmingCharacters(in: .whitespaces))
    }

    /// `none`, or `<seconds> <meetings> learnt|sample`.
    private static func voice(_ text: Substring) -> VoiceState? {
        if text == "none" { return VoiceState.none }
        let parts = text.split(separator: " ")
        guard parts.count == 3, let seconds = Int(parts[0]), seconds >= 0, let meetings = Int(parts[1]), meetings >= 1,
              parts[2] == "learnt" || parts[2] == "sample" else { return nil }
        return .print(seconds: seconds, meetings: meetings, sample: parts[2] == "sample")
    }

    /// Speech in whole minutes, to the nearest, with the singular.
    private static func minutes(_ seconds: Int) -> String {
        let m = Int((Double(seconds) / 60).rounded())
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    private static func calls(_ n: Int) -> String { n == 1 ? "1 call" : "\(n) calls" }

    /// The voice print in Preferences' words (spec 6.2). A sample counts as one of its meetings.
    static func voiceStatus(seconds: Int, meetings: Int, sample: Bool) -> String {
        guard sample else { return "Your voice: learnt from \(calls(meetings)) (\(minutes(seconds)) of speech)" }
        if meetings <= 1 { return "Your voice: from a recorded sample (\(minutes(seconds)) of speech)" }
        return "Your voice: from a recorded sample and \(calls(meetings - 1)) (\(minutes(seconds)) of speech)"
    }

    /// The voice line Preferences shows: nothing until the engine has said.
    static func voiceLine(_ voice: VoiceState) -> String {
        switch voice {
        case .unknown: return ""
        case .none: return voiceNotLearnt
        case .print(let seconds, let meetings, let sample): return voiceStatus(seconds: seconds, meetings: meetings, sample: sample)
        }
    }

    /// "Read aloud for 90 seconds. 0:42 left".
    static func sampleCountdown(secondsLeft: Int) -> String {
        let left = max(0, secondsLeft)
        let seconds = left % 60
        return "Read aloud for \(SampleState.seconds) seconds. \(left / 60):\(seconds < 10 ? "0" : "")\(seconds) left"
    }

    /// The first line with text in an engine command's output, or nil.
    static func firstLine(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// What `voice add` answered, in words: `sample <seconds>` is learnt; anything else fails with the
    /// engine's own line (its refusals are already Preferences' words).
    static func sampleOutcome(status: Int32, output: String) -> SampleState {
        if status == ScriptEngineCommands.timedOut { return .failed(sampleTookTooLong) }
        let line = firstLine(output)
        if status == 0, let line = line, line.hasPrefix("sample "), let seconds = Int(line.dropFirst("sample ".count)), seconds >= 0 {
            return .done("Your voice is learnt from this sample (\(minutes(seconds)) of speech).")
        }
        if status != 0, let line = line { return .failed(line) }
        return .failed("The voice sample could not be used (exit \(status)).")
    }

    /// An engine command's answer as one line for the window: its own first line, or its status.
    static func engineProblem(status: Int32, output: String) -> String {
        if status == ScriptEngineCommands.timedOut { return "meetingbox did not answer in time." }
        return firstLine(output) ?? "meetingbox could not do that (exit \(status))."
    }
}
