// sources: ../../app/MeetingFolder.swift ../../app/MeetingStore.swift ../../app/Session.swift ../../app/ChildRecorder.swift ../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift ../../recorder/Finalise.swift
// Meeting folders, the library store, and the recording session. Everything runs in temporary folders.
import AVFoundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("mb-app-test-\(UUID().uuidString)")
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
var counter = 0
/// A fresh empty root inside the scratch folder.
func freshRoot() -> URL {
    counter += 1
    let u = scratch.appendingPathComponent("root\(counter)")
    try! fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
    return Calendar.current.date(from: c)!
}
func make(_ root: URL, _ name: String, files: [String: String] = [:]) -> URL {
    let dir = root.appendingPathComponent(name)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (f, body) in files { try! body.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
    return dir
}
func mode(_ u: URL) -> Int {
    ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
func names(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }

// parse
do {
    let root = freshRoot()
    let a = MeetingFolder.parse(root.appendingPathComponent("2026-10-28_1508"))
    check(a != nil && a!.title == nil && a!.date == local(2026, 10, 28, 15, 8), "parse HHMM")
    let b = MeetingFolder.parse(root.appendingPathComponent("2026-10-28_150842"))
    check(b != nil && b!.date == local(2026, 10, 28, 15, 8, 42), "parse HHMMSS")
    let c = MeetingFolder.parse(root.appendingPathComponent("2026-10-28 0900 Standup"))
    check(c != nil && c!.title == "Standup" && c!.date == local(2026, 10, 28, 9, 0), "parse titled")
    let d2 = MeetingFolder.parse(root.appendingPathComponent("2026-10-28_150842-2"))
    let d3 = MeetingFolder.parse(root.appendingPathComponent("2026-10-28_150842-3"))
    check(d2 != nil && d3 != nil && d2!.date == b!.date, "parse collision forms")
    check(MeetingFolder.parse(root.appendingPathComponent("notes")) == nil, "parse rejects notes")
    check(MeetingFolder.parse(root.appendingPathComponent("2026-13-40_9999")) == nil, "parse rejects impossible date")
    check(MeetingFolder.parse(root.appendingPathComponent(".DS_Store")) == nil, "parse rejects .DS_Store")
    check(a!.displayTitle == "28 October 2026, 15:08", "displayTitle of untitled folder")
    check(c!.displayTitle == "Standup", "displayTitle of titled folder")
}

// create
do {
    let root = freshRoot()
    let when = local(2026, 10, 28, 15, 8, 42)
    let u1 = try! MeetingFolder.create(in: root, at: when)
    let u2 = try! MeetingFolder.create(in: root, at: when)
    let u3 = try! MeetingFolder.create(in: root, at: when)
    check(u1.lastPathComponent == "2026-10-28_1508", "create first uses HHMM")
    check(u2.lastPathComponent == "2026-10-28_150842", "create second uses HHMMSS")
    check(u3.lastPathComponent == "2026-10-28_150842-2", "create third uses -2")
    check(Set([u1, u2, u3].map { $0.path }).count == 3, "create gives three different folders")
    check([u1, u2, u3].allSatisfy { mode($0) == 0o700 }, "create folders are mode 0700")
    check([u1, u2, u3].allSatisfy { MeetingFolder.parse($0) != nil }, "parse reads all three")
    let u4 = try! MeetingFolder.create(in: root, at: when)
    check(u4.lastPathComponent == "2026-10-28_150842-3", "create fourth uses -3")
    let fresh = scratch.appendingPathComponent("not-yet/inner")
    check((try? MeetingFolder.create(in: fresh, at: when)) != nil, "create makes a missing root")
}

// safeTitle
do {
    check(MeetingFolder.safeTitle("  Budget/review: Q3  ") == "Budget-review- Q3", "safeTitle replaces / and :")
    check(MeetingFolder.safeTitle("   ") == nil, "safeTitle blank is nil")
    check(MeetingFolder.safeTitle("...") == nil, "safeTitle dots is nil")
    check(MeetingFolder.safeTitle(String(repeating: "a", count: 81))?.count == 80, "safeTitle cuts to 80")
}

// rename
do {
    let root = freshRoot()
    let src = make(root, "2026-10-28_1508", files: ["audio.m4a": "x", "meeting.json": "{}"])
    let f = MeetingFolder.parse(src)!
    let r = try? f.renamed(to: "Budget review", isBusy: { false })
    check(r?.url.lastPathComponent == "2026-10-28 1508 Budget review", "rename gives the titled name")
    check(r != nil && names(r!.url) == ["audio.m4a", "meeting.json"], "rename keeps the files")
    check(r?.title == "Budget review", "renamed folder carries the title")
    check(!fm.fileExists(atPath: src.path), "old name is gone after rename")

    // exists
    let root2 = freshRoot()
    let s2 = make(root2, "2026-10-28_1508", files: ["audio.m4a": "x"])
    _ = make(root2, "2026-10-28 1508 Budget review", files: ["other.txt": "y"])
    var threw: RenameError? = nil
    do { _ = try MeetingFolder.parse(s2)!.renamed(to: "Budget review", isBusy: { false }) } catch let e as RenameError { threw = e } catch {}
    check(threw == .exists, "rename over existing throws .exists")
    check(names(root2) == ["2026-10-28 1508 Budget review", "2026-10-28_1508"] && names(s2) == ["audio.m4a"], "exists leaves folders as they were")

    // busy
    var called = 0
    threw = nil
    do { _ = try MeetingFolder.parse(s2)!.renamed(to: "Other", isBusy: { called += 1; return true }) } catch let e as RenameError { threw = e } catch {}
    check(threw == .busy && called == 1, "busy throws .busy and is asked once")
    check(names(root2) == ["2026-10-28 1508 Budget review", "2026-10-28_1508"], "busy leaves folders as they were")

    // empty title
    threw = nil
    do { _ = try MeetingFolder.parse(s2)!.renamed(to: " ... ", isBusy: { false }) } catch let e as RenameError { threw = e } catch {}
    check(threw == .emptyTitle, "empty title throws .emptyTitle")
}

// audioFile
do {
    let root = freshRoot()
    let a = make(root, "2026-10-27_1500", files: ["2026-10-27_1500_meeting.m4a": "x"])
    check(MeetingFolder.parse(a)!.audioFile?.lastPathComponent == "2026-10-27_1500_meeting.m4a", "audioFile falls back to _meeting.m4a")
    let older = make(root, "2026-10-27_1600", files: ["a_meeting.m4a": "x", "b_meeting.m4a": "y"])
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.appendingPathComponent("a_meeting.m4a").path)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: older.appendingPathComponent("b_meeting.m4a").path)
    check(MeetingFolder.parse(older)!.audioFile?.lastPathComponent == "b_meeting.m4a", "audioFile picks the newest fallback")
    let b = make(root, "2026-10-27_1700", files: ["audio.m4a": "x", "z_meeting.m4a": "y"])
    check(MeetingFolder.parse(b)!.audioFile?.lastPathComponent == "audio.m4a", "audioFile prefers audio.m4a")
    let c = make(root, "2026-10-27_1800", files: ["notes.md": "n"])
    check(MeetingFolder.parse(c)!.audioFile == nil, "audioFile nil with neither")
}

