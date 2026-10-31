// sources: ../../app/Preferences.swift ../../app/ControlServer.swift ../../app/MeetingFolder.swift ../../app/MeetingStore.swift ../../app/Session.swift ../../app/ChildRecorder.swift ../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift ../../recorder/Finalise.swift ../../app/ProcessingQueue.swift
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
    var launchDelay: useconds_t = 0      // a slow launch, to widen any race between two starts
    var dieOnLaunch: (code: Int32, line: String)? = nil // logs its reason and exits at once, as on a missing permission

    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32 {
        if launchDelay > 0 { usleep(launchDelay) }
        if let e = launchError { throw e }
        launches.append((dir, mic))
        nextPid += 1
        running[dir.path] = nextPid
        if let die = dieOnLaunch {
            let log = dir.appendingPathComponent("capture.log")
            try? (die.line + "\n").write(to: log, atomically: true, encoding: .utf8)
            exitCodes[nextPid] = die.code
        } else {
            alive.insert(nextPid)
        }
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
    var free: Int64? = 50 * GB          // nil: the volume's free space cannot be read
    var freeAsked: [URL] = []
    var logs: [String] = []
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
    func make(tickQueue: DispatchQueue? = nil) -> Session {
        session = Session(stateDir: state, recorder: rec, store: store, now: { [clock] in clock.now() },
                          freeBytes: { [unowned self] u in self.freeAsked.append(u); return self.free }, tickQueue: tickQueue, workQueue: nil,
                          log: { [unowned self] in self.logs.append($0) })
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
        s = Session(stateDir: r.state, recorder: r.rec, store: r.store, now: { Date() }, freeBytes: { _ in 50 * GB },
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

// M7 / Ruling D: a path that is not a meeting folder and has no recorder is only cleared away.
do {
    let r = Rig()
    let dir = Session.folderURL(r.store.root.appendingPathComponent("notes").path)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! "{\"state\": \"recording\"}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
    let before = r.raw(dir)
    r.writeState(dir, paused: true)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered.isEmpty && r.raw(dir) == before && s.phase == .idle, "M7: recording.dir not a meeting folder is not acted on")
    check(!fm.fileExists(atPath: r.dirFile.path) && !fm.fileExists(atPath: r.pausedFile.path), "M7: its state files are cleared")
    check(r.rec.finds >= 1, "D: find is asked before the state files are cleared")
}
// Ruling D: a non-meeting path whose recorder find cannot tell about is left alone.
do {
    let r = Rig()
    let dir = Session.folderURL(r.store.root.appendingPathComponent("notes").path)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    r.writeState(dir, paused: true)
    r.rec.findUnknown = true
    let s = r.make()
    s.adopt()
    check(fm.fileExists(atPath: r.dirFile.path) && fm.fileExists(atPath: r.pausedFile.path) && names(dir).isEmpty && s.phase == .idle,
          "D: a non-meeting path is left alone while find cannot tell")
}
// Ruling D: a recording outside the store root (start dir=, --dir, MB_DIR) is adopted like any other.
do {
    let r = Rig()
    let elsewhere = r.root.appendingPathComponent("Work")
    try! fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let dir = Session.folderURL(elsewhere.appendingPathComponent("2026-10-29_0955").path)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! r.store.update(dir) { $0.started = r.clock.base.addingTimeInterval(-300); $0.state = .recording }
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    let s = r.make()
    s.adopt()
    check(s.phase == .recording(dir) && fm.fileExists(atPath: r.dirFile.path), "D: a live recorder outside the store root is adopted, state files kept")
    r.clock.t = 10
    _ = s.stop()
    check(r.rec.signals.last?.pid == 4242 && r.rec.signals.last?.sig == SIGINT, "D: and stop reaches it")
    r.rec.exit(4242, 0, verifies: true)
    r.rec.exitCodes[4242] = nil
    r.at(11)
    check(r.stateOf(dir) == "queued" && s.phase == .idle && !fm.fileExists(atPath: r.dirFile.path), "D: and it is queued once it exits")
}
for recovers in [true, false] {
    let r = Rig()
    r.rec.recoverResult = recovers
    let dir = Session.folderURL(r.root.appendingPathComponent("2026-10-29_0900").path)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! r.store.update(dir) { $0.state = .recording }
    r.writeState(dir)
    let s = r.make()
    s.adopt()
    check(r.rec.recovered == [dir] && r.stateOf(dir) == (recovers ? "queued" : "failed") && s.phase == .idle,
          "D: a dead recording outside the store root is recovered and marked (recovers: \(recovers))")
}

// Ruling E: the error is the recorder's reason, not its last progress or continuation line.
func failedStartError(_ lines: [String], exit code: Int32, recoverWrites: Bool = false) -> String? {
    let r = Rig()
    r.rec.recoverResult = false
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: "USB")
    for line in lines { r.log(dir, line) }
    if recoverWrites {
        // --recover appends to the same capture.log, and a tick may land while it runs.
        r.rec.onRecover = { d in r.log(d, "Could not recover \(d.path): no working files"); s.tick() }
    }
    r.rec.exit(r.rec.nextPid, code, verifies: false)
    r.at(1)
    return r.json(dir)["error"] as? String
}
check(failedStartError(["No input device matching \"USB\".", "Available devices:", "  MacBook Pro Microphone", "  Studio Display Microphone"], exit: 1)
        == "No input device matching \"USB\".", "E: the device-list output gives the No input device matching line")
check(failedStartError(["Starting recording...", "Recording started at 10:00", "  Microphone: USB", "Press Ctrl+C to stop.",
                        "health mic=ok system=ok", "Paused", "Resumed", "", "Stopping..."], exit: 1)
        == "the recording was interrupted; its files are kept", "E: progress lines are never the error")
check(failedStartError(["Starting recording...", "Press Ctrl+C to stop."], exit: 128 + SIGKILL)
        == "the recorder stopped unexpectedly (signal 9)", "E: a recorder killed by a signal says so")
check(failedStartError(["Failed to create output files: disk full"], exit: 1, recoverWrites: true)
        == "Failed to create output files: disk full", "E: the recorder's reason is kept while --recover writes to the log")

// Ruling F: every signal to an adopted pid is checked first; a pid that is no longer the recorder means it exited.
func adoptedLive(_ r: Rig) -> (Session, URL) {
    let dir = r.meeting("2026-10-29_0955") { $0.started = r.clock.base.addingTimeInterval(-300); $0.state = .recording }
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    let s = r.make()
    s.adopt()
    return (s, dir)
}
for action in ["pause", "stop"] {
    let r = Rig()
    let (s, dir) = adoptedLive(r)
    r.rec.running[dir.path] = nil // it exited; its pid now belongs to something else
    r.rec.verified.insert(dir.path)
    if action == "pause" { s.pause() } else { _ = s.stop() }
    check(r.rec.signals.isEmpty, "F: \(action) sends nothing to a reused pid")
    check(s.phase == .idle && r.stateOf(dir) == "queued" && r.finished.count == 1, "F: \(action) treats it as exited (the dead path)")
}
do {
    let r = Rig()
    let (s, dir) = adoptedLive(r)
    r.clock.t = 30
    s.pause()
    r.rec.running[dir.path] = nil
    r.rec.verified.insert(dir.path)
    s.resume()
    check(r.rec.sent(SIGUSR2) == 0 && s.phase == .idle && r.stateOf(dir) == "queued", "F: resume sends nothing to a reused pid")
}
do {
    let r = Rig()
    let (s, dir) = adoptedLive(r)
    r.rec.findUnknown = true
    s.pause()
    check(r.rec.signals.isEmpty && s.phase == .recording(dir), "F: pause does nothing while find cannot tell")
    _ = s.stop()
    check(r.rec.signals.isEmpty && s.phase == .finalising(dir), "F: stop sends no SIGINT while find cannot tell")
    r.rec.findUnknown = false
    r.at(1)
    check(r.rec.sent(SIGINT) == 1 && r.rec.signals.last?.pid == 4242, "F: SIGINT goes once find confirms the pid")
}

// Task 4 P1: a stop held while find is unknown starts its exit wait when SIGINT is finally sent,
// so SIGINT and SIGTERM never land on the same tick and the recorder gets its full time to finalise.
do {
    let r = Rig()
    let (s, dir) = adoptedLive(r) // started 300 s ago: exit limit 60 + 300 / 60 = 65 s
    r.rec.findUnknown = true
    _ = s.stop()
    r.at(50)
    r.at(101)
    check(r.rec.signals.isEmpty && s.phase == .finalising(dir), "P1: nothing is sent while find cannot tell")
    r.rec.findUnknown = false
    r.at(102)
    check(r.rec.sent(SIGINT) == 1 && r.rec.sent(SIGTERM) == 0, "P1: the held SIGINT goes alone, no SIGTERM on the same tick")
    r.at(102 + 64)
    check(r.rec.sent(SIGTERM) == 0 && r.rec.sent(SIGKILL) == 0, "P1: no SIGTERM before a full exit wait from the SIGINT")
    r.at(102 + 65)
    check(r.rec.sent(SIGTERM) == 1 && r.rec.sent(SIGKILL) == 0, "P1: SIGTERM a full exit wait after the SIGINT")
    r.rec.exit(4242, 0, verifies: true)
    r.at(102 + 66)
    check(s.phase == .idle && r.stateOf(dir) == "queued", "P1: a recorder that then finishes is queued")
}

// Ruling G: a failed orphan that was stopped for disk space keeps that reason.
do {
    let r = Rig()
    r.rec.recoverResult = false
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .finalising; $0.error = Session.diskStopped }
    let s = r.make()
    s.adopt()
    check(r.stateOf(orphan) == "failed" && r.json(orphan)["error"] as? String == Session.diskStoppedFailed,
          "G: a failed disk-stopped orphan keeps the disk reason")
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
    check(child.lastMessage(dir: dir) == "arg USB Mic", "M2/E: lastMessage skips health and progress lines (\"Stopping...\")")
    check(text.contains("arg --record\narg -o\narg \(dir.path)\narg -n\narg meeting\narg -d\narg USB Mic\n"),
          "the recorder gets --record -o <dir> -n meeting -d <mic>")
    check(child.recover(dir: dir) == .failed, "recover fails when --recover exits 1")
    fm.createFile(atPath: dir.appendingPathComponent("busy").path, contents: Data())
    check(child.recover(dir: dir) == .busy, "A: recover is busy when --recover exits 75")
    fm.createFile(atPath: dir.appendingPathComponent("can-recover").path, contents: Data())
    check(child.recover(dir: dir) == .recovered, "recover succeeds when --recover exits 0")
    check(child.verify(dir: dir) == nil, "verify fails with no audio")
    let killedDir = try! MeetingFolder.create(in: freshRoot(), at: Date())
    let killed = try! child.launch(dir: killedDir, mic: nil) { _ in }
    child.signal(killed, SIGKILL)
    check(waitFor(5) { !child.isRunning(killed) } && child.exitStatus(killed) == 128 + SIGKILL, "E: a recorder killed by SIGKILL reports 128 + 9")

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

// MARK: - Processing queue (Task 5)

/// Records each run; the test ends a run by calling `finish`.
final class FakeRunner: PipelineRunner {
    struct Call {
        let audio: URL
        let progress: URL
        let attempt: String
        let done: (Int32, String) -> Void
        /// meeting.json as it was when the run began.
        let stateAtRun: String?
        let attemptsAtRun: Int?
        let attemptAtRun: String?
        let errorAtRun: String?
    }
    var calls: [Call] = []
    func run(audio: URL, progress: URL, attempt: String, done: @escaping (Int32, String) -> Void) -> Int32 {
        let json = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: audio.deletingLastPathComponent()
            .appendingPathComponent("meeting.json")))) as? [String: Any]) ?? [:]
        calls.append(Call(audio: audio, progress: progress, attempt: attempt, done: done,
                          stateAtRun: json["state"] as? String, attemptsAtRun: (json["attempts"] as? NSNumber)?.intValue,
                          attemptAtRun: json["attempt"] as? String, errorAtRun: json["error"] as? String))
        return Int32(40000 + calls.count)
    }
    var folders: [String] { calls.map { $0.audio.deletingLastPathComponent().lastPathComponent } }
    /// Ends run `i`: on success it writes the transcript and minutes, as `meetingbox process` does.
    func finish(_ i: Int, _ status: Int32, _ line: String = "", writeOutputs: Bool = true) {
        let dir = calls[i].audio.deletingLastPathComponent()
        if status == 0 && writeOutputs {
            try! "[00:00:01] Me: hello\n".write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try! "the minutes\n".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        }
        calls[i].done(status, line)
    }
}

