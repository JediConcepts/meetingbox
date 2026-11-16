import Foundation

// What the meetingbox window shows and decides, in plain values so that every part can be tested
// without AppKit or SwiftUI: a meeting's row in the sidebar, the search, which actions a meeting
// offers, when it is busy, what a rename says, and how minutes are drawn. `LibraryModel` keeps the
// window's state and `LibraryWindow` draws it; neither decides anything that is here. Foundation only.

/// The badge on a meeting's row.
enum LibraryBadge: Equatable {
    case recording, paused, finalising, queued
    /// Being processed, at `stage` when it is known (as the progress file words it).
    case processing(stage: String?)
    case failed, unprocessed

    var text: String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finalising: return "Saving"
        case .queued: return "Queued"
        case .processing(let stage): return stage.map(ProcessingQueue.label) ?? "Processing"
        case .failed: return "Failed"
        case .unprocessed: return "Unprocessed"
        }
    }
}

/// One meeting in the sidebar: the title, the start time, the length when it is known, a badge when
/// something is going on or went wrong, and for a failed meeting the reason it gives.
struct LibraryRow: Equatable, Identifiable {
    /// The folder's path, so a row stays the same row across rescans.
    let id: String
    let title: String
    let date: String
    let length: String?
    /// The title is the user's (or an earlier version's), not the start time standing in for one.
    let titled: Bool
    let badge: LibraryBadge?
    /// Why a failed meeting failed, in one line: the first with text in its record's `error`.
    let problem: String?

    /// What goes under the title: the start time (unless it is the title already) and the length.
    var caption: String {
        [titled ? date : nil, length].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What a meeting offers, in the order shown. The first three are for the meeting being recorded; the
/// last two open a sheet (`LibraryModel.beginRedo`).
enum LibraryAction: CaseIterable, Hashable {
    case pause, resume, stop, rename, showInFinder, playAudio, process, redoMinutes, transcribeAgain

    var title: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Stop"
        case .rename: return "Rename…"
        case .showInFinder: return "Show in Finder"
        case .playAudio: return "Open in QuickTime Player"
        case .process: return "Process"
        case .redoMinutes: return "Redo minutes…"
        case .transcribeAgain: return "Transcribe again…"
        }
    }
}

/// What is in a meeting's folder that decides its actions. Read off the main queue.
struct MeetingFiles: Equatable {
    /// What Play opens: `audio.m4a`, else the newest `*_meeting.m4a` of an earlier version.
    var audio: URL? = nil
    /// The queue can run this folder: `audio.m4a`, the one file a job runs, is there, and the recording
    /// is finished. (A v1.2 `*_meeting.m4a` plays but is not run; an unfinished recording, which has a
    /// working `.caf` and no `.recording-complete`, needs `meetingbox recover` first.)
    var runnable = false
    /// The recording was never finished (`MeetingFolder.recordingUnfinished`): `meetingbox recover` finishes it.
    var unfinished = false
    /// `transcript.txt` is there: Redo minutes writes the minutes from it.
    var transcript = false
    /// Another process may hold the folder's lock (`.processing`): `ProcessingLock.owner` finds a live
    /// owner, or cannot tell. A `meetingbox` run in Terminal, say; the window offers no redo meanwhile.
    var lockHeld = false
    /// Both sides, `mic.m4a` and `call.m4a`, are there (`MeetingFolder.hasBothSides`): Transcribe again asks
    /// for the room and call counts. Without them, one count for a recording kept as one file.
    var bothSides = false

    /// Reads the folder; `ps` (injectable, as in the queue) is run only when there is a lock to ask about.
    /// Call it off the main queue.
    static func read(_ folder: MeetingFolder, ps: URL = URL(fileURLWithPath: "/bin/ps"), now: Date = Date()) -> MeetingFiles {
        MeetingFiles(audio: folder.audioFile, runnable: canRun(folder.url), unfinished: MeetingFolder.recordingUnfinished(folder.url),
                     transcript: FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("transcript.txt").path),
                     lockHeld: ProcessingLock.owner(folder.url, ps: ps, now: now) != .gone, bothSides: MeetingFolder.hasBothSides(folder.url))
    }

    static func canRun(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path) && !MeetingFolder.recordingUnfinished(dir)
    }
}