// scan
do {
    let root = freshRoot()
    _ = make(root, "2026-10-27_1430", files: ["notes.md": "n"])
    _ = make(root, "2026-10-27_1500", files: ["2026-10-27_1500_meeting.m4a": "x"])
    _ = make(root, "2026-10-28 0900 Standup", files: ["meeting.json": """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Standup","started":"2026-10-28T09:00:00Z","seconds":60,"state":"queued"}
        """])
    _ = make(root, "misc")
    try! "x".write(to: root.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    let found = MeetingStore(root: root).scan()
    check(found.count == 3, "scan finds three meetings")
    check(found.map { $0.folder.url.lastPathComponent } == ["2026-10-28 0900 Standup", "2026-10-27_1500", "2026-10-27_1430"], "scan is newest first")
    check(found.map { $0.state } == [.queued, .unprocessed, .done], "scan states (queued, unprocessed, done from notes.md)")
    check(found.first?.record?.title == "Standup" && found.last?.record == nil, "scan records")
    check(MeetingStore(root: scratch.appendingPathComponent("absent")).scan().isEmpty, "scan of a missing root is empty")
}

// update
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    let id = "22222222-2222-2222-2222-222222222222"
    let f = make(root, "2026-10-28_1000", files: ["meeting.json": """
        {"id":"\(id)","title":"Old","started":"2026-10-28T10:00:00Z","seconds":5,"state":"done","participants":["Priya"],"extra":{"k":1}}
        """])
    try! store.update(f) { $0.title = "New" }
    let data = try! Data(contentsOf: f.appendingPathComponent("meeting.json"))
    let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    check(obj["title"] as? String == "New", "update changes title")
    check(obj["participants"] as? [String] == ["Priya"], "update keeps participants")
    check((obj["extra"] as? [String: Any])?["k"] as? Int == 1, "update keeps nested unknown keys")
    check(obj["id"] as? String == id && obj["state"] as? String == "done", "update keeps id and state")
    check(mode(f.appendingPathComponent("meeting.json")) == 0o600, "meeting.json is mode 0600")
    check(names(f) == ["meeting.json"], "atomic write leaves no stray files")

    // clearing an optional removes the key
    try! store.update(f) { $0.title = nil }
    let obj2 = try! JSONSerialization.jsonObject(with: Data(contentsOf: f.appendingPathComponent("meeting.json"))) as! [String: Any]
    check(obj2["title"] == nil && obj2["participants"] != nil, "update clears a nil optional")

    // no meeting.json yet
    let g = make(root, "2026-10-28_1100", files: ["notes.md": "n"])
    try! store.update(g) { $0.state = .queued }
    let gobj = try! JSONSerialization.jsonObject(with: Data(contentsOf: g.appendingPathComponent("meeting.json"))) as! [String: Any]
    check((gobj["id"] as? String).flatMap { UUID(uuidString: $0) } != nil, "update gives a folder an id")
    check(gobj["state"] as? String == "queued" && gobj["started"] is String, "new meeting.json has state and started")
    check(names(g) == ["meeting.json", "notes.md"], "new meeting.json beside existing files")

    // bad meeting.json
    let h = make(root, "2026-10-28_1200", files: ["meeting.json": "{not json"])
    let before = try! Data(contentsOf: h.appendingPathComponent("meeting.json"))
    let scanned = store.scan().first { $0.folder.url.lastPathComponent == "2026-10-28_1200" }
    check(scanned != nil && scanned!.record == nil && scanned!.state == .unprocessed, "scan reads a bad meeting.json as no record")
    check((try! Data(contentsOf: h.appendingPathComponent("meeting.json"))) == before && names(h) == ["meeting.json"], "scan never touches a bad meeting.json")
    try! store.update(h) { $0.state = .failed; $0.error = "x" }
    let hn = names(h)
    let bad = hn.filter { $0.hasPrefix("meeting.json.bad-") }
    check(hn.count == 2 && bad.count == 1, "update backs up a bad meeting.json")
    check(bad.first.flatMap { try? Data(contentsOf: h.appendingPathComponent($0)) } == before, "backup holds the original bytes")
    let hobj = try! JSONSerialization.jsonObject(with: Data(contentsOf: h.appendingPathComponent("meeting.json"))) as! [String: Any]
    check(hobj["state"] as? String == "failed" && hobj["error"] as? String == "x", "update then writes a fresh meeting.json")
    // a decodable but wrong-typed file counts as bad too
    let k = make(root, "2026-10-28_1300", files: ["meeting.json": "[1,2]"])
    try! store.update(k) { $0.state = .queued }
    check(names(k).filter { $0.hasPrefix("meeting.json.bad-") }.count == 1, "non-object meeting.json is backed up")
}

// update never queues an old folder
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    func state(_ f: URL) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: f.appendingPathComponent("meeting.json")))) as? [String: Any])?["state"] as? String
    }
    func scanned(_ f: URL) -> MeetingState? { store.scan().first { $0.folder.url.lastPathComponent == f.lastPathComponent }?.state }
    let withNotes = make(root, "2026-10-20_0900", files: ["notes.md": "hand edited"])
    let without = make(root, "2026-10-20_1000", files: ["2026-10-20_1000_meeting.m4a": "x"])
    try! store.update(withNotes) { $0.title = "Retitled" }
    try! store.update(without) { $0.title = "Retitled" }
    check(state(withNotes) == "done" && scanned(withNotes) == .done, "update on old folder with notes.md stays done")
    check(state(without) == "unprocessed" && scanned(without) == .unprocessed, "update on old folder without notes.md is unprocessed")
    let badNotes = make(root, "2026-10-20_1100", files: ["notes.md": "n", "meeting.json": "{oops"])
    let badNone = make(root, "2026-10-20_1200", files: ["meeting.json": "{oops"])
    try! store.update(badNotes) { $0.title = "T" }
    try! store.update(badNone) { $0.title = "T" }
    check(state(badNotes) == "done" && scanned(badNotes) == .done, "undecodable meeting.json with notes.md becomes done")
    check(state(badNone) == "unprocessed" && scanned(badNone) == .unprocessed, "undecodable meeting.json without notes.md becomes unprocessed")
    check(names(badNotes).contains { $0.hasPrefix("meeting.json.bad-") } && names(badNone).contains { $0.hasPrefix("meeting.json.bad-") }, "backups kept")
    check(mode(withNotes.appendingPathComponent("meeting.json")) == 0o600 && !names(withNotes).contains { $0.hasPrefix(".meeting.json.tmp") }, "private file, no temp left")
}

