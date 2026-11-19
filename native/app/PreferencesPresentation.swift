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

/// What `meetingbox engines` said. Everything is unknown until it answers. `outside` is the listing of
/// the source it was asked about (`engines --kind K --address A`), nil when it has no `outside` line.
struct EngineStatus: Equatable {
    var parakeet: EngineAvailability = .unknown
    var apple: EngineAvailability = .unknown
    var voice: VoiceState = .unknown
    var outsideRuntime: EngineAvailability = .unknown
    var outside: SourceListing? = nil
}

/// The models a source listed, or why it could not list them.
struct SourceListing: Equatable {
    var models: [String]
    var error: String?
}

/// One entry of "Write the minutes with": Apple's model (`writer` nil) or an outside one, its words, and
/// whether it can be chosen.
struct WriterOption: Equatable {
    let writer: OutsideWriter?
    let title: String
    let available: Bool
}

extension PreferencesPresentation {
    static let transcriberNote = "Applies to the next meeting processed."
    static let parakeetMissing = "Parakeet is not set up, so Apple's transcriber is used. Run meetingbox setup."
    static let tidyTitle = "Tidy transcript lines (drop 'um' and 'uh', keep short replies inline)"
    static let yourNameLabel = "Your name"
    static let nameInvalid = "Use letters, spaces, hyphens and apostrophes, up to 40 characters."
    static let nameReserved = "That name is used as a label. Choose another."
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
    static let sampleMicrophoneFailed = "The microphone stopped working, so the voice sample was not used. Record again."

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

