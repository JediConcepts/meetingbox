import AppKit
import Combine

/// Everything the meetingbox window remembers: the meetings and which are listed, the selection and the
/// pane, the search, the text of the selected meeting, and the rename sheet with its text and error.
/// `AppModel` owns it and `LibraryWindow` draws it; the decisions are `LibraryPresentation`'s.
///
/// It runs on the main queue, which is also the session's and the processing queue's tick queue, so
/// reading `session.phase` and `queue.current` and calling `queue.process` here is safe. Nothing slow
/// runs on it: the scan, the transcripts, the search and the reading of a meeting's files are done on
/// two background queues and published back here, and a result that a newer request has overtaken is dropped.
@MainActor
final class LibraryModel: ObservableObject {
    enum Pane: CaseIterable {
        case minutes, transcript

        var title: String { self == .minutes ? "Minutes" : "Transcript" }
    }

    /// What the rows and the actions depend on apart from the clock: the session's phase and the queue's job.
    struct Live: Equatable {
        var phase: Session.Phase = .idle
        var processing: URL? = nil
        var stage: String? = nil
    }

    /// What the selected meeting's folder holds for the detail pane, read off the main queue.
    struct Content: Equatable {
        let key: String
        let minutes: AttributedString?
        let transcript: String?
        let files: MeetingFiles
    }

    struct RenameDraft: Equatable {
        let key: String
        var text: String
        var error: String? = nil
    }

    /// The first scan has come back, so an empty list means no meetings rather than not yet read.
    @Published private(set) var hasScanned = false
    /// Every meeting, newest first, as the last scan found them.
    @Published private(set) var meetings: [Meeting] = []
    /// The ones the search lets through.
    @Published private(set) var visible: [Meeting] = []
    /// The keys of the meetings Process is offered for (never processed or failed, with the audio a job
    /// runs and a finished recording), worked out by each scan off the main queue.
    @Published private(set) var processable: Set<String> = []
    @Published private(set) var live = Live()
    /// The selected meeting's folder, as a `LibraryPresentation.key`.
    @Published private(set) var selection: String?
    @Published private(set) var content: Content?
    @Published private(set) var searchText = ""
    @Published var pane: Pane = .minutes
    @Published private(set) var renaming: RenameDraft?

    private let store: MeetingStore
    private let session: Session
    private let queue: ProcessingQueue
    /// Pause, resume and stop: `AppModel.perform`, so they take the path every recording command takes.
    var control: (@MainActor (MenuAction) -> Void)?

    private let reader = DispatchQueue(label: "meetingbox.library.read", qos: .userInitiated)
    private let searcher = DispatchQueue(label: "meetingbox.library.search", qos: .userInitiated)
    private var scanToken = 0
    private var searchToken = 0
    private var loadToken = 0
    /// The store has read the transcripts of the meetings in `meetings`. Cleared by each scan.
    private var indexed = false

    init(store: MeetingStore, session: Session, queue: ProcessingQueue) {
        self.store = store
        self.session = session
        self.queue = queue
    }

    // MARK: what the views read

    var selectedMeeting: Meeting? {
        guard let selection = selection else { return nil }
        return meetings.first { LibraryPresentation.key($0.folder.url) == selection }
    }

    var rows: [LibraryRow] {
        LibraryPresentation.rows(visible, phase: live.phase, processing: live.processing, stage: live.stage, processable: processable)
    }

    func row(_ meeting: Meeting) -> LibraryRow {
        LibraryPresentation.row(meeting, phase: live.phase, processing: live.processing, stage: live.stage,
                                processable: processable.contains(LibraryPresentation.key(meeting.folder.url)))
    }

    /// The selected meeting's text, once it has been read (not the previous selection's).
    var shownContent: Content? {
        content?.key == selection ? content : nil
    }

    func actions(for meeting: Meeting) -> [LibraryAction] {
        let files = content?.key == LibraryPresentation.key(meeting.folder.url) ? (content?.files ?? MeetingFiles()) : MeetingFiles()
        return LibraryPresentation.actions(for: meeting, phase: live.phase, files: files)
    }

    // MARK: loading

    /// Scans the Meetings folder off the main queue. Called after a job, after a rename, when the
    /// window becomes key, and when the session changes phase (a new recording appears at once).
    func reload() {
        scanToken += 1
        let token = scanToken
        let store = self.store
        reader.async { [weak self] in
            let found = store.scan()
            // Only the meetings that were never processed or failed need their folders looked at.
            let processable = Set(found.filter { ($0.state == .unprocessed || $0.state == .failed) && MeetingFiles.canRun($0.folder.url) }
                .map { LibraryPresentation.key($0.folder.url) })
            Task { @MainActor in self?.scanned(found, processable, token) }
        }
    }

    private func scanned(_ found: [Meeting], _ canProcess: Set<String>, _ token: Int) {
        guard token == scanToken else { return }
        hasScanned = true
        processable = canProcess
        meetings = found
        indexed = false
        refilter()
        loadContent()
    }

