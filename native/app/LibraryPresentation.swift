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
        case .finalising: return "Finalising"
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

/// What a meeting offers, in the order shown. The first three are for the meeting being recorded.
enum LibraryAction: CaseIterable, Hashable {
    case pause, resume, stop, rename, showInFinder, playAudio, process

    var title: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Stop"
        case .rename: return "Rename…"
        case .showInFinder: return "Show in Finder"
        case .playAudio: return "Play audio"
        case .process: return "Process"
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

    static func read(_ folder: MeetingFolder) -> MeetingFiles {
        MeetingFiles(audio: folder.audioFile, runnable: canRun(folder.url))
    }

    static func canRun(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path) && !MeetingFolder.recordingUnfinished(dir)
    }
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
        var problem: String? = nil
        if badge == .failed {
            problem = (meeting.record?.error ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        return LibraryRow(id: key(url), title: title, date: dateFormatter.string(from: meeting.folder.date),
                          length: length, titled: titled, badge: badge, problem: problem)
    }

    /// `processable` holds the keys of the meetings Process is offered for; nil takes every meeting to be one.
    static func rows(_ meetings: [Meeting], phase: Session.Phase = .idle, processing: URL? = nil, stage: String? = nil,
                     processable: Set<String>? = nil) -> [LibraryRow] {
        meetings.map { row($0, phase: phase, processing: processing, stage: stage,
                           processable: processable?.contains(key($0.folder.url)) ?? true) }
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

    /// The meeting the session is on offers what the recording can be asked to do; any other offers
    /// Rename and Show in Finder, Play audio when there is audio, and Process when `canProcess`.
    static func actions(for meeting: Meeting, phase: Session.Phase, files: MeetingFiles) -> [LibraryAction] {
        if let folder = phase.folder, samePlace(folder, meeting.folder.url) {
            switch phase {
            case .recording: return [.pause, .stop, .showInFinder]
            case .paused: return [.resume, .stop, .showInFinder]
            case .finalising: return [.showInFinder]
            case .idle: break
            }
        }
        var list: [LibraryAction] = [.rename, .showInFinder]
        if files.audio != nil { list.append(.playAudio) }
        if canProcess(meeting, files: files) { list.append(.process) }
        return list
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
        case .busy?: return "That meeting is busy"
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

    /// Inline markdown (bold, italic, code, links) with the line breaks and spaces kept, so the notes
    /// read as the file does; plain text when it will not parse.
    static func minutes(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