// matches
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    _ = make(root, "2026-10-28 0900 Café planning", files: ["transcript.txt": "We talked about the Roadmap and Hiring."])
    _ = make(root, "2026-10-28 1000 Standup", files: ["transcript.txt": "Nothing blocked."])
    _ = make(root, "2026-10-28_1100")
    let all = store.scan()
    func m(_ title: String) -> Meeting { all.first { $0.folder.url.lastPathComponent.hasSuffix(title) }! }
    let sem = DispatchSemaphore(value: 0)
    check(!store.matches(m("Standup"), query: "roadmap"), "no transcript match before indexing")
    store.indexTranscripts { sem.signal() }
    check(sem.wait(timeout: .now() + 10) == .success, "indexTranscripts calls done")
    check(store.matches(m("Standup"), query: "STANDUP"), "title match")
    check(store.matches(m("Café planning"), query: "roadmap hiring") == false, "query is a phrase, not words")
    check(store.matches(m("Café planning"), query: "roadmap and hiring"), "transcript match")
    check(!store.matches(m("Standup"), query: "roadmap"), "no match")
    check(store.matches(m("Café planning"), query: "cafe"), "cafe matches Café")
    check(store.matches(m("Standup"), query: "  "), "blank query matches everything")
    check(!store.matches(m("1100"), query: "roadmap"), "folder without transcript has no transcript match")
}


// MARK: - Session (Task 4)

/// An error whose text is what a caller sees.
struct FakeError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

/// Stands in for the recorder child. Processes are numbers; a test decides when one exits.
final class FakeRecorder: RecorderControl {
    var launches: [(dir: URL, mic: String?)] = []
    var launchError: Error? = nil
    var signals: [(pid: Int32, sig: Int32)] = []
    var alive: Set<Int32> = []
    var exitCodes: [Int32: Int32] = [:]
    var running: [String: Int32] = [:]   // folder path -> pid, as `find` would see it
    var recoverResult = true
    var recoverBusy = false              // --recover exits 75: someone else holds the folder lock
    var recoverLies = false              // recover says yes without making anything verify
    var recovered: [URL] = []
    var onRecover: ((URL) -> Void)? = nil
    var verified: Set<String> = []       // folders whose audio verifies
    var durations: [String: Double] = [:] // audio.m4a duration of a verified folder (default 1.0)
    var findUnknown = false              // ps could not be run or read
    var finds = 0
    var healthLine: ((String) -> Void)? = nil
    var tails: [String: LogTail] = [:]   // the real capture.log tail, over files in the temp folder
    var nextPid: Int32 = 1000

    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32 {
        if let e = launchError { throw e }
        launches.append((dir, mic))
        nextPid += 1
        alive.insert(nextPid)
        running[dir.path] = nextPid
        healthLine = onHealthLine
        tails[dir.path] = LogTail(dir.appendingPathComponent("capture.log"), fromEnd: false, onHealthLine: onHealthLine)
        return nextPid
    }
    func attach(dir: URL, onHealthLine: @escaping (String) -> Void) {
        tails[dir.path] = LogTail(dir.appendingPathComponent("capture.log"), fromEnd: true, onHealthLine: onHealthLine)
    }
    func pollLog(dir: URL) { tails[dir.path]?.poll() }
    func lastMessage(dir: URL) -> String? { tails[dir.path]?.lastMessage }
    func signal(_ pid: Int32, _ sig: Int32) { signals.append((pid, sig)) }
    func isRunning(_ pid: Int32) -> Bool { alive.contains(pid) }
    func find(dir: URL) -> FindResult {
        finds += 1
        if findUnknown { return .unknown }
        return running[dir.path].flatMap { alive.contains($0) ? FindResult.found($0) : nil } ?? .notFound
    }
    func exitStatus(_ pid: Int32) -> Int32? { alive.contains(pid) ? nil : exitCodes[pid] }
    func recover(dir: URL) -> RecoverResult {
        recovered.append(dir)
        onRecover?(dir)
        if recoverBusy { return .busy }
        if recoverLies { return .recovered }
        if recoverResult { verified.insert(dir.path) }
        return recoverResult ? .recovered : .failed
    }
    func verify(dir: URL) -> Double? { verified.contains(dir.path) ? (durations[dir.path] ?? 1.0) : nil }

    /// The recorder exits, as it would after finalising (0) or failing (1).
    func exit(_ pid: Int32, _ code: Int32, verifies: Bool) {
        alive.remove(pid)
        exitCodes[pid] = code
        if verifies, let dir = running.first(where: { $0.value == pid })?.key { verified.insert(dir) }
    }
    func sent(_ sig: Int32) -> Int { signals.filter { $0.sig == sig }.count }
}

final class FakeClock {
    let base = local(2026, 10, 29, 10, 0)
    var t: TimeInterval = 0
    func now() -> Date { base.addingTimeInterval(t) }
}

let GB: Int64 = 1_000_000_000
let MB: Int64 = 1_000_000

/// A session over temp folders, a fake recorder, a fake clock and a settable free space.
final class Rig {
    let root = freshRoot()
    let state: URL
    let rec = FakeRecorder()
    let clock = FakeClock()
    var free: Int64 = 50 * GB
    let store: MeetingStore
    var session: Session!
    var finished: [(URL, Bool)] = []
    var changes: [Session.Phase] = []

    init() {
        state = root.appendingPathComponent("state")
        store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        try! fm.createDirectory(at: store.root, withIntermediateDirectories: true)
    }
    @discardableResult
    func make() -> Session {
        session = Session(stateDir: state, recorder: rec, store: store, now: { [clock] in clock.now() },
                          freeBytes: { [unowned self] in self.free }, tickQueue: nil, workQueue: nil)
        session.onFinished = { [unowned self] in self.finished.append(($0, $1)) }
        session.onChange = { [unowned self] in self.changes.append($0) }
        return session
    }
    func at(_ t: TimeInterval) { clock.t = t; session.tick() }
    var dirFile: URL { state.appendingPathComponent("recording.dir") }
    var pausedFile: URL { state.appendingPathComponent("paused") }
    func json(_ dir: URL) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meeting.json")))) as? [String: Any]) ?? [:]
    }
    func stateOf(_ dir: URL) -> String? { json(dir)["state"] as? String }
    /// A meeting folder on disk with the given meeting.json fields.
    func meeting(_ name: String, _ change: (inout MeetingRecord) -> Void) -> URL {
        let dir = Session.folderURL(store.root.appendingPathComponent(name).path)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! store.update(dir, change)
        return dir
    }
    func writeState(_ dir: URL, paused: Bool = false) {
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        try! dir.path.write(to: dirFile, atomically: true, encoding: .utf8)
        if paused { fm.createFile(atPath: pausedFile.path, contents: Data()) }
    }
    func raw(_ dir: URL) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("meeting.json")) }
    /// Appends lines to the folder's capture.log, as the recorder does through its stderr.
    func log(_ dir: URL, _ lines: String...) {
        let url = dir.appendingPathComponent("capture.log")
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try! FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        h.closeFile()
    }
}