    /// Reads the selected meeting's minutes and transcript, and what it has to play, off the main queue.
    private func loadContent() {
        loadToken += 1
        let token = loadToken
        guard let folder = selectedMeeting?.folder, let key = selection else {
            content = nil
            return
        }
        reader.async { [weak self] in
            func read(_ name: String) -> String? { try? String(contentsOf: folder.url.appendingPathComponent(name), encoding: .utf8) }
            let loaded = Content(key: key, minutes: read("notes.md").map(LibraryPresentation.minutes),
                                 transcript: read("transcript.txt"), files: MeetingFiles.read(folder))
            Task { @MainActor in self?.loaded(loaded, token) }
        }
    }

    private func loaded(_ new: Content, _ token: Int) {
        guard token == loadToken, content != new else { return }
        content = new
    }

    // MARK: search

    func search(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        refilter()
    }

    /// A blank search lists every meeting at once. Otherwise the transcripts are indexed (once per scan),
    /// then the meetings are matched, both off the main queue and one search after another, so a later
    /// keystroke never reads a half-built index.
    private func refilter() {
        searchToken += 1
        let token = searchToken
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            visible = meetings
            return
        }
        let snapshot = meetings
        let store = self.store
        let needsIndex = !indexed
        indexed = true
        searcher.async { [weak self] in
            if needsIndex {
                let built = DispatchSemaphore(value: 0)
                store.indexTranscripts { built.signal() }
                built.wait()
            }
            let found = LibraryPresentation.visible(snapshot, query: query, store: store)
            Task { @MainActor in self?.filtered(found, token) }
        }
    }

    private func filtered(_ found: [Meeting], _ token: Int) {
        guard token == searchToken else { return }
        visible = found
    }

    // MARK: selection

    func select(_ key: String?) {
        guard key != selection else { return }
        selection = key
        loadContent()
    }

    /// The window is asked to show this meeting's minutes (a job finished, or "Minutes ready" was
    /// chosen): the search is cleared so the meeting is in the list, and the list is read again.
    func show(_ dir: URL) {
        searchText = ""
        pane = .minutes
        selection = LibraryPresentation.key(dir)
        refilter()
        loadContent()
        reload()
    }

    /// The session or the queue moved on. A new phase is a new list: a recording that has just begun
    /// is a meeting, and one that has just ended has its length.
    func update(_ status: StatusInput) {
        let next = Live(phase: status.phase, processing: status.processing, stage: status.stage)
        guard next != live else { return }
        let phaseChanged = next.phase != live.phase
        live = next
        if phaseChanged { reload() }
    }

    // MARK: actions

    func perform(_ action: LibraryAction) {
        guard let meeting = selectedMeeting else { return }
        switch action {
        case .pause: control?(.pause)
        case .resume: control?(.resume)
        case .stop: control?(.stop)
        case .rename: beginRename()
        case .showInFinder:
            NSWorkspace.shared.open(meeting.folder.url)
        case .playAudio:
            if let audio = shownContent?.files.audio { NSWorkspace.shared.open(audio) }
        case .process:
            // A failed meeting goes through retry; one that was never processed is written queued first.
            if meeting.state == .failed { queue.retry(meeting.folder.url) } else { queue.process(meeting.folder.url) }
            reload()
        }
    }

    // MARK: rename

    /// The sheet opens with the title as it is, or empty for a meeting that has none.
    func beginRename() {
        guard let meeting = selectedMeeting else { return }
        let row = self.row(meeting)
        renaming = RenameDraft(key: row.id, text: row.titled ? row.title : "")
    }

    func renameText(_ text: String) {
        guard renaming != nil else { return }
        renaming?.text = text
        renaming?.error = nil
    }

    func cancelRename() {
        renaming = nil
    }

    /// Renames on this queue, the one the session and the processing queue run on, so that busy is
    /// decided at the moment of the rename (`LibraryPresentation.rename` says what is written where). A
    /// refusal is shown in the sheet, in words. If the folder moved but its title could not be saved, the
    /// sheet stays open with that said and follows the folder, and the same text again writes the title.
    func commitRename() {
        guard let draft = renaming else { return }
        guard let meeting = meetings.first(where: { LibraryPresentation.key($0.folder.url) == draft.key }) else {
            renaming = nil
            return
        }
        do {
            let folder = try LibraryPresentation.rename(meeting, to: draft.text, store: store, phase: session.phase, current: queue.current)
            renaming = nil
            moved(meeting, to: folder, titled: true)
        } catch let failure as TitleNotSaved {
            moved(meeting, to: failure.folder, titled: false)
            renaming = RenameDraft(key: LibraryPresentation.key(failure.folder.url), text: draft.text, error: LibraryPresentation.renameMessage(failure))
        } catch {
            renaming?.error = LibraryPresentation.renameMessage(error)
        }
    }

    /// The list as a rename leaves it, at once and before the rescan that follows: the folder where it
    /// now is, the selection with it, and the record's title when it was written.
    private func moved(_ meeting: Meeting, to folder: MeetingFolder, titled: Bool) {
        let before = LibraryPresentation.key(meeting.folder.url)
        let patch = { (m: Meeting) -> Meeting in
            guard LibraryPresentation.key(m.folder.url) == before else { return m }
            var record = m.record
            if titled { record?.title = folder.title }
            return Meeting(folder: folder, record: record, state: m.state)
        }
        meetings = meetings.map(patch)
        visible = visible.map(patch)
        if processable.remove(before) != nil { processable.insert(LibraryPresentation.key(folder.url)) }
        if selection == before { selection = LibraryPresentation.key(folder.url) }
        loadContent()
        reload()
    }
}