/// A transcript the Transcript view's picker can show, read only: its words in the picker and its file.
struct TranscriptVersion: Equatable {
    let title: String
    let url: URL
}

/// The folder is named as it should be but its title could not be written into `meeting.json`: the list
/// shows the old title until it is, and renaming to the same text again writes only the title.
struct TitleNotSaved: Error {
    /// The folder, under its new name.
    let folder: MeetingFolder
    let underlying: Error
}

enum LibraryPresentation {
    // MARK: folders

    /// A folder's identity: its path with `.`, `..` and a trailing slash settled, and macOS's `/private`
    /// spelling of `/var`, `/tmp` and `/etc` folded into the short one, as a listing of a folder gives
    /// it. Worked out from the text alone, so a folder that has since been renamed away keeps the key
    /// it had (Foundation's own standardising looks at the disk, and says something else once it is gone).
    static func key(_ url: URL) -> String {
        let path = url.standardized.path
        for root in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix("/private" + root) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    static func samePlace(_ a: URL, _ b: URL) -> Bool { key(a) == key(b) }

    // MARK: rows

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    /// `45 s`, `42 min`, `1 h 05 min`; nil when the length is not known (no record, or none recorded yet).
    static func lengthText(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return "\(minutes / 60) h \(rest < 10 ? "0" : "")\(rest) min"
    }

    /// `phase` is the session's, `processing` and `stage` the queue's current job and its live stage.
    /// The meeting the session is on is whatever the session says; the job the queue is on is
    /// processing even if its record has not been rescanned yet; any other meeting is what its record says.
    /// A meeting that was never processed is badged Unprocessed only if `processable`, that is, only when
    /// Process is offered for it (`canProcess`): a badge is not shown for what the window cannot do.
    static func row(_ meeting: Meeting, phase: Session.Phase = .idle, processing: URL? = nil, stage: String? = nil,
                    processable: Bool = true) -> LibraryRow {
        let url = meeting.folder.url
        var badge: LibraryBadge? = nil
        var live = false
        if let folder = phase.folder, samePlace(folder, url) {
            live = true
            switch phase {
            case .recording: badge = .recording
            case .paused: badge = .paused
            case .finalising: badge = .finalising
            case .idle: break
            }
        } else if let current = processing, samePlace(current, url) {
            badge = .processing(stage: stage ?? meeting.record?.stage)
        } else {
            switch meeting.state {
            case .done: break
            case .recording: badge = .recording
            case .finalising: badge = .finalising
            case .queued: badge = .queued
            case .processing: badge = .processing(stage: meeting.record?.stage)
            case .failed: badge = .failed
            case .unprocessed: badge = processable ? .unprocessed : nil
            }
        }
        let recorded = meeting.record?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = recorded.isEmpty ? meeting.folder.displayTitle : recorded
        let titled = !recorded.isEmpty || !(meeting.folder.title ?? "").isEmpty
        // The record's length is for a finished recording; the one in progress shows its timer instead.
        let length = live ? nil : lengthText(meeting.record?.seconds ?? 0)
        let problem = badge == .failed ? firstLine(meeting.record?.error) : nil
        return LibraryRow(id: key(url), title: title, date: dateFormatter.string(from: meeting.folder.date),
                          length: length, titled: titled, badge: badge, problem: problem)
    }

    /// `processable` holds the keys of the meetings Process is offered for; nil takes every meeting to be one.
    static func rows(_ meetings: [Meeting], phase: Session.Phase = .idle, processing: URL? = nil, stage: String? = nil,
                     processable: Set<String>? = nil) -> [LibraryRow] {
        meetings.map { row($0, phase: phase, processing: processing, stage: stage,
                           processable: processable?.contains(key($0.folder.url)) ?? true) }
    }

    /// What the detail says under a meeting's title and caption: why it failed (`row.problem`), or for a
    /// done meeting that nothing is using, why its last redo did not finish (the first line of its
    /// record's `error`, until a job succeeds); for a failed recording that was never finished, how to
    /// finish it (there is no Recover in the window); and why a recording stopped early, when it did
    /// (`stopReason`).
    static func notes(for meeting: Meeting, row: LibraryRow, files: MeetingFiles) -> [String] {
        var lines: [String] = []
        if let problem = row.problem {
            lines.append(problem)
        } else if meeting.state == .done, row.badge == nil, let left = firstLine(meeting.record?.error) {
            lines.append(left)
        }
        if row.badge == .failed && files.unfinished {
            lines.append("To finish it, run: meetingbox recover \(shellWord(meeting.folder.url.path)), then choose Process here.")
        }
        if let reason = meeting.record?.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            lines.append("Recording stopped early: \(reason)")
        }
        return lines
    }

