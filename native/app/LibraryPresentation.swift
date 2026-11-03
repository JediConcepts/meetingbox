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
/// something is going on or went wrong.
struct LibraryRow: Equatable, Identifiable {
    /// The folder's path, so a row stays the same row across rescans.
    let id: String
    let title: String
    let date: String
    let length: String?
    /// The title is the user's (or an earlier version's), not the start time standing in for one.
    let titled: Bool
    let badge: LibraryBadge?

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
    /// `audio.m4a` is there: the one file a processing job runs. (A v1.2 `*_meeting.m4a` plays but is
    /// not run, so Process is not offered for it.)
    var runnable = false

    static func read(_ folder: MeetingFolder) -> MeetingFiles {
        MeetingFiles(audio: folder.audioFile,
                     runnable: FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("audio.m4a").path))
    }
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
    static func row(_ meeting: Meeting, phase: Session.Phase = .idle, processing: URL? = nil, stage: String? = nil) -> LibraryRow {
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
            case .unprocessed: badge = .unprocessed
            }
        }
        let recorded = meeting.record?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = recorded.isEmpty ? meeting.folder.displayTitle : recorded
        let titled = !recorded.isEmpty || !(meeting.folder.title ?? "").isEmpty
        // The record's length is for a finished recording; the one in progress shows its timer instead.
        let length = live ? nil : lengthText(meeting.record?.seconds ?? 0)
        return LibraryRow(id: key(url), title: title, date: dateFormatter.string(from: meeting.folder.date),
                          length: length, titled: titled, badge: badge)
    }

    static func rows(_ meetings: [Meeting], phase: Session.Phase = .idle, processing: URL? = nil, stage: String? = nil) -> [LibraryRow] {
        meetings.map { row($0, phase: phase, processing: processing, stage: stage) }
    }

    // MARK: search

    /// The meetings that match `query` (a title or a word in the transcript; blank matches all), in the
    /// order given. Reads only what `indexTranscripts` has cached, never the disk, but a long cache
    /// takes a moment to search: call it off the main queue.
    static func visible(_ meetings: [Meeting], query: String, store: MeetingStore) -> [Meeting] {
        meetings.filter { store.matches($0, query: query) }
    }

    // MARK: actions

    /// The meeting the session is on offers what the recording can be asked to do; any other offers
    /// Rename and Show in Finder, Play audio when there is audio, and Process when it was never
    /// processed or failed and has the audio a job runs.
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
        if files.runnable, meeting.state == .unprocessed || meeting.state == .failed { list.append(.process) }
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

    /// Renames the folder, then writes the title into its `meeting.json` too. Busy is decided at the
    /// moment of the rename, from the session, the queue and the record on the disk, never from a
    /// list read earlier: call it on the queue the session and the queue run on. Throws `RenameError`.
    static func rename(_ folder: MeetingFolder, to text: String, store: MeetingStore, phase: Session.Phase, current: URL?) throws -> MeetingFolder {
        let renamed = try folder.renamed(to: text) {
            isBusy(folder.url, phase: phase, current: current, recorded: recordedState(folder.url))
        }
        // The folder's name carries the title already, so a record that cannot be written is not a failed rename.
        try? store.update(renamed.url) { $0.title = renamed.title }
        return renamed
    }

    /// The words for a rename that did not happen.
    static func renameMessage(_ error: Error) -> String {
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