    /// Reads `meetingbox engines`: the `parakeet`, `apple`, `voice` and `outside-runtime` lines, and with a
    /// source (`engines --kind K --address A`) its `outside model <id>`, `outside none` or `outside error
    /// <reason>` lines, the reason taken as given. A line it cannot read, or one that is not there, leaves
    /// what it would say unknown; a model id outside the engine's model rule is dropped.
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
            case "outside": status.outside = outside(rest, status.outside)
            default: continue
            }
        }
        return status
    }

    /// One `outside` line added to the listing so far: `model <id>`, `none` or `error <reason>`. An error
    /// is the listing, whatever else it said.
    private static func outside(_ text: Substring, _ listing: SourceListing?) -> SourceListing? {
        if let error = listing?.error { return SourceListing(models: [], error: error) }
        if text == "none" { return SourceListing(models: listing?.models ?? [], error: nil) }
        if text.hasPrefix("model ") {
            let id = String(text.dropFirst("model ".count))
            var models = listing?.models ?? []
            if modelNameProblem(id) == nil && !models.contains(id) { models.append(id) }
            return SourceListing(models: models, error: nil)
        }
        if text.hasPrefix("error ") {
            let reason = text.dropFirst("error ".count).trimmingCharacters(in: .whitespaces)
            return reason.isEmpty ? listing : SourceListing(models: [], error: reason)
        }
        return listing
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

// MARK: - the minutes writer: sources, their models, the address rule and agreement

extension PreferencesPresentation {
    // The words, as spec 6.5 and the plan's "Copy, fixed" have them.
    static let writerLabel = "Write the minutes with"
    static let appleWriter = "Apple, on this Mac"
    static let runsOnline = " (runs online)"
    static let notAvailable = " (not available)"
    static let modelNameLabel = "Model name"
    static let addSourceTitle = "Add…"
    static let removeTitle = "Remove"
    static let setKeyTitle = "Set…"
    static let checkTitle = "Check"
    static let setKeyFirst = "Set a key for this source first."
    static let noSources = "To use another model, add a source: the Claude API with your key, or a standard address such as Ollama (http://127.0.0.1:11434/v1) or the Local CLI Bridge."
    static let outsideNeedsNode = "Outside models need Node 20 or later. Run meetingbox setup."
    static let staysOnMac = "Transcripts stay on this Mac."
    static let cancelTitle = "Cancel"
    static let consentCancel = cancelTitle
    /// The engine's own refusal of a key (`meetingbox key set`), so the sheet and the engine say the same.
    static let keyRefused = "That key is not one meetingbox accepts: a key is 1 to 4096 letters, digits and . _ ~ + / = -"
    static let claudeAddress = "https://api.anthropic.com"
    /// The kinds a source can be, in the order the source sheet offers them.
    static let kinds: [SourceKind] = [.claude, .standard]

    // Words this task adds (the report lists them for the docs).
    static let editSourceTitle = "Edit…"
    static let useModelTitle = "Use"
    static let addSourceSheetTitle = "Add a source"
    static let editSourceSheetTitle = "Change a source"
    static let kindLabel = "Kind"
    static let addressLabel = "Address"
    static let addButton = "Add"
    static let saveButton = "Save"
    static let keyLabel = "Key"
    static let setKeyButton = "Set"
    static let addressRefused = "That address is not one meetingbox accepts. Use https:// with a host name in lower case, or an IPv6 address written short, such as [2001:db8::1]; http:// is for 127.0.0.1, localhost and [::1] only. An address has no @, ? or #."
    static let addressTaken = "Another source already has that address."
    static let modelNameRefused = "That model name is not one meetingbox accepts: a name is 1 to 200 letters, digits and . _ : / + @ -"
    /// The engine's reasons this file reads or gives itself (the engine says them in these words too).
    static let askedForKey = "it asked for a key"
    static let listingTimedOut = "it did not answer within 10 seconds"
    static let unexpectedAnswer = "it gave an unexpected answer"

    static func kindTitle(_ kind: SourceKind) -> String {
        switch kind {
        case .claude: return "Claude API"
        case .standard: return "Standard (Ollama, LM Studio, Local CLI Bridge)"
        }
    }

    /// What a new source's address starts at: the Claude API's own, or nothing for a Standard one.
    static func defaultAddress(_ kind: SourceKind) -> String { kind == .claude ? claudeAddress : "" }

    /// Whether a key is stored, read without reading it: nil while not known (not read yet, or the
    /// keychain could not be read, which is never "none").
    static func keyLine(_ set: Bool?) -> String? { set.map { $0 ? "Key: set" : "Key: none" } }

    static func keySheetTitle(host: String) -> String { "Key for \(host)" }

    static func sourceSheetTitle(adding: Bool) -> String { adding ? addSourceSheetTitle : editSourceSheetTitle }
    static func sourceSheetButton(adding: Bool) -> String { adding ? addButton : saveButton }

    /// Beside a source's Model name field: "at <host>", as "<model> at <host>" reads once it is chosen.
    static func atHost(_ address: String) -> String { "at \(shownHost(address))" }

    /// A key Remove could not remove: the engine's line, and that it may still be there.
    static func keyNotRemoved(_ line: String) -> String { line + " It may still be there." }

    /// A key that could not be removed with its source (removed, or given a new address).
    static func oldKeyLeft(address: String) -> String {
        "The key for \(address) could not be removed from the keychain. It may still be there."
    }

    /// An outside writer whose source has gone or changed, chosen or committed again.
    static func writerGone(_ writer: OutsideWriter) -> String {
        "\(writer.model) at \(shownHost(writer.address)) cannot be used: its source was removed or changed. Choose another."
    }

    // MARK: the address rule (spec section 5, tests/fixtures/addresses.txt)

    private static let lower = Set("abcdefghijklmnopqrstuvwxyz".utf8)
    private static let digits = Set("0123456789".utf8)
    private static let hexDigits = Set("0123456789abcdef".utf8)
    private static let pathBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~!$&()*+,;=:%/-".utf8)
    private static let keyBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/=-".utf8)
    private static let modelBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/+@-".utf8)
    private static let localHosts = ["127.0.0.1", "localhost", "[::1]"]

    /// The host an address names, as the rule parses it (an IPv6 literal with its brackets), or nil when
    /// the rule refuses the address. The same rule as the engine's `address_ok` and writer.mjs's
    /// `addressHost`: at most 2048 characters; lower-case `https://` or `http://`; then a host with an
    /// optional `:port` (1 to 65535, no leading zero); then an optional path of RFC 3986 characters less
    /// `'` and `@`. `http` only for 127.0.0.1, localhost and [::1], exactly; `https` for a lower-case DNS
    /// name or a bracketed IPv6 literal as the URL parser writes it. Every host shown is this one.
    static func host(of address: String) -> String? {
        let bytes = Array(address.utf8)
        guard !bytes.isEmpty, bytes.count <= 2048 else { return nil }
        let secure: Bool
        let rest: ArraySlice<UInt8>
        if bytes.starts(with: "https://".utf8) {
            secure = true
            rest = bytes.dropFirst(8)
        } else if bytes.starts(with: "http://".utf8) {
            secure = false
            rest = bytes.dropFirst(7)
        } else {
            return nil
        }
        let slash = rest.firstIndex(of: UInt8(ascii: "/"))
        let authority = rest[..<(slash ?? rest.endIndex)]
        guard rest[(slash ?? rest.endIndex)...].allSatisfy(pathBytes.contains) else { return nil }
        let host: ArraySlice<UInt8>
        var port: ArraySlice<UInt8>?
        if authority.first == UInt8(ascii: "[") {
            guard let close = authority.firstIndex(of: UInt8(ascii: "]")) else { return nil }
            host = authority[...close]
            let after = authority[(close + 1)...]
            if !after.isEmpty {
                guard after.first == UInt8(ascii: ":") else { return nil }
                port = after.dropFirst()
            }
            guard ipv6(host.dropFirst().dropLast()) else { return nil }
        } else if let colon = authority.firstIndex(of: UInt8(ascii: ":")) {
            host = authority[..<colon]
            port = authority[(colon + 1)...]
        } else {
            host = authority
        }
        if let port = port {
            guard (1...5).contains(port.count), port.first != UInt8(ascii: "0"), port.allSatisfy(digits.contains),
                  let number = Int(String(decoding: port, as: UTF8.self)), number <= 65535 else { return nil }
        }
        let name = String(decoding: host, as: UTF8.self)
        if !secure { return localHosts.contains(name) ? name : nil }
        if host.first == UInt8(ascii: "[") { return name }
        return dnsName(host) ? name : nil
    }

    /// Nil for an address the rule accepts; else why not.
    static func addressProblem(_ address: String) -> String? {
        host(of: address) == nil ? addressRefused : nil
    }

    static let endpointHint = "This looks like a full endpoint. Use the address up to /v1, for example http://127.0.0.1:8787/v1."

    /// A hint, not a refusal, for an address pasted as a full endpoint: one ending in `/chat/completions` or
    /// `/models`, with or without a trailing slash, in any case. meetingbox adds those itself, so every run
    /// would ask for `.../chat/completions/chat/completions`. The address rule is unchanged.
    static func addressHint(_ address: String) -> String? {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if a.hasSuffix("/") { a.removeLast() }
        return a.hasSuffix("/chat/completions") || a.hasSuffix("/models") ? endpointHint : nil
    }

    /// The host an address shows as: the rule's, or the address itself for one it refuses (only ever a
    /// setting written by hand).
    static func shownHost(_ address: String) -> String { host(of: address) ?? address }

    /// Two addresses name the same source once any trailing slashes are dropped.
    static func sameAddress(_ a: String, _ b: String) -> Bool {
        let bare = { (s: String) in String(s.reversed().drop { $0 == "/" }.reversed()) }
        return bare(a) == bare(b)
    }

    /// Lower-case labels of letters, digits and hyphens, 1 to 63 each and not starting or ending with a
    /// hyphen, at most 253 characters in all, the last of which has a letter and is not 0x followed only
    /// by hex digits: so never a number to the URL parser, an IPv4 literal in any spelling included.
    private static func dnsName(_ host: ArraySlice<UInt8>) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        let hyphen = UInt8(ascii: "-")
        guard labels.allSatisfy({ label in
            (1...63).contains(label.count) && label.first != hyphen && label.last != hyphen
                && label.allSatisfy { lower.contains($0) || digits.contains($0) || $0 == hyphen }
        }), let last = labels.last, last.contains(where: lower.contains) else { return false }
        return !(last.starts(with: "0x".utf8) && last.dropFirst(2).allSatisfy(hexDigits.contains))
    }

    /// Lower-case hex groups of 1 to 4 digits, eight of them or at most seven around one "::", written as
    /// the URL parser writes them: no leading zero, and the first longest run of two or more zero groups,
    /// and only that, as "::". No zone and no embedded IPv4.
    private static func ipv6(_ text: ArraySlice<UInt8>) -> Bool {
        guard !text.isEmpty, text.allSatisfy({ hexDigits.contains($0) || $0 == UInt8(ascii: ":") }) else { return false }
        let s = String(decoding: text, as: UTF8.self)
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        let parts = halves.map { $0.isEmpty ? [] : $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
        let groups = parts.flatMap { $0 }
        guard groups.allSatisfy({ (1...4).contains($0.count) }), halves.count == 2 ? groups.count <= 7 : groups.count == 8 else { return false }
        let pieces = halves.count == 2 ? parts[0] + Array(repeating: "0", count: 8 - groups.count) + parts[1] : groups
        let numbers = pieces.compactMap { Int($0, radix: 16) }
        return numbers.count == 8 && canonical(numbers) == s
    }

    /// Eight groups as the URL parser writes them.
    private static func canonical(_ pieces: [Int]) -> String {
        var (start, length, i) = (-1, 0, 0)
        while i < 8 {
            guard pieces[i] == 0 else { i += 1; continue }
            var j = i
            while j < 8 && pieces[j] == 0 { j += 1 }
            if j - i > length && j - i >= 2 { (start, length) = (i, j - i) }
            i = j
        }
        let hex = pieces.map { String($0, radix: 16) }
        guard start >= 0 else { return hex.joined(separator: ":") }
        return hex[..<start].joined(separator: ":") + "::" + hex[(start + length)...].joined(separator: ":")
    }

    // MARK: keys and model names

    /// A key the engine accepts: 1 to 4096 of A-Za-z0-9._~+/=- (its `key_ok`).
    static func keyOK(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return (1...4096).contains(bytes.count) && bytes.allSatisfy(keyBytes.contains)
    }

    /// Nil for a model name the engine accepts, 1 to 200 of A-Za-z0-9._:/+@- (its `model_ok`, and the ids
    /// `engines` lists); else why not.
    static func modelNameProblem(_ name: String) -> String? {
        let bytes = Array(name.utf8)
        return (1...200).contains(bytes.count) && bytes.allSatisfy(modelBytes.contains) ? nil : modelNameRefused
    }

    // MARK: listings and the choice of writer

    /// What `engines --kind K --address A` answered, as the source's listing: its `outside` lines; past
    /// the app's limit, that; otherwise the engine's own first line, or that it gave no listing.
    static func listing(status: Int32, output: String) -> SourceListing {
        if let found = parseEngines(wholeLines(output)).outside { return found }
        if status == ScriptEngineCommands.timedOut { return SourceListing(models: [], error: listingTimedOut) }
        if status != 0 { return SourceListing(models: [], error: engineProblem(status: status, output: output)) }
        return SourceListing(models: [], error: unexpectedAnswer)
    }

    /// An engine command's output without its last line when that line was cut off: output that reached
    /// the 64 KB the app keeps (`ScriptEngineCommands.outputLimit`) and does not end with a newline. So a
    /// listing cut short never offers part of an id as a model.
    static func wholeLines(_ output: String) -> String {
        let bytes = Array(output.utf8)
        guard bytes.count >= ScriptEngineCommands.outputLimit, bytes.last != UInt8(ascii: "\n") else { return output }
        guard let end = bytes.lastIndex(of: UInt8(ascii: "\n")) else { return "" }
        return String(decoding: bytes[...end], as: UTF8.self)
    }

    /// Under a source, once it has been listed: "Found N models", "Found 1 model", or why not, with a hint
    /// when a source given no key asked for one.
    static func listingLine(_ listing: SourceListing?) -> String? {
        guard let listing = listing else { return nil }
        guard let error = listing.error else { return listing.models.count == 1 ? "Found 1 model" : "Found \(listing.models.count) models" }
        let reason = error.hasSuffix(".") ? String(error.dropLast()) : error
        return "Could not list its models: \(reason)." + (error == askedForKey ? " Set a key for this source." : "")
    }

    /// A source that lists no models, or cannot list them, gets a Model name field; one not listed yet
    /// does not, until Check or the picker lists it.
    static func showsModelField(_ listing: SourceListing?) -> Bool { listing?.models.isEmpty ?? false }

    /// "<model> at <host>", with "(runs online)" for an id ending in -cloud or :cloud.
    static func writerTitle(_ writer: OutsideWriter) -> String {
        "\(writer.model) at \(shownHost(writer.address))" + (writer.model.hasSuffix("-cloud") || writer.model.hasSuffix(":cloud") ? runsOnline : "")
    }

    /// "Write the minutes with": Apple, on this Mac, then every model of every source listed, in order.
    /// The saved choice, when it is not among them, stays at the end: plainly while its source has not
    /// listed, or cannot list, its models (a name typed in Model name), else "(not available)", as it is
    /// when its source is gone or has another kind.
    static func writerChoice(sources: [Source], listings: [String: SourceListing], saved: OutsideWriter?) -> [WriterOption] {
        var options = [WriterOption(writer: nil, title: appleWriter, available: true)]
        for source in sources {
            guard let listing = listings[source.address], listing.error == nil else { continue }
            for model in listing.models {
                let writer = OutsideWriter(kind: source.kind, address: source.address, model: model)
                options.append(WriterOption(writer: writer, title: writerTitle(writer), available: true))
            }
        }
        guard let saved = saved, !options.contains(where: { $0.writer == saved }) else { return options }
        let source = sources.first { $0.kind == saved.kind && $0.address == saved.address }
        let typed = source.map { showsModelField(listings[$0.address]) || listings[$0.address] == nil } ?? false
        options.append(WriterOption(writer: saved, title: writerTitle(saved) + (typed ? "" : notAvailable), available: typed))
        return options
    }

    /// Under the minutes writer while Node or the router cannot be used.
    static func outsideRuntimeLine(_ engines: EngineStatus) -> String? {
        if case .unavailable = engines.outsideRuntime { return outsideNeedsNode }
        return nil
    }

    /// The line under the picker, for the writer a job would use now (nil: Apple's): amber while
    /// transcripts are sent.
    static func privacyLine(writer: OutsideWriter?) -> (text: String, amber: Bool) {
        guard let writer = writer else { return (staysOnMac, false) }
        return ("Transcripts are sent to \(shownHost(writer.address)) to write the minutes. Recordings stay on this Mac. "
                + "This applies to every meeting processed, including new recordings.", true)
    }

    // MARK: agreement

    static func consentTitle(host: String) -> String { "Send transcripts to \(host)?" }

    static func consentText(address: String) -> String {
        "To write the minutes, meetingbox will send each meeting's full transcript, with its date, time and length, to \(address). "
            + "If that is a program on this Mac, it may pass it on: the Local CLI Bridge sends it to Claude or Codex under your account, "
            + "and an Ollama model whose name ends in 'cloud' runs on Ollama's servers. The transcript includes what other people said, "
            + "so make sure they are happy with that. Recordings stay on this Mac. You can switch back to Apple at any time."
    }

    static func consentButton(host: String) -> String { "Send transcripts to \(host)" }
}