    /// The first line of `text` with anything on it, trimmed; nil when there is none.
    private static func firstLine(_ text: String?) -> String? {
        (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// A path as one word for the shell: as it is when nothing in it needs quoting, else in single quotes.
    private static func shellWord(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%,")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(plain.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: search

    /// The meetings that match `query` (a title or a word in the transcript; blank matches all), in the
    /// order given. Reads only what `indexTranscripts` has cached, never the disk, but a long cache
    /// takes a moment to search: call it off the main queue.
    static func visible(_ meetings: [Meeting], query: String, store: MeetingStore) -> [Meeting] {
        meetings.filter { store.matches($0, query: query) }
    }

    // MARK: actions

    /// Process is for a meeting that was never processed or whose run failed, and that the queue can run:
    /// it has the `audio.m4a` a job runs and its recording is finished.
    static func canProcess(_ meeting: Meeting, files: MeetingFiles) -> Bool {
        files.runnable && (meeting.state == .unprocessed || meeting.state == .failed)
    }

    /// The meeting the session is on offers what the recording can be asked to do; any other offers Rename
    /// and Show in Finder, Open in QuickTime Player when there is audio, Process when `canProcess`, and the
    /// two redos when nothing has a claim on it. Redo minutes is for a done or failed meeting with a
    /// transcript; Transcribe again for a done meeting the queue can run. A claim is the session, the
    /// queue's live job (`processing`), a busy state in its record (`isBusy`, as for a rename), or a lock
    /// another process may hold (`files.lockHeld`). Nothing is played while a recording runs or is paused:
    /// the recorder takes in the Mac's own sound, so the meeting played would be recorded into this one. A
    /// redo is offered meanwhile, since it may run while another meeting records. Reads only its arguments:
    /// never the disk, and never `ps`.
    static func actions(for meeting: Meeting, phase: Session.Phase, files: MeetingFiles, processing: URL?) -> [LibraryAction] {
        let capturing: Bool
        switch phase {
        case .recording, .paused: capturing = true
        case .idle, .finalising: capturing = false
        }
        if let folder = phase.folder, samePlace(folder, meeting.folder.url) {
            switch phase {
            case .recording: return [.pause, .stop, .showInFinder]
            case .paused: return [.resume, .stop, .showInFinder]
            case .finalising: return [.showInFinder]
            case .idle: break
            }
        }
        var list: [LibraryAction] = [.rename, .showInFinder]
        if files.audio != nil && !capturing { list.append(.playAudio) }
        if canProcess(meeting, files: files) { list.append(.process) }
        if !files.lockHeld && !isBusy(meeting.folder.url, phase: phase, current: processing, recorded: meeting.state) {
            if files.transcript && (meeting.state == .done || meeting.state == .failed) { list.append(.redoMinutes) }
            if files.runnable && meeting.state == .done { list.append(.transcribeAgain) }
        }
        return list
    }

    /// Open in QuickTime Player opens the recording there, by its bundle identifier, and never in the
    /// `.m4a` default application: that is often Music, which adds the file to its library and may
    /// upload it. Without QuickTime Player nothing is opened, and the window says why.
    static let quickTimePlayer = "com.apple.QuickTimePlayerX"
    static let needsQuickTime = "QuickTime Player is needed to play recordings"

    // MARK: the redo sheets

    /// A sheet's title, and the button that queues it: the action's words without the ellipsis.
    static func redoTitle(_ kind: JobKind) -> String {
        switch kind {
        case .minutes: return "Redo minutes"
        case .transcribe: return "Transcribe again"
        case .process: return LibraryAction.process.title
        }
    }

    static let transcriberLabel = "Transcriber"
    static let roomLabel = "People in the room, including you"
    static let callLabel = "People on the other end of the call"
    static let workItOut = "Work it out"
    /// Work it out (nil), then 1 to 6, for either side.
    static let countChoices: [Int?] = [nil] + MeetingRecord.People.range.map { Optional($0) }

    static func roomChoice(_ count: Int?) -> String {
        guard let count = count else { return workItOut }
        return count == 1 ? "1 (just you)" : String(count)
    }

    static func callChoice(_ count: Int?) -> String {
        count.map(String.init) ?? workItOut
    }

    /// The one count of a recording kept as one file (without the `mic.m4a` and `call.m4a` pair), shown in
    /// place of the two. Its one person may be someone else, so 1 is a plain "1".
    static let recordingLabel = "People in the recording"

    static func recordingChoice(_ count: Int?) -> String {
        count.map(String.init) ?? workItOut
    }

    /// Why a rename, or a redo at the click, was refused: something has a claim on the meeting.
    static let busy = "That meeting is busy"

    // MARK: transcript versions

    static let currentVersion = "Current"
    /// Transcripts another tool wrote into the folder, by their words in the picker, in this order.
    private static let namedVersions = [("transcript-parakeet.txt", "Parakeet (MLX)"), ("transcript-original.txt", "Original")]

    /// What the Transcript view's picker lists for a folder, given the names of the files in it (`files`)
    /// and of the folders in its `earlier/` that hold a `transcript.txt` (`earlier`): "Current"
    /// (`transcript.txt`) first; then `transcript-parakeet.txt` as "Parakeet (MLX)" and
    /// `transcript-original.txt` as "Original"; then every other `transcript*.txt` by file name; then
    /// "Earlier, <date> <time>" for each earlier version, newest first, a second one kept in the same
    /// minute (`-2`, `-3`) told apart as "(2)", "(3)" and listed before the first. A folder in `earlier/`
    /// not named as meetingbox names them is listed last, as "Earlier, <its name>". Control characters
    /// in a name (a newline, say) are shown as spaces.
    static func transcriptVersions(in folder: URL, files: [String], earlier: [String]) -> [TranscriptVersion] {
        var list = [TranscriptVersion(title: currentVersion, url: folder.appendingPathComponent("transcript.txt"))]
        let others = Set(files.filter { $0.hasPrefix("transcript") && $0.hasSuffix(".txt") && $0 != "transcript.txt" })
        for (name, title) in namedVersions where others.contains(name) {
            list.append(TranscriptVersion(title: title, url: folder.appendingPathComponent(name)))
        }
        for name in others.subtracting(namedVersions.map(\.0)).sorted() {
            list.append(TranscriptVersion(title: shown(name), url: folder.appendingPathComponent(name)))
        }
        let kept = earlier.map { (name: $0, stamp: EarlierStamp($0)) }
        let dated = kept.compactMap { k in k.stamp.map { (name: k.name, stamp: $0) } }
            .sorted { $0.stamp.minute != $1.stamp.minute ? $0.stamp.minute > $1.stamp.minute : $0.stamp.copy > $1.stamp.copy }
        let titled = dated.map { ($0.name, "Earlier, \($0.stamp.text)" + ($0.stamp.copy > 1 ? " (\($0.stamp.copy))" : "")) }
            + kept.filter { $0.stamp == nil }.map(\.name).sorted().map { ($0, "Earlier, \(shown($0))") }
        for (name, title) in titled {
            let url = folder.appendingPathComponent("earlier", isDirectory: true).appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("transcript.txt")
            list.append(TranscriptVersion(title: title, url: url))
        }
        return list
    }

    /// A name as one line of the picker: each control character (a newline, a tab) a space.
    private static func shown(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
    }

    /// An `earlier/` folder's name as the engine makes it, `YYYY-MM-DD HHMM`, with `-N` (2 or more, no
    /// leading zero) for a later copy kept in the same minute: the minute (which sorts as text), which
    /// copy, and the words for it. Any other name is not the engine's. The stamp is local time and is only
    /// reworded, never converted.
    private struct EarlierStamp: Equatable {
        let minute: String
        let copy: Int
        let text: String

        private static let pattern = try! NSRegularExpression(pattern: "^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{4})(?:-([2-9]|[1-9][0-9]{1,3}))?\\z")
        private static func formatter(_ format: String, _ locale: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: locale)
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = TimeZone(identifier: "UTC")
            f.isLenient = false
            f.dateFormat = format
            return f
        }
        private static let reading = formatter("yyyy-MM-dd HHmm", "en_US_POSIX")
        private static let words = formatter("d MMM yyyy HH:mm", "en_GB")

        init?(_ name: String) {
            let range = NSRange(name.startIndex..., in: name)
            guard let m = EarlierStamp.pattern.firstMatch(in: name, range: range), let minuteRange = Range(m.range(at: 1), in: name),
                  let date = EarlierStamp.reading.date(from: String(name[minuteRange])) else { return nil }
            minute = String(name[minuteRange])
            copy = Range(m.range(at: 2), in: name).flatMap { Int(name[$0]) } ?? 1
            text = EarlierStamp.words.string(from: date)
        }
    }

    // MARK: busy and rename

    /// What `meeting.json` says now, read from the disk; nil when there is no usable record.
    static func recordedState(_ folder: URL) -> MeetingState? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return MeetingRecord(json: object)?.state
    }

    /// A meeting cannot be renamed while anything has a claim on its folder: the session is on it (in
    /// any phase), the queue is running it, or its record says recording, finalising, queued or processing.
    static func isBusy(_ folder: URL, phase: Session.Phase, current: URL?, recorded: MeetingState?) -> Bool {
        if let live = phase.folder, samePlace(live, folder) { return true }
        if let current = current, samePlace(current, folder) { return true }
        switch recorded {
        case .recording?, .finalising?, .queued?, .processing?: return true
        case .done?, .failed?, .unprocessed?, nil: return false
        }
    }

    /// Makes the folder's name and its record's `title` both the typed title, and returns the folder as
    /// it is then. Normally that is a rename and then a write through `store.update`. If the folder
    /// already has the title and the record does not (an earlier write failed, or a v1.2 folder has no
    /// record), only the record is written, the folder is not moved; if both have it, nothing is touched.
    /// Busy is decided at the moment of the move or the write, from the session, the queue and the record
    /// on the disk, never from a list read earlier: call it on the queue the session and the queue run on.
    /// Throws `RenameError`, or `TitleNotSaved` when the folder is where it should be and the title could
    /// not be written; the same text again then writes only the title.
    static func rename(_ meeting: Meeting, to text: String, store: MeetingStore, phase: Session.Phase, current: URL?) throws -> MeetingFolder {
        let folder = meeting.folder
        guard let clean = MeetingFolder.safeTitle(text) else { throw RenameError.emptyTitle }
        let busy = { isBusy(folder.url, phase: phase, current: current, recorded: recordedState(folder.url)) }
        func write(to moved: MeetingFolder) throws {
            do { try store.update(moved.url) { $0.title = clean } } catch { throw TitleNotSaved(folder: moved, underlying: error) }
        }
        if clean == folder.title {
            let recorded = meeting.record?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if recorded == clean { return folder }
            if busy() { throw RenameError.busy }
            try write(to: folder)
            return folder
        }
        let renamed = try folder.renamed(to: text, isBusy: busy)
        try write(to: renamed)
        return renamed
    }

    /// The words for a rename that did not happen, or did not finish.
    static func renameMessage(_ error: Error) -> String {
        if error is TitleNotSaved { return "Renamed, but the title could not be saved" }
        switch error as? RenameError {
        case .busy?: return busy
        case .exists?: return "A meeting with that name already exists"
        case .emptyTitle?: return "Type a title"
        case nil: return "Could not rename: \(error.localizedDescription)"
        }
    }

    // MARK: minutes

    /// Finished minutes open the window on them unless a recording or a pause is under way.
    static func shouldOpenMinutes(openMinutes: Bool, phase: Session.Phase) -> Bool {
        guard openMinutes else { return false }
        switch phase {
        case .recording, .paused: return false
        case .idle, .finalising: return true
        }
    }

    /// Inline markdown (bold, italic, code) with the line breaks and spaces kept, so the notes read as the
    /// file does; plain text when it will not parse. Links are shown as plain text, never as links to
    /// click: a model wrote them, from a transcript others spoke into (spec 6.5). A link's own
    /// words stay; where it pointed is not shown.
    static func minutes(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var shown = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for range in shown.runs.filter({ $0.link != nil || $0.imageURL != nil }).map(\.range) {
            shown[range].link = nil
            shown[range].imageURL = nil
        }
        return shown
    }
}