func errorText(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return error.localizedDescription }
}

// start
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: "USB Mic")
    check(fm.fileExists(atPath: dir.path) && dir.deletingLastPathComponent().path == r.store.root.path, "start creates the meeting folder")
    check((try? String(contentsOf: r.dirFile, encoding: .utf8)) == dir.path, "start writes recording.dir")
    let j = r.json(dir)
    check(j["state"] as? String == "recording" && UUID(uuidString: j["id"] as? String ?? "") != nil, "start sets meeting.json recording with an id")
    check(s.phase == .recording(dir) && r.changes.last == .recording(dir), "start gives .recording")
    check(r.rec.launches.count == 1 && r.rec.launches[0].dir == dir && r.rec.launches[0].mic == "USB Mic", "start launches the recorder once with the mic")
    let second = errorText { _ = try s.start(root: r.store.root, mic: nil) }
    check(second?.contains("already recording") ?? false, "a second start throws already recording")
    check(r.rec.launches.count == 1 && s.phase == .recording(dir), "a second start launches nothing")
}

// start: launch throws
do {
    let r = Rig()
    r.rec.launchError = FakeError(text: "the recorder could not be started")
    let s = r.make()
    let text = errorText { _ = try s.start(root: r.store.root, mic: nil) }
    check(text == "the recorder could not be started", "the launch error text reaches the caller")
    check(s.phase == .idle && !fm.fileExists(atPath: r.dirFile.path), "a failed launch leaves idle and removes recording.dir")
    let folders = names(r.store.root)
    check(folders.count == 1 && r.stateOf(r.store.root.appendingPathComponent(folders[0])) == "failed",
          "a failed launch marks the meeting failed, never left as recording")
}

// start: disk floor
do {
    let r = Rig()
    r.free = 2 * GB - 1
    let s = r.make()
    let text = errorText { _ = try s.start(root: r.store.root, mic: nil) }
    check(text == "not enough free disk space to record (2 GB needed)", "start refuses below 2 GB")
    check(r.rec.launches.isEmpty && names(r.store.root).isEmpty && s.phase == .idle, "a refused start makes nothing")
}

// pause and resume, and the clock
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    let pid = r.rec.nextPid
    r.clock.t = 60
    s.pause()
    check(s.phase == .paused(dir) && fm.fileExists(atPath: r.pausedFile.path), "pause gives .paused and writes paused")
    check(r.rec.signals.count == 1 && r.rec.signals[0].pid == pid && r.rec.signals[0].sig == SIGUSR1, "pause sends SIGUSR1")
    s.pause()
    check(r.rec.signals.count == 1, "a second pause is a no-op")
    check(s.recordedSeconds(at: r.clock.base.addingTimeInterval(75)) == 60, "the clock stands still while paused")
    r.clock.t = 90
    s.resume()
    check(s.phase == .recording(dir) && !fm.fileExists(atPath: r.pausedFile.path), "resume gives .recording and removes paused")
    check(r.rec.signals.count == 2 && r.rec.signals[1].sig == SIGUSR2, "resume sends SIGUSR2")
    s.resume()
    check(r.rec.signals.count == 2, "a second resume is a no-op")
    check(s.recordedSeconds(at: r.clock.base.addingTimeInterval(120)) == 90, "start 0, pause 60, resume 90, read 120 gives 90")
}

// stop: finalising before processing
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    let pid = r.rec.nextPid
    r.clock.t = 45
    check(s.stop() == dir, "stop returns the folder")
    check(r.rec.sent(SIGINT) == 1 && s.phase == .finalising(dir), "stop sends SIGINT and moves to finalising at once")
    check(r.stateOf(dir) == "finalising", "meeting.json says finalising")
    check(s.stop() == dir && r.rec.sent(SIGINT) == 1, "a second stop while finalising sends nothing")
    r.at(50)
    check(r.stateOf(dir) == "finalising" && r.finished.isEmpty && s.phase == .finalising(dir), "nothing is queued while the recorder is alive")
    check(s.recordedSeconds(at: r.clock.now()) == 45, "the clock stops at stop")
    r.rec.exit(pid, 0, verifies: true)
    r.at(51)
    check(r.stateOf(dir) == "queued" && (r.json(dir)["seconds"] as? Int) == 45, "a clean exit that verifies is queued with seconds")
    check(!fm.fileExists(atPath: r.dirFile.path) && !fm.fileExists(atPath: r.pausedFile.path), "state files are cleared")
    check(r.finished.count == 1 && r.finished[0].0 == dir && r.finished[0].1, "onFinished(dir, true)")
    check(s.phase == .idle && r.changes.last == .idle, "back to idle")
    check(r.rec.recovered.isEmpty, "a clean exit needs no recovery")
}

// stop while paused counts recorded time only
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    let pid = r.rec.nextPid
    r.clock.t = 30; s.pause()
    r.clock.t = 100
    _ = s.stop()
    r.rec.exit(pid, 0, verifies: true)
    r.at(101)
    check((r.json(dir)["seconds"] as? Int) == 30, "stopping while paused stores recorded seconds only")
}

// stop: the recorder will not exit
func stuckStop(recordFor seconds: TimeInterval, recovers: Bool) -> (Rig, URL) {
    let r = Rig()
    r.rec.recoverResult = recovers
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.clock.t = seconds
    _ = s.stop()
    return (r, dir)
}
do {
    let (r, dir) = stuckStop(recordFor: 30, recovers: true)
    r.at(30 + 59)
    check(r.rec.sent(SIGTERM) == 0, "no SIGTERM before 60 s")
    r.at(30 + 60)
    check(r.rec.sent(SIGTERM) == 1, "SIGTERM after 60 s")
    r.at(30 + 69)
    check(r.rec.sent(SIGKILL) == 0 && r.rec.recovered.isEmpty, "no SIGKILL before a further 10 s")
    r.at(30 + 70)
    check(r.rec.sent(SIGKILL) == 1 && r.rec.recovered == [dir], "SIGKILL after 10 s, then recover")
    check(r.stateOf(dir) == "queued" && r.finished.count == 1 && r.finished[0].1, "recovered means queued")
    check(r.session.phase == .idle && !fm.fileExists(atPath: r.dirFile.path), "idle with state files cleared after recovery")
    r.at(30 + 200)
    check(r.rec.sent(SIGTERM) == 1 && r.rec.sent(SIGKILL) == 1 && r.rec.recovered.count == 1, "nothing more happens once finished")
}
do {
    let (r, dir) = stuckStop(recordFor: 30, recovers: false)
    for t in stride(from: 31.0, through: 110, by: 1) { r.at(t) }
    check(r.stateOf(dir) == "failed" && r.json(dir)["error"] as? String == "the recording was interrupted; its files are kept",
          "not recovered means failed with the reason")
    check(r.finished.count == 1 && r.finished[0].0 == dir && !r.finished[0].1, "onFinished(dir, false)")
    check(fm.fileExists(atPath: dir.path) && fm.fileExists(atPath: dir.appendingPathComponent("meeting.json").path), "every file is kept")
}
do {
    // 60 s plus 1 s per recorded minute: ten minutes waits 70 s.
    let (r, _) = stuckStop(recordFor: 600, recovers: true)
    r.at(600 + 69)
    check(r.rec.sent(SIGTERM) == 0, "a ten minute recording waits more than 60 s")
    r.at(600 + 70)
    check(r.rec.sent(SIGTERM) == 1, "a ten minute recording gets SIGTERM after 70 s")
}