/// `ps -o lstart=` for a PID, as `meetingbox process` writes it into the lock's owner file.
func lstartOf(_ pid: Int32) -> String {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "lstart=", "-p", String(pid)]
    p.environment = ["LC_ALL": "C", "TZ": "UTC0"]
    p.standardOutput = out
    try! p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
/// A PID nothing runs under any more.
let deadPid: Int32 = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! p.run()
    p.waitUntilExit()
    return p.processIdentifier
}()
let me = getpid()

final class QRig {
    let root = freshRoot()
    let store: MeetingStore
    let runner = FakeRunner()
    var queue: ProcessingQueue!
    var finished: [(String, Bool)] = []
    var changes = 0

    init() {
        store = MeetingStore(root: root.appendingPathComponent("Meetings"))
        try! fm.createDirectory(at: store.root, withIntermediateDirectories: true)
    }
    @discardableResult
    func make() -> ProcessingQueue {
        queue = ProcessingQueue(store: store, runner: runner, tickQueue: nil)
        queue.onFinished = { [unowned self] in self.finished.append(($0.lastPathComponent, $1)) }
        queue.onChange = { [unowned self] in self.changes += 1 }
        return queue
    }
    func meeting(_ name: String, files: [String: String] = [:], _ change: ((inout MeetingRecord) -> Void)? = nil) -> URL {
        let dir = store.root.appendingPathComponent(name, isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (f, body) in files { try! body.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        if let change = change { try! store.update(dir, change) }
        return dir
    }
    func json(_ dir: URL) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meeting.json")))) as? [String: Any]) ?? [:]
    }
    func state(_ dir: URL) -> String? { json(dir)["state"] as? String }
    func attempts(_ dir: URL) -> Int? { (json(dir)["attempts"] as? NSNumber)?.intValue }
    func attempt(_ dir: URL) -> String? { json(dir)["attempt"] as? String }
    func error(_ dir: URL) -> String? { json(dir)["error"] as? String }
    /// A `.processing` lock as `meetingbox process` makes it. `owner` nil: a lock with no owner yet.
    func lock(_ dir: URL, owner: String?) {
        let l = dir.appendingPathComponent(".processing")
        try! fm.createDirectory(at: l, withIntermediateDirectories: true)
        if let owner = owner { try! (owner + "\n").write(to: l.appendingPathComponent("owner"), atomically: true, encoding: .utf8) }
    }
    func unlock(_ dir: URL) {
        let l = dir.appendingPathComponent(".processing")
        try? fm.removeItem(at: l.appendingPathComponent("owner"))
        try? fm.removeItem(at: l)
    }
    func result(_ dir: URL, attempt: String, status: Int, started: Date) {
        let iso = ISO8601DateFormatter()
        try! "attempt=\(attempt) status=\(status) started=\(iso.string(from: started)) finished=\(iso.string(from: Date()))\n"
            .write(to: dir.appendingPathComponent(".process-result"), atomically: true, encoding: .utf8)
    }
    func outputs(_ dir: URL, at date: Date) {
        for f in ["transcript.txt", "notes.md"] {
            let u = dir.appendingPathComponent(f)
            try! "text\n".write(to: u, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
    }
}

func queued(_ r: inout MeetingRecord) { r.state = .queued }

// enqueue: queued before anything runs, one at a time, in order, never twice
do {
    let r = QRig()
    let q = r.make()
    let a = r.meeting("2026-10-29_0900") { $0.state = .queued; $0.error = "left over" }
    let b = r.meeting("2026-10-29_1000", queued)
    let c = r.meeting("2026-10-29_1100", queued)
    let failedOne = r.meeting("2026-10-29_0800") { $0.state = .failed; $0.error = "it broke"; $0.attempts = 3 }
    q.enqueue(a)
    check(r.runner.calls.count == 1 && q.current?.lastPathComponent == a.lastPathComponent, "Q: enqueue starts the first job at once")
    let first = r.runner.calls.first
    check(first?.stateAtRun == "processing" && first?.attemptsAtRun == 1 && first?.attemptAtRun == first?.attempt
          && first?.errorAtRun == nil, "Q: a job starts as processing, attempts 1, its attempt stored, error cleared")
    check(first?.audio.lastPathComponent == "audio.m4a" && first?.progress.deletingLastPathComponent().lastPathComponent == a.lastPathComponent,
          "Q: the runner gets the folder's audio.m4a and a progress file in the folder")
    q.enqueue(c)
    q.enqueue(b)
    q.enqueue(failedOne)
    check(r.state(failedOne) == "failed" && r.error(failedOne) == "it broke" && r.attempts(failedOne) == 3,
          "M2: enqueue ignores a failed meeting")
    q.retry(failedOne)
    check(r.state(failedOne) == "queued" && r.attempts(failedOne) == nil && r.error(failedOne) == nil,
          "M2: retry writes a failed meeting queued, attempts reset, before anything runs for it")
    q.enqueue(b); q.enqueue(a); q.enqueue(c); q.enqueue(failedOne); q.retry(failedOne)
    check(r.runner.calls.count == 1, "Q: one job at a time, and a folder queued or processing is not added twice")
    check(r.state(b) == "queued" && r.state(c) == "queued", "Q: waiting jobs stay queued on disk")
    r.runner.finish(0, 0)
    check(r.state(a) == "done" && r.error(a) == nil && r.json(a)["stage"] == nil, "Q: success writes done")
    check(r.runner.folders == [a, c].map { $0.lastPathComponent }, "Q: the next job runs when one ends, in the order asked")
    r.runner.finish(1, 1, "transcription failed on both sides")
    check(r.state(c) == "failed" && r.error(c) == "transcription failed on both sides",
          "Q: a failure writes failed with the last stderr line")
    check(r.runner.calls.count == 3 && r.runner.folders[2] == b.lastPathComponent, "Q: after a failure the next job still runs")
    r.runner.finish(2, 0)
    r.runner.finish(3, 0)
    check(r.runner.calls.count == 4 && q.current == nil && q.stage == nil, "Q: the queue empties")
    check(r.finished.map { $0.0 } == [a, c, b, failedOne].map { $0.lastPathComponent }
          && r.finished.map { $0.1 } == [true, false, true, true], "Q: onFinished reports each folder and whether it worked")
    q.enqueue(a)
    check(r.runner.calls.count == 4 && r.state(a) == "done", "Q: a done meeting is never processed again")
    q.retry(a)
    check(r.runner.calls.count == 4 && r.state(a) == "done", "M2: retry leaves anything but a failed meeting alone")
    let attemptsBefore = r.runner.calls.map { $0.attempt }
    check(Set(attemptsBefore).count == 4, "Q: every run gets its own attempt")
}

// what enqueue refuses
do {
    let r = QRig()
    let q = r.make()
    let old = r.meeting("2026-01-05_0900", files: ["notes.md": "old minutes", "audio.m4a": "aac"])
    let unprocessed = r.meeting("2026-01-06_0900") { $0.state = .unprocessed }
    let recording = r.meeting("2026-01-07_0900") { $0.state = .recording }
    let finalising = r.meeting("2026-01-08_0900") { $0.state = .finalising }
    let bare = r.meeting("2026-01-09_0900", files: ["audio.m4a": "aac"])
    for d in [old, unprocessed, recording, finalising, bare] { q.enqueue(d) }
    check(r.runner.calls.isEmpty, "Q: enqueue never runs an old, unprocessed, recording, finalising or unrecorded folder")
    check(!fm.fileExists(atPath: old.appendingPathComponent("meeting.json").path)
          && !fm.fileExists(atPath: bare.appendingPathComponent("meeting.json").path)
          && r.state(unprocessed) == "unprocessed" && r.state(recording) == "recording" && r.state(finalising) == "finalising",
          "Q: and writes nothing for them")
}

// a busy refusal (exit 75): nothing ran, so nothing is counted; it runs again once the lock goes
do {
    let r = QRig()
    let q = r.make()
    let a = r.meeting("2026-10-29_0900", queued)
    q.enqueue(a)
    r.lock(a, owner: "\(me) \(lstartOf(me))")
    r.runner.finish(0, 75, "     error this meeting is already being processed: \(a.path)")
    check(r.state(a) == "processing" && r.attempts(a) == 0 && r.runner.calls.count == 1 && q.current != nil,
          "Q: refused as already being processed: not failed, not counted, waiting")
    q.tick()
    check(r.runner.calls.count == 1, "Q: still waiting while the other process holds the lock")
    r.unlock(a)
    q.tick()
    check(r.runner.calls.count == 2 && r.attempts(a) == 1 && r.runner.calls[1].attempt != r.runner.calls[0].attempt,
          "Q: once the lock goes it runs, attempts 1, with a new attempt")
    r.runner.finish(1, 0)
    check(r.state(a) == "done", "Q: and finishes")
}

// success needs the minutes; stage follows the progress file
do {
    let r = QRig()
    let q = r.make()
    let a = r.meeting("2026-10-29_0900", queued)
    let b = r.meeting("2026-10-29_1000", queued)
    q.enqueue(a)
    q.enqueue(b)
    let progress = r.runner.calls[0].progress
    check(fm.fileExists(atPath: progress.path) && ((try? Data(contentsOf: progress))?.isEmpty ?? false) && mode(progress) == 0o600,
          "Q: the progress file starts empty and private")
    let before = r.changes
    try! "transcribing\n".write(to: progress, atomically: false, encoding: .utf8)
    q.tick()
    check(q.stage == "transcribing" && r.json(a)["stage"] as? String == "transcribing" && r.changes > before,
          "Q: stage follows the progress file, into meeting.json, with onChange")
    let h = try! FileHandle(forWritingTo: progress)
    h.seekToEndOfFile()
    h.write(Data("speakers\nmin".utf8))
    h.closeFile()
    q.tick()
    check(q.stage == "speakers", "Q: stage is the last whole line")
    check(ProcessingQueue.label("transcribing") == "Transcribing" && ProcessingQueue.label("speakers") == "Finding speakers"
          && ProcessingQueue.label("minutes") == "Writing minutes", "Q: stages read as Transcribing, Finding speakers, Writing minutes")
    r.runner.finish(0, 0, writeOutputs: false)
    check(r.state(a) == "failed" && (r.error(a) ?? "").contains("minutes"), "Q: status 0 with no minutes written is a failure")
    check(q.current?.lastPathComponent == b.lastPathComponent && q.stage == nil, "Q: stage resets for the next job")
    r.runner.finish(1, 2, "")
    check(r.error(b) == "processing failed (exit 2)", "Q: a failure with nothing on stderr names the exit status")
}

// Review Focus 4: the app crashed with five queued and one processing; a new queue picks all six up
do {
    let r = QRig()
    let q1 = r.make()
    let names = ["2026-10-29_0900", "2026-10-29_1000", "2026-10-29_1100", "2026-10-29_1200", "2026-10-29_1300", "2026-10-29_1400"]
    let dirs = names.map { r.meeting($0, queued) }
    let old = r.meeting("2026-01-05_0900", files: ["notes.md": "old minutes", "audio.m4a": "aac"])
    let unprocessed = r.meeting("2026-01-06_0900") { $0.state = .unprocessed }
    let done = r.meeting("2026-01-07_0900") { $0.state = .done }
    let failed = r.meeting("2026-01-08_0900") { $0.state = .failed; $0.error = "no" }
    let untouched = [old, unprocessed, done, failed].map { try? Data(contentsOf: $0.appendingPathComponent("meeting.json")) }
    for d in dirs { q1.enqueue(d) }
    check(r.state(dirs[0]) == "processing" && dirs.dropFirst().allSatisfy { r.state($0) == "queued" },
          "RF4: one processing and five queued on disk when the app dies")
    r.queue = nil // the app crashed: its runner's callbacks never come
    let runs = r.runner.calls.count
    let q2 = r.make()
    q2.resume()
    let fresh = Array(r.runner.calls[runs...])
    check(fresh.count == 1 && fresh[0].audio.deletingLastPathComponent().lastPathComponent == names[0]
          && fresh[0].attemptsAtRun == 2 && fresh[0].attempt != r.runner.calls[0].attempt,
          "RF4: the interrupted job (no lock, no result) is retried with attempts 2 and a new attempt")
    for i in 0..<6 { r.runner.finish(runs + i, 0) }
    check(r.runner.calls.count == runs + 6 && Array(r.runner.calls[runs...]).map { $0.audio.deletingLastPathComponent().lastPathComponent } == names,
          "RF4: all six run, one at a time, oldest first")
    check(dirs.allSatisfy { r.state($0) == "done" }, "RF4: all six end done")
    let after = [old, unprocessed, done, failed].map { try? Data(contentsOf: $0.appendingPathComponent("meeting.json")) }
    check(after == untouched && !fm.fileExists(atPath: old.appendingPathComponent("meeting.json").path),
          "RF4: resume never touches old, unprocessed, done or failed meetings")
    q2.resume()
    check(r.runner.calls.count == runs + 6, "RF4: resume again finds nothing to do")
}

// Review Focus 4: the processing one, case by case
func resumed(_ setUp: (QRig, URL) -> Void) -> (QRig, URL, ProcessingQueue) {
    let r = QRig()
    let dir = r.meeting("2026-10-29_0900") { $0.state = .processing; $0.attempts = 1; $0.attempt = "attempt-one" }
    setUp(r, dir)
    let q = r.make()
    q.resume()
    return (r, dir, q)
}
do {
    // the owner is alive: wait for the lock to go, then read the result
    let t0 = Date().addingTimeInterval(-60)
    let (r, dir, q) = resumed { r, dir in r.lock(dir, owner: "\(me) \(lstartOf(me))") }
    let other = r.meeting("2026-10-29_1000", queued)
    q.enqueue(other)
    check(r.runner.calls.isEmpty && q.current?.lastPathComponent == dir.lastPathComponent && r.state(other) == "queued",
          "RF4: a live owner is waited for; nothing else runs meanwhile")
    try! "transcribing\nminutes\n".write(to: dir.appendingPathComponent(".process-progress"), atomically: true, encoding: .utf8)
    q.tick()
    check(r.runner.calls.isEmpty && q.stage == ProcessingQueue.waitingStage && q.stage == "waiting for another meetingbox",
          "M3: while another holder works, stage says so, not a stale progress file")
    r.result(dir, attempt: "attempt-one", status: 0, started: t0)
    r.outputs(dir, at: Date())
    r.unlock(dir)
    q.tick()
    check(r.state(dir) == "done" && r.runner.calls.count == 1 && r.runner.folders == [other.lastPathComponent],
          "RF4: its result (our attempt, status 0, fresh outputs) gives done, then the next job runs")
    check(r.finished.first.map { $0.0 == dir.lastPathComponent && $0.1 } ?? false, "RF4: onFinished reports it done")
    check(((try? Data(contentsOf: dir.appendingPathComponent(".process-progress")))?.isEmpty ?? true),
          "M3: the progress file is emptied when the job settles")
}
do {
    let (r, dir, _) = resumed { r, dir in r.result(dir, attempt: "someone-else", status: 0, started: Date().addingTimeInterval(-60))
                                          r.outputs(dir, at: Date()) }
    check(r.runner.calls.count == 1 && r.attempts(dir) == 2 && r.attempt(dir) != "attempt-one" && r.runner.calls[0].attempt == r.attempt(dir),
          "RF4: a result for another attempt means a retry with attempts + 1 and a new attempt")
}
do {
    let (r, dir, _) = resumed { r, dir in r.lock(dir, owner: "\(deadPid) Thu Jan  1 00:00:00 2026") }
    check(r.runner.calls.count == 1 && r.attempts(dir) == 2, "RF4: a dead owner and no result means a retry")
}
do {
    let (r, dir, _) = resumed { r, dir in r.lock(dir, owner: "\(me) Thu Jan  1 00:00:00 2026") }
    check(r.runner.calls.count == 1 && r.attempts(dir) == 2, "RF4: a live PID with another start time is a reused PID: retry")
}
do {
    let (r, dir, _) = resumed { r, dir in r.result(dir, attempt: "attempt-one", status: 0, started: Date())
                                          r.outputs(dir, at: Date().addingTimeInterval(-3600)) }
    check(r.runner.calls.count == 1 && r.attempts(dir) == 2, "RF4: our result with outputs older than the run is not success: retry")
}
do {
    let (r, dir, _) = resumed { r, dir in r.result(dir, attempt: "attempt-one", status: 143, started: Date())  }
    check(r.runner.calls.count == 1 && r.attempts(dir) == 2, "RF4: our result ended by a signal is an interruption: retry")
}
do {
    let (r, dir, _) = resumed { r, dir in r.result(dir, attempt: "attempt-one", status: 1, started: Date()) }
    check(r.runner.calls.isEmpty && r.state(dir) == "failed" && r.error(dir) == "processing failed (exit 1)",
          "RF4: our result with a failing status is a failure, not a retry")
}
do {
    let (r, _, q) = resumed { r, dir in r.lock(dir, owner: "garbled") }
    check(r.runner.calls.isEmpty && q.current != nil, "M7: a garbled owner with a fresh change time is waited for, as in the script")
}
do {
    let (r, dir, q) = resumed { r, dir in r.lock(dir, owner: nil) }
    check(r.runner.calls.isEmpty && q.current != nil, "RF4: a lock with no owner yet and a fresh change time is waited for")
    r.unlock(dir)
    q.tick()
    check(r.runner.calls.count == 1 && r.attempts(dir) == 2, "RF4: once it goes, with no result, a retry")
}
do {
    let r = QRig()
    let dir = r.meeting("2026-10-29_0900") { $0.state = .processing; $0.attempts = 3; $0.attempt = "attempt-three" }
    let next = r.meeting("2026-10-29_1000", queued)
    let q = r.make()
    q.resume()
    check(r.state(dir) == "failed" && r.error(dir) == "processing kept stopping part way",
          "RF4: at attempts 3 an interrupted job becomes failed: processing kept stopping part way")
    check(r.runner.folders == [next.lastPathComponent], "RF4: and the next job runs")
    _ = q
}
do {
    // attempts 1, 2, 3 then failed, across three crashes
    let r = QRig()
    let dir = r.meeting("2026-10-29_0900", queued)
    var q: ProcessingQueue? = r.make()
    q!.enqueue(dir)
    var seen = [r.attempts(dir)]
    for _ in 0..<3 {
        q = nil
        r.queue = nil
        q = r.make()
        q!.resume()
        seen.append(r.state(dir) == "failed" ? -1 : r.attempts(dir))
    }
    check(seen == [1, 2, 3, -1] && r.runner.calls.count == 3 && r.error(dir) == "processing kept stopping part way",
          "RF4: an interrupted job is retried at most three times, then failed")
}

// the lock and result as the real script writes them
do {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let home = freshRoot()
    let dir = freshRoot()
    func hold(_ attempt: String, tz: String? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", """
            sed '/^# -* main$/,$d' "$1/meetingbox" > "$HOME/functions"; . "$HOME/functions"; set +e
            take_processing_lock "$2"; : > "$2/held"; while :; do sleep 0.1; done
            """, "_", repo.path, dir.path]
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MB_ATTEMPT": attempt]
        if let tz = tz { env["TZ"] = tz }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        return p
    }
    func waitFor(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; usleep(20_000) }
        return cond()
    }
    let ps = URL(fileURLWithPath: "/bin/ps")
    let held = dir.appendingPathComponent("held")
    let a = hold("attempt-a")
    check(waitFor(10) { fm.fileExists(atPath: held.path) } && ProcessingLock.owner(dir, ps: ps, now: Date()) == .alive,
          "the script's lock reads as alive while its owner runs")
    a.interrupt() // SIGINT: the script ends through its trap
    a.waitUntilExit()
    let result = ProcessResult.read(dir)
    check(ProcessingLock.owner(dir, ps: ps, now: Date()) == .gone && result?.attempt == "attempt-a" && result?.status == 130
          && result?.started != nil, "an interrupted script leaves no lock and a result with its attempt and status 130")
    try? fm.removeItem(at: held)
    let b = hold("attempt-b")
    check(waitFor(10) { fm.fileExists(atPath: held.path) }, "the script takes the lock again")
    kill(b.processIdentifier, SIGKILL)
    b.waitUntilExit()
    check(fm.fileExists(atPath: dir.appendingPathComponent(".processing").path) && ProcessingLock.owner(dir, ps: ps, now: Date()) == .gone
          && ProcessResult.read(dir)?.attempt == "attempt-a", "a script killed outright leaves a stale lock (gone) and no result of its own")
    check(ProcessingLock.owner(dir, ps: URL(fileURLWithPath: "/no-such-ps"), now: Date()) == .unknown,
          "the lock's owner is unknown when ps cannot tell")
    try? fm.removeItem(at: held)
    let c = hold("attempt-c", tz: "Pacific/Kiritimati")
    check(waitFor(10) { fm.fileExists(atPath: held.path) } && ProcessingLock.owner(dir, ps: ps, now: Date()) == .alive,
          "I1: a lock taken under another time zone reads as alive")
    c.interrupt()
    c.waitUntilExit()
    // The reader pins the zone too: a ps that prints the TZ it was given.
    let tzps = freshRoot().appendingPathComponent("ps")
    try! "#!/bin/bash\nprintf '%s\\n' \"${TZ:-unset}\"\n".write(to: tzps, atomically: true, encoding: .utf8)
    chmod(tzps.path, 0o700)
    let tzdir = freshRoot()
    do {
        let l = tzdir.appendingPathComponent(".processing")
        try! fm.createDirectory(at: l, withIntermediateDirectories: true)
        try! "\(me) UTC0\n".write(to: l.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
    }
    check(ProcessingLock.owner(tzdir, ps: tzps, now: Date()) == .alive, "I1: the app reads start times with TZ=UTC0")
}

// I2: the app goes away mid-run; the script carries on, and its result is accepted on resume
do {
    let r = QRig()
    let dir = r.meeting("2026-10-29_0900", queued)
    let script = freshRoot().appendingPathComponent("meetingbox")
    try! """
    #!/bin/bash
    set -euo pipefail
    d="$(dirname "$2")"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for i in 1 2 3 4 5 6; do echo "working $i" >&2; echo "out $i"; sleep 0.2; done
    echo text > "$d/transcript.txt"; echo minutes > "$d/notes.md"
    printf 'attempt=%s status=0 started=%s finished=%s\n' "$MB_ATTEMPT" "$started" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$d/.process-result"
    """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o700)
    var q: ProcessingQueue? = ProcessingQueue(store: r.store, runner: ScriptRunner(script: script, environment: [:]), tickQueue: nil)
    weak var gone = q
    q!.enqueue(dir)
    let attempt = r.attempt(dir)
    q = nil
    check(gone == nil && r.state(dir) == "processing", "I2: the queue is gone while its run goes on")
    let end = Date().addingTimeInterval(15)
    while Date() < end && ProcessResult.read(dir) == nil { usleep(50_000) }
    check(ProcessResult.read(dir)?.attempt == attempt && ProcessResult.read(dir)?.status == 0,
          "I2: the orphaned run still finishes with status 0")
    let q2 = r.make()
    q2.resume()
    check(r.state(dir) == "done" && r.runner.calls.isEmpty, "I2: a new queue accepts its result: done, nothing run again")
    let log = (try? String(contentsOf: dir.appendingPathComponent(".process-log"), encoding: .utf8)) ?? ""
    check(log.contains("working 6\n") && log.contains("out 6\n"), "I2: its output went on into .process-log")
}

// the real runner
do {
    let dir = freshRoot()
    let script = dir.appendingPathComponent("meetingbox")
    let log = dir.appendingPathComponent("log")
    try! """
    #!/bin/bash
    { for a in "$@"; do echo "arg $a"; done
      echo "sounds=$MB_SOUNDS"; echo "progress=$MB_PROGRESS_FILE"; echo "attempt=$MB_ATTEMPT"; echo "keep=$MB_KEEP_AUDIO"
      echo "path=$PATH"; echo "dir=${MB_DIR:-unset}"; } > "\(log.path)"
    echo "to stdout"
    echo "meetingbox transcribing" >&2
    printf '\\033[0;31m     error\\033[0m the transcript came out empty\\n\\n' >&2
    exit 3
    """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o700)
    let home = URL(fileURLWithPath: "/Users/someone")
    let runner = ScriptRunner(script: script, home: home, environment: ["PATH": "/usr/bin:/bin", "MB_DIR": "/elsewhere", "HOME": "/Users/someone"])
    let audio = dir.appendingPathComponent("audio.m4a")
    let progress = dir.appendingPathComponent(".process-progress")
    let processLog = dir.appendingPathComponent(".process-log")
    try! "an error from an earlier run\n".write(to: processLog, atomically: true, encoding: .utf8)
    let sem = DispatchSemaphore(value: 0)
    var got: (Int32, String)?
    let pid = runner.run(audio: audio, progress: progress, attempt: "the-attempt") { s, l in got = (s, l); sem.signal() }
    check(pid > 0, "ScriptRunner returns the worker's PID")
    check(sem.wait(timeout: .now() + 10) == .success, "ScriptRunner calls done")
    check(got?.0 == 3 && got?.1 == "the transcript came out empty", "ScriptRunner gives the exit status and the last stderr line")
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check(text.contains("arg process\narg \(audio.path)\n"), "ScriptRunner runs <script> process <audio>")
    check(text.contains("sounds=0\n") && text.contains("progress=\(progress.path)\n") && text.contains("attempt=the-attempt\n"),
          "ScriptRunner sets MB_SOUNDS=0, MB_PROGRESS_FILE and MB_ATTEMPT")
    check(text.contains("path=/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\n"),
          "ScriptRunner puts ~/.local/bin, /opt/homebrew/bin and /usr/local/bin before PATH")
    check(text.contains("dir=unset\n"), "ScriptRunner passes on no MB_* setting of its own environment")
    check(text.contains("keep=1\n"), "M1: ScriptRunner sets MB_KEEP_AUDIO=1")
    let logText = (try? String(contentsOf: processLog, encoding: .utf8)) ?? ""
    check(logText.hasPrefix("an error from an earlier run\n") && logText.contains("to stdout\n")
          && logText.contains("meetingbox transcribing\n") && mode(processLog) == 0o600,
          "I2: stdout and stderr are appended to <dir>/.process-log (0600), not a pipe")
    var quiet: (Int32, String)?
    let sem3 = DispatchSemaphore(value: 0)
    let quietScript = dir.appendingPathComponent("quiet")
    try! "#!/bin/bash\nexit 2\n".write(to: quietScript, atomically: true, encoding: .utf8)
    chmod(quietScript.path, 0o700)
    _ = ScriptRunner(script: quietScript, home: home, environment: [:]).run(audio: audio, progress: progress, attempt: "q") { s, l in
        quiet = (s, l); sem3.signal() }
    check(sem3.wait(timeout: .now() + 10) == .success && quiet?.0 == 2 && quiet?.1 == "",
          "I2: the last line comes only from this run's part of the log")
    let missing = ScriptRunner(script: dir.appendingPathComponent("no-such-script"), home: home, environment: [:])
    var gone: (Int32, String)?
    let sem2 = DispatchSemaphore(value: 0)
    _ = missing.run(audio: audio, progress: progress, attempt: "x") { s, l in gone = (s, l); sem2.signal() }
    check(sem2.wait(timeout: .now() + 5) == .success && gone?.0 == 127 && (gone?.1 ?? "").contains("could not start"),
          "ScriptRunner reports a script it cannot start")
}

// MARK: - The control socket (Task 6)

// parse: every request, mic and dir decoded, nothing else accepted.
do {
    check(ControlRequest.parse("status") == .status && ControlRequest.parse("pause") == .pause
          && ControlRequest.parse("resume") == .resume && ControlRequest.parse("stop") == .stop
          && ControlRequest.parse("show") == .show, "parse: status, pause, resume, stop and show")
    check(ControlRequest.parse("start") == .start(mic: nil, dir: nil)
          && ControlRequest.parse("toggle") == .toggle(mic: nil, dir: nil), "parse: start and toggle with nothing else")
    check(ControlRequest.parse("start mic=USB%20Mic dir=%2FUsers%2Fme%2FMy%20Meetings")
          == .start(mic: "USB Mic", dir: "/Users/me/My Meetings"), "parse: start decodes mic and dir")
    check(ControlRequest.parse("toggle dir=/tmp/x mic=A%3DB%25") == .toggle(mic: "A=B%", dir: "/tmp/x"),
          "parse: toggle decodes mic and dir in either order")
    check(ControlRequest.parse("start mic=Caf%C3%A9") == .start(mic: "Café", dir: nil), "parse: UTF-8 in a mic name")
    for bad in ["rm -rf /", "", " ", "status\nstop", "status\n", "stop\r", "status now", "Status", "start mic=a mic=b",
                "start colour=red", "start mic=%ZZ", "start  mic=a", "start mic", "start mic=", "show dir=/tmp",
                "start mic=a\u{0}"] {
        check(ControlRequest.parse(bad) == nil, "parse: refuses \(bad.debugDescription)")
    }
}

func testDefaults() -> UserDefaults {
    counter += 1
    // An absolute path keeps the suite's plist in the scratch folder, away from ~/Library/Preferences.
    return UserDefaults(suiteName: scratch.appendingPathComponent("prefs\(counter)").path)!
}

// Preferences: defaults on an empty suite, and they persist.
do {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let d = testDefaults()
    let p = Preferences(defaults: d, home: home)
    check(p.showMenuBar && p.floating == .whileRecording && p.showInDock && p.openMinutes && p.sounds
          && p.microphone == nil, "Preferences: defaults on an empty suite")
    check(p.meetingsFolder.path == "/Users/someone/Meetings", "Preferences: the meetings folder defaults to ~/Meetings")
    p.showMenuBar = false; p.floating = .never; p.showInDock = false; p.openMinutes = false; p.sounds = false
    p.meetingsFolder = URL(fileURLWithPath: "/Volumes/Work/Calls", isDirectory: true)
    p.microphone = "USB Mic"
    let q = Preferences(defaults: d, home: home)
    check(!q.showMenuBar && q.floating == .never && !q.showInDock && !q.openMinutes && !q.sounds
          && q.meetingsFolder.path == "/Volumes/Work/Calls" && q.microphone == "USB Mic", "Preferences: every setting persists")
    p.floating = .always; p.microphone = nil
    let q2 = Preferences(defaults: d, home: home)
    check(q2.floating == .always && q2.microphone == nil, "Preferences: floating always, and the microphone back to the default")
    check(FloatingMode.allCases.map(\.rawValue) == ["always", "whileRecording", "never"], "FloatingMode: always, while recording, never")
    check(p.formatTimer(0) == "00:00" && p.formatTimer(59) == "00:59" && p.formatTimer(3599) == "59:59"
          && p.formatTimer(3600) == "1:00:00" && p.formatTimer(36_061) == "10:01:01", "formatTimer: mm:ss, then h:mm:ss")
    d.removePersistentDomain(forName: scratch.appendingPathComponent("prefs\(counter)").path)
}

/// A handler over a Rig's session; the meetings folder preference is the Rig's store root.
func handlerRig(tickQueue: DispatchQueue? = nil) -> (Rig, ControlHandler, Preferences) {
    let r = Rig()
    let s = r.make(tickQueue: tickQueue)
    let prefs = Preferences(defaults: testDefaults(), home: r.root)
    prefs.meetingsFolder = r.store.root
    return (r, ControlHandler(session: s, preferences: prefs), prefs)
}

// Fix 1 M4: the handler's queue is the session's tick queue (main when the session has none).
do {
    let q = DispatchQueue(label: "meetingbox.test.m4")
    let (r, h, _) = handlerRig(tickQueue: q)
    check(h.queue === q && r.session.tickQueue === q, "M4: the handler runs on the session's tick queue")
    let (_, hm, _) = handlerRig()
    check(hm.queue === DispatchQueue.main, "M4: a session with no tick queue gives the main queue")
}

// Fix 1 M9: pause and resume that cannot reach the recorder say so, and change nothing.
do {
    let (r, h, _) = handlerRig()
    let dir = r.meeting("2026-10-29_0955") { $0.started = r.clock.base.addingTimeInterval(-300); $0.state = .recording }
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    r.session.adopt()
    r.rec.findUnknown = true
    check(h.reply(for: .pause) == "error cannot reach the recorder right now, try again" && r.rec.signals.isEmpty
          && r.session.phase == .recording(dir), "M9: pause while the recorder cannot be checked says so and changes nothing")
    r.rec.findUnknown = false
    check(h.reply(for: .pause) == "ok paused \(dir.path)", "M9: and works once it can")
    r.rec.findUnknown = true
    check(h.reply(for: .resume) == "error cannot reach the recorder right now, try again" && r.session.phase == .paused(dir),
          "M9: resume while the recorder cannot be checked says so and changes nothing")
}

// Fix 1 M3: free space is measured where the recording goes, and unknown is not unlimited.
do {
    let (r, h, _) = handlerRig()
    let other = freshRoot().appendingPathComponent("Elsewhere")
    _ = h.reply(for: .start(mic: nil, dir: other.path))
    check(r.freeAsked.first.map { $0.standardizedFileURL.path } == other.standardizedFileURL.path,
          "M3: the start floor is measured on the folder the request names")
    r.freeAsked.removeAll()
    r.at(1)
    let folder = r.session.phase.folder
    check(folder != nil && r.freeAsked.last == folder, "M3: while recording, on the recording's own folder")
}
do {
    let r = Rig()
    r.free = nil
    let s = r.make()
    let dir = try? s.start(root: r.store.root, mic: nil)
    check(dir != nil && r.rec.launches.count == 1, "M3: start is allowed when free space cannot be read")
    check(r.logs.count == 1 && r.logs[0].contains("cannot read the free space"), "M3: and that is logged")
    r.at(1); r.at(2)
    check(dir.map { s.phase == .recording($0) } == true && r.rec.sent(SIGINT) == 0,
          "M3: and unknown free space never stops the recording")
    check(r.logs.count == 2 && r.logs[1].contains("the disk stop waits"), "M3: logged once while recording, not every tick")
}

// reply: the session's answers, one line each.
do {
    let (r, h, prefs) = handlerRig()
    prefs.microphone = "Desk Mic"
    var started: [URL] = []
    var stopped: [URL] = []
    var shown = 0
    h.onStarted = { started.append($0) }
    h.onStopped = { stopped.append($0) }
    h.onShow = { shown += 1 }
    check(h.reply(for: .status) == "ok idle -", "reply: status when idle")
    check(h.reply(for: .pause) == "error not recording" && h.reply(for: .resume) == "error not recording"
          && h.reply(for: .stop) == "error not recording", "reply: pause, resume and stop with nothing recording")
    let first = h.reply(for: .start(mic: nil, dir: nil))
    let folders = names(r.store.root)
    let dir = Session.folderURL(r.store.root.appendingPathComponent(folders.first ?? "none").path)
    check(folders.count == 1 && first == "ok recording \(dir.path)", "reply: ok recording <dir> after a start (\(first))")
    check(r.rec.launches.count == 1 && r.rec.launches[0].mic == "Desk Mic", "reply: start uses the microphone preference")
    check(started == [dir], "reply: a start is announced once (for the start sound)")
    check(h.reply(for: .start(mic: nil, dir: nil)) == "error already recording in \(dir.path)", "reply: a second start says already recording in <dir>")
    check(h.reply(for: .toggle(mic: nil, dir: nil)) == "ok finalising \(dir.path)", "reply: toggle while recording stops")
    check(stopped == [dir], "reply: a stop is announced once (for the stop sound)")
    check(h.reply(for: .toggle(mic: nil, dir: nil)) == "ok finalising \(dir.path)" && stopped == [dir],
          "reply: toggle while finalising changes nothing and announces nothing")
    _ = h.reply(for: .show)
    check(shown == 1, "reply: show asks the app to show itself")
}
do {
    let (r, h, _) = handlerRig()
    _ = h.reply(for: .start(mic: "USB", dir: nil))
    let dir = Session.folderURL(r.store.root.appendingPathComponent(names(r.store.root)[0]).path)
    check(r.rec.launches.last?.mic == "USB", "reply: a request's mic beats the preference")
    check(h.reply(for: .pause) == "ok paused \(dir.path)" && h.reply(for: .status) == "ok paused \(dir.path)", "reply: pause, then status says paused")
    check(h.reply(for: .pause) == "ok paused \(dir.path)" && r.rec.sent(SIGUSR1) == 1, "reply: a second pause sends nothing more")
    check(h.reply(for: .resume) == "ok recording \(dir.path)", "reply: resume")
    check(h.reply(for: .stop) == "ok finalising \(dir.path)" && r.rec.sent(SIGINT) == 1, "reply: ok finalising <dir> from stop")
    check(h.reply(for: .stop) == "ok finalising \(dir.path)" && r.rec.sent(SIGINT) == 1, "reply: stop again while finalising sends nothing")
    check(h.reply(for: .start(mic: nil, dir: nil)).hasPrefix("error already recording in "), "reply: no start while finalising")
}
do {
    let (r, h, _) = handlerRig()
    let other = freshRoot().appendingPathComponent("Elsewhere")
    let reply = h.reply(for: .start(mic: nil, dir: other.path))
    check(names(r.store.root).isEmpty && names(other).count == 1 && reply == "ok recording \(other.appendingPathComponent(names(other)[0]).path)",
          "reply: a request's dir beats Preferences.meetingsFolder")
}
do {
    let (r, h, _) = handlerRig()
    check(h.reply(for: .start(mic: nil, dir: "Meetings")).hasPrefix("error ") && r.rec.launches.isEmpty && names(r.store.root).isEmpty,
          "reply: a relative dir is refused and nothing is made")
}
do {
    let (r, h, _) = handlerRig()
    r.rec.launchError = FakeError(text: "Failed to start system audio: denied")
    var started = 0
    h.onStarted = { _ in started += 1 }
    check(h.reply(for: .start(mic: nil, dir: nil)) == "error Failed to start system audio: denied", "reply: error <launch message> when the launch throws")
    check(started == 0 && h.reply(for: .status) == "ok idle -", "reply: a failed start plays nothing and leaves idle")
    r.rec.launchError = FakeError(text: "two\nlines")
    check(h.reply(for: .toggle(mic: nil, dir: nil)) == "error two lines", "reply: an error is always one line")
}

/// A short folder in /tmp: a socket path must fit in 104 bytes.
func shortTemp() -> URL {
    var template = Array("/tmp/mb-t6.XXXXXX".utf8CString)
    guard mkdtemp(&template) != nil else { fatalError("mkdtemp") }
    return URL(fileURLWithPath: String(cString: template), isDirectory: true)
}
/// Runs a program, feeds it `input`, and gives its exit status and stdout.
func run(_ path: String, _ args: [String], input: String = "") -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let inp = Pipe(), out = Pipe()
    p.standardInput = inp
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return (-1, "") }
    inp.fileHandleForWriting.write(Data(input.utf8))
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
func inode(_ u: URL) -> UInt64 {
    var st = stat()
    return lstat(u.path, &st) == 0 ? UInt64(st.st_ino) : 0
}
/// A socket file nobody listens on, as a crashed instance leaves it.
func deadSocket(_ path: URL) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        let bytes = Array(path.path.utf8)
        for (i, b) in bytes.enumerated() { buf[i] = b }
    }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    close(fd)
}

do {
    let tmp = shortTemp()
    defer { try? fm.removeItem(at: tmp) }
    let q = DispatchQueue(label: "meetingbox.test.tick")
    let (r, h, _) = handlerRig(tickQueue: q)
    let state = tmp.appendingPathComponent("state")
    let sock = state.appendingPathComponent("control.sock")
    let server = try? ControlServer(socket: sock, handler: h)
    server?.start()
    check(server != nil && mode(state) == 0o700 && mode(sock) == 0o600, "server: the folder is 0700 and the socket 0600")
    let nc = run("/usr/bin/nc", ["-U", "-w", "5", sock.path], input: "status\n")
    check(nc == (0, "ok idle -\n"), "server: answers status from a real nc -U (\(nc))")
    check(ControlClient.send("rm -rf /", to: sock) == "error unknown request", "server: an unknown request gets an error, nothing else")
    // Clients that connect and leave before they are served, as the stale-socket probe does: the
    // reply to them must fail quietly, never raise SIGPIPE for the whole app.
    for _ in 0..<50 { if case .connected(let fd) = ControlServer.connectTo(sock.path) { close(fd) } }
    usleep(200_000)
    check(ControlClient.send("status", to: sock) == "ok idle -", "server: clients that leave at once do no harm")

    // Review Focus 6: two starts at the same moment over two connections.
    q.sync { r.rec.launchDelay = 300_000 }
    let go = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let lock = NSLock()
    var replies: [String] = []
    for _ in 0..<2 {
        DispatchQueue.global().async(group: group) {
            go.wait()
            let reply = ControlClient.send("start", to: sock, timeout: 10) ?? "no reply"
            lock.lock(); replies.append(reply); lock.unlock()
        }
    }
    go.signal(); go.signal()
    group.wait()
    let oks = replies.filter { $0.hasPrefix("ok recording ") }
    let errs = replies.filter { $0.hasPrefix("error already recording in ") }
    check(oks.count == 1 && errs.count == 1, "RF6: two starts together give one ok recording and one already recording (\(replies))")
    check(q.sync { r.rec.launches.count } == 1 && names(r.store.root).count == 1, "RF6: and one launch, one folder")
    check(oks.first.map { String($0.dropFirst("ok recording ".count)) } == errs.first.map { String($0.dropFirst("error already recording in ".count)) },
          "RF6: both name the same folder")

    // A live listener's socket is never taken.
    let (_, h2, _) = handlerRig(tickQueue: q)
    let before = inode(sock)
    check((try? ControlServer(socket: sock, handler: h2)) == nil, "server: a socket with a live listener is not replaced")
    check(inode(sock) == before && ControlClient.send("status", to: sock)?.hasPrefix("ok recording ") == true,
          "server: and the first instance still answers on it")
    server?.stop()
    check(!fm.fileExists(atPath: sock.path), "server: stop removes its own socket")
    q.sync {} // let any tick finish before the rig goes
}

// Fix 1 I1: a start whose recorder dies straight away is an error with the recorder's reason,
// and plays no start sound; one that stays alive is ok. toggle takes the same path.
for verb in ["start", "toggle"] {
    let tmp = shortTemp()
    defer { try? fm.removeItem(at: tmp) }
    let q = DispatchQueue(label: "meetingbox.test.i1")
    let (r, h, _) = handlerRig(tickQueue: q)
    var sounds = 0
    h.onStarted = { _ in sounds += 1 }
    let sock = tmp.appendingPathComponent("control.sock")
    let server = try? ControlServer(socket: sock, handler: h)
    server?.start()
    q.sync {
        r.rec.recoverResult = false
        r.rec.dieOnLaunch = (1, "No input device matching \"USB\"")
    }
    let reply = ControlClient.send(verb, to: sock, timeout: 15)
    check(reply == "error No input device matching \"USB\"", "I1: \(verb): a recorder that dies at once gives error <its reason> (\(reply ?? "nil"))")
    check(q.sync { sounds } == 0 && q.sync { r.session.phase } == .idle, "I1: \(verb): no start sound, and idle")
    q.sync { r.rec.dieOnLaunch = nil }
    let ok = ControlClient.send(verb, to: sock, timeout: 15) ?? "nil"
    check(ok.hasPrefix("ok recording ") && q.sync { sounds } == 1, "I1: \(verb): a recorder that stays alive gives ok and one start sound (\(ok))")
    server?.stop()
    q.sync {}
}

// A socket left by a dead instance is replaced; anything that is not a socket is left alone.
do {
    let tmp = shortTemp()
    defer { try? fm.removeItem(at: tmp) }
    let (_, h, _) = handlerRig()
    let sock = tmp.appendingPathComponent("control.sock")
    deadSocket(sock)
    var st = stat()
    check(lstat(sock.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK && ControlClient.send("status", to: sock) == nil,
          "stale: a socket file nobody listens on")
    let q = DispatchQueue(label: "meetingbox.test.tick2")
    let (_, hq, _) = handlerRig(tickQueue: q)
    let server = try? ControlServer(socket: sock, handler: hq)
    server?.start()
    check(server != nil && ControlClient.send("status", to: sock) == "ok idle -", "stale: a socket left by a dead instance is replaced")
    server?.stop()
    let plain = tmp.appendingPathComponent("plain.sock")
    try! "keep me".write(to: plain, atomically: true, encoding: .utf8)
    check((try? ControlServer(socket: plain, handler: h)) == nil
          && (try? String(contentsOf: plain, encoding: .utf8)) == "keep me", "stale: a file that is not a socket is never removed")
    let long = tmp.appendingPathComponent(String(repeating: "x", count: 120))
    check((try? ControlServer(socket: long, handler: h)) == nil, "server: a socket path too long to bind is an error, not a crash")
}

// app.lock: one instance at a time, released by the kernel when its holder dies.
do {
    let tmp = shortTemp()
    defer { try? fm.removeItem(at: tmp) }
    let lockURL = tmp.appendingPathComponent("state/app.lock")
    let first = AppLock.take(lockURL)
    check(first != nil && mode(lockURL) == 0o600 && mode(lockURL.deletingLastPathComponent()) == 0o700, "app.lock: taken, 0600, in a 0700 folder")
    check(AppLock.take(lockURL) == nil, "app.lock: a second instance in the same state folder cannot take it")
    check(run("/usr/bin/lockf", ["-k", "-t", "0", lockURL.path, "/usr/bin/true"]).0 == 75, "app.lock: another process cannot take it either")
    first?.release()
    let again = AppLock.take(lockURL)
    check(again != nil, "app.lock: free again once released")
    again?.release()
    // A holder that is killed outright: the kernel releases its lock.
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    holder.arguments = ["-k", lockURL.path, "/bin/sleep", "30"]
    try! holder.run()
    var held = false
    for _ in 0..<50 where !held { usleep(100_000); held = AppLock.take(lockURL).map { $0.release(); return false } ?? true }
    check(held, "app.lock: held by another process")
    kill(holder.processIdentifier, SIGKILL)
    holder.waitUntilExit()
    let after = AppLock.take(lockURL)
    check(after != nil, "app.lock: free once its holder is killed")
    after?.release()
}

try? fm.removeItem(at: scratch)
if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