// stop: a failed exit goes through recovery; unverified audio is never queued
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    let pid = r.rec.nextPid
    _ = s.stop()
    r.rec.exit(pid, 1, verifies: false)
    r.at(1)
    check(r.rec.recovered == [dir] && r.stateOf(dir) == "queued", "an exit of 1 is recovered, then queued")
}
do {
    // recover claims success but the audio still does not verify
    let r = Rig()
    r.rec.recoverLies = true
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    _ = s.stop()
    r.rec.exit(r.rec.nextPid, 0, verifies: false)
    r.at(1)
    check(r.rec.recovered == [dir] && r.stateOf(dir) == "failed" && r.finished.count == 1 && !r.finished[0].1,
          "audio that does not verify is never queued, even after recover says yes")
}

// the recorder dies on its own while recording
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(20)
    check(r.rec.sent(SIGINT) == 0 && r.rec.recovered == [dir], "a recorder that died on its own is recovered")
    check(r.stateOf(dir) == "queued" && s.phase == .idle && r.finished.count == 1, "and handled as a stop")
}

// adopt: the recorder is still alive
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0955") {
        $0.started = r.clock.base.addingTimeInterval(-300)
        $0.pausedSeconds = 60
        $0.state = .recording
    }
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    let s = r.make()
    s.adopt()
    check(s.phase == .recording(dir), "adopt gives .recording for a live recorder")
    check(s.recordedSeconds(at: r.clock.now()) == 240, "the timer continues from meeting.json")
    check(r.rec.recovered.isEmpty && r.rec.launches.isEmpty, "adopting launches and recovers nothing")
    r.clock.t = 10
    _ = s.stop()
    check(r.rec.signals.last?.pid == 4242 && r.rec.signals.last?.sig == SIGINT, "stop signals the adopted recorder")
    r.rec.exit(4242, 0, verifies: true)
    r.rec.exitCodes[4242] = nil // not our child: its exit status is unknown
    r.at(11)
    check(r.stateOf(dir) == "queued" && (r.json(dir)["seconds"] as? Int) == 250 && s.phase == .idle, "an adopted recording finishes and is queued")
}
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0950") {
        $0.started = r.clock.base.addingTimeInterval(-300)
        $0.pausedSeconds = 60
        $0.pausedAt = r.clock.base.addingTimeInterval(-100)
        $0.state = .recording
    }
    r.writeState(dir, paused: true)
    r.rec.alive.insert(4343)
    r.rec.running[dir.path] = 4343
    let s = r.make()
    s.adopt()
    check(s.phase == .paused(dir), "adopt gives .paused when paused exists")
    check(s.recordedSeconds(at: r.clock.now()) == 140, "an adopted pause keeps its clock")
    r.clock.t = 20
    s.resume()
    check(r.rec.signals.last?.sig == SIGUSR2 && s.recordedSeconds(at: r.clock.base.addingTimeInterval(30)) == 150, "an adopted pause resumes")
}

// adopt: the recorder died with the app
for recovers in [true, false] {
    let r = Rig()
    r.rec.recoverResult = recovers
    let dir = r.meeting("2026-10-29_0900") { $0.state = .recording }
    r.writeState(dir, paused: true)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered == [dir], "adopt recovers a dead recording (recovers: \(recovers))")
    check(r.stateOf(dir) == (recovers ? "queued" : "failed"), "a dead recording is queued only when recovered (recovers: \(recovers))")
    if !recovers {
        check(r.json(dir)["error"] as? String == "the recording was interrupted; its files are kept", "an unrecoverable one says why")
    }
    check(s.phase == .idle && !fm.fileExists(atPath: r.dirFile.path) && !fm.fileExists(atPath: r.pausedFile.path), "state files are cleared after a dead adopt")
    check(r.finished.count == 1 && r.finished[0].1 == recovers, "onFinished reports the result (recovers: \(recovers))")
}

// adopt: orphans
do {
    let r = Rig()
    r.rec.recoverResult = true
    let named = r.meeting("2026-10-29_0800") { $0.state = .recording }
    let orphanRec = r.meeting("2026-10-28_0900") { $0.state = .recording }
    let orphanFin = r.meeting("2026-10-28_1000") { $0.state = .finalising }
    let queued = r.meeting("2026-10-28_1100") { $0.state = .queued }
    let live = r.meeting("2026-10-28_1200") { $0.state = .recording }
    r.rec.alive = [7, 8]
    r.rec.running[named.path] = 7
    r.rec.running[live.path] = 8
    r.writeState(named)
    let s = r.make()
    s.adopt()
    let recoveredNames = Set(r.rec.recovered.map { $0.lastPathComponent })
    check(recoveredNames == [orphanRec.lastPathComponent, orphanFin.lastPathComponent], "orphans are recovered at launch, and only orphans")
    check(r.stateOf(orphanRec) == "queued" && r.stateOf(orphanFin) == "queued", "recovered orphans are queued")
    check(r.stateOf(queued) == "queued" && r.stateOf(live) == "recording" && r.stateOf(named) == "recording", "others are untouched")
    check(s.phase == .recording(named), "the named recording is still adopted")
}
do {
    let r = Rig()
    r.rec.recoverResult = false
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .recording }
    let s = r.make()
    s.adopt()
    check(r.stateOf(orphan) == "failed" && r.finished.count == 1 && !r.finished[0].1 && s.phase == .idle,
          "an orphan that cannot be recovered is failed, with no recording.dir at all")
}

// adopt: recording.dir left behind by a meeting that had already settled
for settled in [MeetingState.queued, .done] {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0700") { $0.state = settled }
    r.writeState(dir, paused: true)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered.isEmpty && r.stateOf(dir) == settled.rawValue && s.phase == .idle,
          "a settled meeting named by recording.dir is left as it is (\(settled.rawValue))")
    check(!fm.fileExists(atPath: r.dirFile.path) && !fm.fileExists(atPath: r.pausedFile.path), "its stale state files are cleared (\(settled.rawValue))")
}

// adopt: the app went away after SIGINT and the recorder is still finalising
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0930") { $0.state = .finalising; $0.seconds = 1200 }
    r.writeState(dir)
    r.rec.alive.insert(5151)
    r.rec.running[dir.path] = 5151
    let s = r.make()
    s.adopt()
    check(s.phase == .finalising(dir) && s.recordedSeconds(at: r.clock.now()) == 1200, "a recorder still finalising is adopted as finalising")
    r.at(79)
    check(r.rec.sent(SIGTERM) == 0, "its wait counts from adoption: 60 s plus 20 s for 20 minutes")
    r.at(80)
    check(r.rec.sent(SIGTERM) == 1 && r.rec.signals.last?.pid == 5151, "then SIGTERM to the adopted recorder")
    r.rec.exit(5151, 0, verifies: true)
    r.rec.exitCodes[5151] = nil
    r.at(81)
    check(r.stateOf(dir) == "queued" && (r.json(dir)["seconds"] as? Int) == 1200 && s.phase == .idle, "and it is queued once it exits")
}

// the real 1 s timer and the work queue
do {
    let r = Rig()
    let q = DispatchQueue(label: "test.session.tick")
    let done = DispatchSemaphore(value: 0)
    var result: (URL, Bool)? = nil
    var s: Session! = nil
    var dir: URL! = nil
    q.sync {
        s = Session(stateDir: r.state, recorder: r.rec, store: r.store, now: { Date() }, freeBytes: { 50 * GB },
                    tickQueue: q, workQueue: DispatchQueue(label: "test.session.work"))
        s.onFinished = { result = ($0, $1); done.signal() }
        dir = try! s.start(root: r.store.root, mic: nil)
        _ = s.stop()
        r.rec.exit(r.rec.nextPid, 0, verifies: true)
    }
    check(done.wait(timeout: .now() + 5) == .success, "the timer finishes a stop on its own")
    q.sync {
        check(result?.0 == dir && result?.1 == true && s.phase == .idle && r.stateOf(dir) == "queued", "through the work queue, back on the tick queue")
    }
}

// health
do {
    let r = Rig()
    let s = r.make()
    _ = try! s.start(root: r.store.root, mic: nil)
    check(s.health == Session.Health(mic: .ok, system: .ok, disk: .ok), "health starts ok")
    r.rec.healthLine?("Starting recording...")
    r.rec.healthLine?("health mic=ok system=stalled")
    check(s.health.mic == .ok && s.health.system == .stalled, "system stalled, mic ok, separately")
    r.rec.healthLine?("health mic=error system=ok")
    check(s.health.mic == .error && s.health.system == .ok, "mic error, system ok")
    r.clock.t = 5
    r.rec.healthLine?("health mic=ok system=ok")
    r.at(14)
    check(s.health.mic == .ok && s.health.system == .ok, "ok within 10 s of a health line")
    r.at(15)
    check(s.health.mic == .stalled && s.health.system == .stalled, "stalled after 10 s with no health line")
    r.rec.healthLine?("health mic=ok system=ok")
    check(s.health.mic == .ok, "a fresh line clears it")
    r.free = 999 * MB
    r.at(16)
    check(s.health.disk == .low, "below 1 GB the disk is low")
    r.free = 5 * GB
    r.at(17)
    check(s.health.disk == .ok, "disk ok again with space")
}
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.free = 199 * MB
    r.at(30)
    check(s.phase == .finalising(dir) && r.rec.sent(SIGINT) == 1, "below 200 MB the session stops itself")
    let err = r.json(dir)["error"] as? String ?? ""
    check(err.contains("disk") && r.stateOf(dir) == "finalising", "the reason is in meeting.json error")
    r.rec.exit(r.rec.nextPid, 0, verifies: true)
    r.at(31)
    check(r.stateOf(dir) == "queued" && r.json(dir)["error"] == nil, "it finalises, and a queued meeting carries no error (M5)")
}

// MARK: - Task 4 fix round 1

// A: find cannot tell. The named recording is left exactly as it is, then retried on the next tick.
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0955") { $0.started = r.clock.base.addingTimeInterval(-300); $0.state = .recording }
    r.writeState(dir, paused: true)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    r.rec.findUnknown = true
    let before = r.raw(dir)
    let s = r.make()
    s.adopt()
    check(s.phase == .idle && r.rec.recovered.isEmpty && r.finished.isEmpty, "A: find unknown: no recover, no failed, still idle")
    check(fm.fileExists(atPath: r.dirFile.path) && fm.fileExists(atPath: r.pausedFile.path), "A: find unknown: state files kept")
    check(r.raw(dir) == before, "A: find unknown: meeting.json unchanged")
    r.at(1)
    check(s.phase == .idle && r.raw(dir) == before && fm.fileExists(atPath: r.dirFile.path), "A: a tick while find still cannot tell changes nothing")
    r.rec.findUnknown = false
    r.at(2)
    check(s.phase == .paused(dir), "A: the next tick that can tell adopts it")
}
// A: an orphan that find cannot tell about is left alone.
do {
    let r = Rig()
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .recording }
    r.rec.findUnknown = true
    let before = r.raw(orphan)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered.isEmpty && r.raw(orphan) == before && r.finished.isEmpty, "A: an orphan find cannot tell about is untouched")
}
// A: recovery says busy (75): nothing is written, the app lets go of the folder.
do {
    let r = Rig()
    r.rec.recoverBusy = true
    let dir = r.meeting("2026-10-29_0900") { $0.state = .recording }
    r.writeState(dir, paused: true)
    let before = r.raw(dir)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered == [dir] && r.raw(dir) == before, "A: recover busy writes nothing to meeting.json")
    check(s.phase == .idle && !fm.fileExists(atPath: r.dirFile.path) && !fm.fileExists(atPath: r.pausedFile.path),
          "A: recover busy on the current recording: idle, own state files cleared")
    check(r.finished.isEmpty, "A: recover busy reports nothing finished")
}
do {
    let r = Rig()
    r.rec.recoverBusy = true
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .finalising }
    let before = r.raw(orphan)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered == [orphan] && r.raw(orphan) == before && r.finished.isEmpty, "A: a busy orphan is left alone")
    r.rec.recoverBusy = false
    s.adopt()
    check(r.rec.recovered.count == 2 && r.stateOf(orphan) == "queued", "A: and a later adopt keeps no claim on it")
}
do {
    let r = Rig()
    r.rec.recoverBusy = true
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    _ = s.stop()
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(1)
    check(r.stateOf(dir) == "finalising" && s.phase == .idle && r.finished.isEmpty && !fm.fileExists(atPath: r.dirFile.path),
          "A: a stop whose recovery is busy is never marked failed")
}

// B: an adopted recorder's health comes from tailing capture.log, with the 10 s rule.
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0955") { $0.started = r.clock.base.addingTimeInterval(-300); $0.state = .recording }
    r.log(dir, "Starting recording...", "health mic=error system=error") // before the crash: not read
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    let s = r.make()
    s.adopt()
    r.at(1)
    check(s.health.mic == .ok && s.health.system == .ok, "B: an adopted recorder's log is read from its end")
    r.clock.t = 5
    r.log(dir, "health mic=ok system=stalled")
    r.at(5)
    check(s.health.mic == .ok && s.health.system == .stalled, "B: an adopted recorder's health lines update health")
    r.at(14)
    check(s.health.system == .stalled && s.health.mic == .ok, "B: still as reported within 10 s")
    r.at(15)
    check(s.health.mic == .stalled && s.health.system == .stalled, "B: an adopted recorder that stops writing is stalled after 10 s")
    r.log(dir, "health mic=ok system=ok")
    r.at(16)
    check(s.health.mic == .ok && s.health.system == .ok, "B: and ok again when it writes")
}
// B: a launched recorder's health comes from its capture.log from the start.
do {
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.log(dir, "Starting recording...", "health mic=stalled system=ok")
    r.at(1)
    check(s.health.mic == .stalled && s.health.system == .ok, "B: a launched recorder's capture.log is read from offset 0")
}

// M1: seconds comes from the verified audio after a recovery.
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0900") { $0.state = .recording; $0.seconds = 0 }
    r.rec.durations[dir.path] = 3599.6
    r.writeState(dir)
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .recording; $0.seconds = 60 }
    r.rec.durations[orphan.path] = 1200.2
    let s = r.make()
    s.adopt()
    check(r.stateOf(dir) == "queued" && (r.json(dir)["seconds"] as? Int) == 3600, "M1: a recovered recording takes seconds from audio.m4a")
    check(r.stateOf(orphan) == "queued" && (r.json(orphan)["seconds"] as? Int) == 1200, "M1: so does a recovered orphan")
}

// M2: a recorder that fails at once says why.
do {
    let r = Rig()
    r.rec.recoverResult = false
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.log(dir, "Starting recording...", "Failed to start system audio: denied",
          "Grant Screen Recording permission in System Settings → Privacy & Security.", "health mic=ok system=ok")
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(1)
    check(r.stateOf(dir) == "failed" && r.json(dir)["error"] as? String == "Grant Screen Recording permission in System Settings → Privacy & Security.",
          "M2: a recorder that exits 1 and cannot be recovered leaves its last message as the error")
}

// M3: an adopted pid is checked before SIGTERM or SIGKILL.
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0930") { $0.state = .finalising; $0.seconds = 0 }
    r.writeState(dir)
    r.rec.alive.insert(5151)
    r.rec.running[dir.path] = 5151
    let s = r.make()
    s.adopt()
    r.rec.running[dir.path] = nil // it exited and its pid now belongs to something else
    r.rec.verified.insert(dir.path)
    r.at(60)
    check(r.rec.sent(SIGTERM) == 0 && r.rec.sent(SIGKILL) == 0, "M3: no signal to a reused pid")
    check(s.phase == .idle && r.stateOf(dir) == "queued", "M3: a pid that is no longer the recorder is treated as exited")
}
do {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0930") { $0.state = .finalising; $0.seconds = 0 }
    r.writeState(dir)
    r.rec.alive.insert(5151)
    r.rec.running[dir.path] = 5151
    let s = r.make()
    s.adopt()
    r.rec.findUnknown = true
    r.at(60)
    check(r.rec.sent(SIGTERM) == 0 && s.phase == .finalising(dir), "M3: no signal while find cannot tell")
    r.rec.findUnknown = false
    r.at(61)
    check(r.rec.sent(SIGTERM) == 1 && r.rec.signals.last?.pid == 5151, "M3: SIGTERM once find confirms the pid")
    r.at(71)
    check(r.rec.sent(SIGKILL) == 1, "M3: SIGKILL once find confirms the pid again")
}

// M4: a second adopt while an orphan is being recovered does not finish it twice.
do {
    let r = Rig()
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .recording }
    let s = r.make()
    var nested = false
    r.rec.onRecover = { _ in if !nested { nested = true; s.adopt() } }
    s.adopt()
    check(r.rec.recovered == [orphan] && r.finished.count == 1, "M4: one recovery and one onFinished per orphan")
}

// M5: a disk stop that cannot be finalised keeps the disk reason.
do {
    let r = Rig()
    r.rec.recoverResult = false
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.free = 199 * MB
    r.at(30)
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(31)
    check(r.stateOf(dir) == "failed" && r.json(dir)["error"] as? String
            == "recording stopped because the disk was nearly full; the recording was interrupted; its files are kept",
          "M5: a failed disk stop keeps the disk reason")
}

// M7: recording.dir is acted on only for a meeting folder under the store root.
for (label, makeDir) in [("not a meeting folder", { (r: Rig) in r.store.root.appendingPathComponent("notes") }),
                         ("outside the store root", { (r: Rig) in r.root.appendingPathComponent("2026-10-29_0900") })] {
    let r = Rig()
    let dir = Session.folderURL(makeDir(r).path)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! "{\"state\": \"recording\"}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
    let before = r.raw(dir)
    r.writeState(dir, paused: true)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered.isEmpty && r.raw(dir) == before && s.phase == .idle, "M7: recording.dir \(label) is not acted on")
    check(!fm.fileExists(atPath: r.dirFile.path) && !fm.fileExists(atPath: r.pausedFile.path), "M7: its state files are cleared (\(label))")
}

// M8: start refuses while recording.dir names a live (or unknown) recorder.
for unknown in [false, true] {
    let r = Rig()
    let dir = r.meeting("2026-10-29_0955") { $0.state = .recording }
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    r.rec.findUnknown = unknown
    let s = r.make()
    let text = errorText { _ = try s.start(root: r.store.root, mic: nil) }
    check((text?.contains("already recording") ?? false) && r.rec.launches.isEmpty && names(r.store.root) == [dir.lastPathComponent],
          "M8: start refuses while recording.dir names a recorder that is \(unknown ? "unknown" : "alive")")
    check((try? String(contentsOf: r.dirFile, encoding: .utf8)) == dir.path, "M8: and leaves recording.dir alone (\(unknown ? "unknown" : "alive"))")
}
do {
    let r = Rig()
    let old = r.meeting("2026-10-29_0955") { $0.state = .recording }
    r.writeState(old)
    let s = r.make()
    let dir = try? s.start(root: r.store.root, mic: nil)
    check(dir != nil && r.rec.launches.count == 1, "M8: a recording.dir whose recorder is gone does not block start")
}

// M9: the state files are private.
do {
    let r = Rig()
    let s = r.make()
    _ = try! s.start(root: r.store.root, mic: nil)
    s.pause()
    check(mode(r.dirFile) == 0o600 && mode(r.pausedFile) == 0o600, "M9: recording.dir and paused are 0600")
}

// ChildRecorder, against a fake executable (never the real recorder)
do {
    let bin = freshRoot()
    let src = bin.appendingPathComponent("fake.c")
    let exe = bin.appendingPathComponent("fake-recorder")
    let code = """
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    #include <sys/stat.h>
    static volatile sig_atomic_t stop = 0;
    static void on_int(int s) { (void)s; stop = 1; }
    int main(int argc, char **argv) {
        if (argc >= 3 && strcmp(argv[1], "--recover") == 0) {
            char p[4096];
            snprintf(p, sizeof p, "%s/can-recover", argv[2]);
            fprintf(stderr, "recovering %s\\n", argv[2]);
            if (access(p, F_OK) == 0) return 0;
            snprintf(p, sizeof p, "%s/busy", argv[2]);
            return access(p, F_OK) == 0 ? 75 : 1;
        }
        signal(SIGINT, on_int);
        if (getenv("FAKE_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
        struct stat st;
        fstat(2, &st);
        fprintf(stderr, "stderr-is-file %d\\n", S_ISREG(st.st_mode) ? 1 : 0);
        fprintf(stderr, "Starting recording...\\n");
        for (int i = 0; i < argc; i++) fprintf(stderr, "arg %s\\n", argv[i]);
        while (!stop) {
            fprintf(stderr, "health mic=ok system=stalled\\n");
            usleep(100000);
        }
        fprintf(stderr, "Stopping...\\n");
        return 3;
    }
    """
    try! code.write(to: src, atomically: true, encoding: .utf8)
    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-o", exe.path, src.path]
    try! cc.run()
    cc.waitUntilExit()
    check(cc.terminationStatus == 0, "fake recorder compiles")

    let child = ChildRecorder(executable: exe)
    let dir = try! MeetingFolder.create(in: freshRoot(), at: Date())
    let lines = NSMutableArray()
    let pid = try! child.launch(dir: dir, mic: "USB Mic") { line in
        lines.add(line)
    }
    check(pid > 0 && child.isRunning(pid) && child.exitStatus(pid) == nil, "ChildRecorder launches and reports running")
    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; usleep(20_000) }
        return cond()
    }
    check(waitFor(5) { child.pollLog(dir: dir); return lines.count >= 2 }, "health lines reach onHealthLine through capture.log")
    check((lines as! [String]).allSatisfy { $0 == "health mic=ok system=stalled" }, "only health lines are passed on")
    check(child.find(dir: dir) == .found(pid), "find sees the recorder by its command line")
    check(child.find(dir: dir.appendingPathComponent("other")) == .notFound, "find ignores other folders")
    check(ChildRecorder(executable: exe, ps: bin.appendingPathComponent("no-such-ps")).find(dir: dir) == .unknown,
          "A: find is unknown when ps cannot be run")
    check(ChildRecorder(executable: exe, ps: URL(fileURLWithPath: "/usr/bin/false")).find(dir: dir) == .unknown,
          "A: find is unknown when ps fails")
    // Attached from the end, as for an adopted recorder: only what is written afterwards.
    let quiet = try! MeetingFolder.create(in: freshRoot(), at: Date())
    let quietLog = quiet.appendingPathComponent("capture.log")
    try! "health mic=error system=error\nStarting recording...\n".write(to: quietLog, atomically: true, encoding: .utf8)
    let attached = NSMutableArray()
    let watcher = ChildRecorder(executable: exe)
    watcher.attach(dir: quiet) { attached.add($0) }
    watcher.pollLog(dir: quiet)
    check(attached.count == 0 && watcher.lastMessage(dir: quiet) == nil, "B: attach starts at the end of capture.log")
    let h = try! FileHandle(forWritingTo: quietLog)
    h.seekToEndOfFile()
    h.write(Data("health mic=ok sys".utf8))
    watcher.pollLog(dir: quiet)
    h.write(Data("tem=ok\n".utf8))
    h.closeFile()
    watcher.pollLog(dir: quiet)
    check((attached as! [String]) == ["health mic=ok system=ok"], "B: attach passes on new health lines, whole lines only")
    let log = dir.appendingPathComponent("capture.log")
    check(mode(log) == 0o600, "capture.log is 0600")
    child.signal(pid, SIGINT)
    check(waitFor(5) { !child.isRunning(pid) }, "SIGINT stops it")
    check(child.exitStatus(pid) == 3, "exitStatus reports the exit code")
    check(child.find(dir: dir) == .notFound, "find no longer sees it")
    let flushed = waitFor(2) { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("Stopping...") }
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check(flushed && text.contains("Starting recording...") && text.contains("health mic=ok"), "every stderr line goes to capture.log")
    check(text.contains("stderr-is-file 1\n"), "B: the recorder's stderr is capture.log itself, not a pipe")
    child.pollLog(dir: dir)
    check(child.lastMessage(dir: dir) == "Stopping...", "M2: lastMessage is the last line that is not a health line")
    check(text.contains("arg --record\narg -o\narg \(dir.path)\narg -n\narg meeting\narg -d\narg USB Mic\n"),
          "the recorder gets --record -o <dir> -n meeting -d <mic>")
    check(child.recover(dir: dir) == .failed, "recover fails when --recover exits 1")
    fm.createFile(atPath: dir.appendingPathComponent("busy").path, contents: Data())
    check(child.recover(dir: dir) == .busy, "A: recover is busy when --recover exits 75")
    fm.createFile(atPath: dir.appendingPathComponent("can-recover").path, contents: Data())
    check(child.recover(dir: dir) == .recovered, "recover succeeds when --recover exits 0")
    check(child.verify(dir: dir) == nil, "verify fails with no audio")

    // Real audio: working files finalised in process, as the recorder would.
    let audio = try! MeetingFolder.create(in: freshRoot(), at: Date())
    for name in ["mic.caf", "call.caf"] {
        let file = try! AVAudioFile(forWriting: audio.appendingPathComponent(name), settings: RecordingOutput.workingSettings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = 48000
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buffer.floatChannelData![0][i] = 0.3 * Float(sin(2 * Double.pi * 440 * Double(i) / 48000)) }
        try! file.write(from: buffer)
    }
    try! recover(directory: audio)
    let d = child.verify(dir: audio)
    check(d != nil && abs(d! - 1.0) < 0.1, "verify passes with the marker and three matching .m4a, giving audio.m4a's duration (M1)")
    try! fm.removeItem(at: audio.appendingPathComponent(".recording-complete"))
    check(child.verify(dir: audio) == nil, "verify fails without the marker")
}

try? fm.removeItem(at: scratch)
if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
