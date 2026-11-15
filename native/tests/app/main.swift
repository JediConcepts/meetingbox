// sources: ../../app/Preferences.swift ../../app/ControlServer.swift ../../app/MeetingFolder.swift ../../app/MeetingStore.swift ../../app/Session.swift ../../app/ChildRecorder.swift ../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift ../../recorder/Finalise.swift ../../app/ProcessingQueue.swift ../../app/StatusPresentation.swift ../../app/StatusReducer.swift ../../app/LaunchMode.swift ../../app/LibraryPresentation.swift ../../app/LibraryModel.swift ../../app/PreferencesPresentation.swift ../../app/AppModel.swift ../../app/RecordingMenu.swift ../../app/BuildInfo.swift ../../app/VoiceSample.swift ../../app/Player.swift ../../app/TopBarPresentation.swift
// Meeting folders, the library store, and the recording session. Everything runs in temporary folders.
import AppKit
import AVFoundation
import Combine
import CoreServices

setvbuf(stdout, nil, _IOLBF, 0) // a crash then leaves every line before it
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
    // C4: a time the clocks skip (01:30 on 29 March 2026 in London) is still a meeting; impossible dates are not
    var london = Calendar(identifier: .gregorian)
    london.timeZone = TimeZone(identifier: "Europe/London")!
    let skipped = MeetingFolder.parse(root.appendingPathComponent("2026-03-29_0130"), calendar: london)
    check(skipped.map { london.dateComponents([.year, .month, .day], from: $0.date) == DateComponents(year: 2026, month: 3, day: 29) } == true,
          "C4: a folder named for a time the clocks skip (2026-03-29_0130 in London) is parsed, on its day")
    check(MeetingFolder.parse(root.appendingPathComponent("2026-03-29 0130 Early call"), calendar: london)?.title == "Early call",
          "C4: titled too")
    check(MeetingFolder.parse(root.appendingPathComponent("2026-02-31_1000"), calendar: london) == nil
          && MeetingFolder.parse(root.appendingPathComponent("2026-10-28_1060"), calendar: london) == nil,
          "C4: 31 February and minute 60 are still refused")
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
    // C6: a final extension with a letter in it would make the folder a file or a package to the Finder
    check(MeetingFolder.safeTitle("Q3 board deck.key") == "Q3 board deck-key", "C6: safeTitle: Q3 board deck.key gives Q3 board deck-key")
    check(MeetingFolder.safeTitle("Launch plan.app") == "Launch plan-app" && MeetingFolder.safeTitle("Notes.pages") == "Notes-pages",
          "C6: safeTitle: .app and .pages too")
    check(MeetingFolder.safeTitle("Budget v2.0") == "Budget v2.0", "C6: safeTitle: Budget v2.0 is unchanged (no letter after the dot)")
    check(MeetingFolder.safeTitle("Call with Dr. Smith") == "Call with Dr. Smith" && MeetingFolder.safeTitle("Ends with a dot.") == "Ends with a dot.",
          "C6: safeTitle: a dot inside a sentence, or a closing one, is not an extension")
    check(MeetingFolder.safeTitle("v1.2 review.key") == "v1.2 review-key", "C6: safeTitle: only the final dot changes")
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
    var recoverSays: String? = nil       // the last line a failed --recover printed
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
    var onLaunch: ((URL) -> Void)? = nil // told at each launch, before it returns, to see what else has happened by then

    func launch(dir: URL, mic: String?, onHealthLine: @escaping (String) -> Void) throws -> Int32 {
        if launchDelay > 0 { usleep(launchDelay) }
        if let e = launchError { throw e }
        onLaunch?(dir)
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
        return recoverResult ? .recovered : .failed(recoverSays)
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

    /// `otherRoots`: the store's other folders that recordings were started in (Preferences.otherRoots in the app).
    init(otherRoots: @escaping () -> [URL] = { [] }) {
        state = root.appendingPathComponent("state")
        store = MeetingStore(root: root.appendingPathComponent("Meetings"), otherRoots: otherRoots)
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
    check(r.rec.recovered.count == 1, "A3: a later adopt does not try a busy folder again sooner than 15 s after")
    r.clock.t = 15
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

// Ruling G: a failed orphan that was stopped for disk space keeps that reason. A meeting.json written
// before the wording changed (Session.diskStoppedLegacy) is the same stop as one written now, at all
// three places adopt reads it: the orphan sweep, a named recording whose recorder is gone, and one still found.
for (which, text) in [("new text", Session.diskStopped), ("old text", Session.diskStoppedLegacy)] {
    do {
        let r = Rig()
        r.rec.recoverResult = false
        let orphan = r.meeting("2026-10-28_0900") { $0.state = .finalising; $0.error = text }
        let s = r.make()
        s.adopt()
        check(r.stateOf(orphan) == "failed" && r.json(orphan)["error"] as? String == Session.diskStoppedFailed,
              "G: a failed disk-stopped orphan keeps the disk reason (\(which))")
    }
    do {
        let r = Rig()
        r.rec.recoverResult = false
        let dir = r.meeting("2026-10-28_0930") { $0.state = .recording; $0.error = text }
        r.writeState(dir)
        let s = r.make()
        s.adopt()
        check(r.stateOf(dir) == "failed" && r.json(dir)["error"] as? String == Session.diskStoppedFailed && s.phase == .idle,
              "G: so does a named recording whose recorder is gone (\(which))")
    }
    do {
        let r = Rig()
        r.rec.recoverResult = false
        let dir = r.meeting("2026-10-28_1000") { $0.state = .recording; $0.error = text }
        r.writeState(dir)
        r.rec.alive.insert(5151)
        r.rec.running[dir.path] = 5151
        let s = r.make()
        s.adopt()
        r.rec.exit(5151, 1, verifies: false)
        r.at(1)
        check(r.stateOf(dir) == "failed" && r.json(dir)["error"] as? String == Session.diskStoppedFailed,
              "G: so does a recorder found alive and then gone (\(which))")
    }
}
do {
    // Not every error is a disk stop: any other text, or none, ends as the generic interruption.
    let r = Rig()
    r.rec.recoverResult = false
    let other = r.meeting("2026-10-28_1100") { $0.state = .finalising; $0.error = "the microphone was unplugged" }
    let none = r.meeting("2026-10-28_1200") { $0.state = .finalising }
    let s = r.make()
    s.adopt()
    check(r.json(other)["error"] as? String == Session.interrupted && r.json(none)["error"] as? String == Session.interrupted,
          "G: a failed orphan with another reason, or none, is just interrupted")
    check(Session.isDiskStopped(Session.diskStopped) && Session.isDiskStopped(Session.diskStoppedLegacy)
          && !Session.isDiskStopped(Session.diskStoppedFailed) && !Session.isDiskStopped(Session.interrupted) && !Session.isDiskStopped(nil),
          "G: only the two disk-stop texts are the disk stop; the failed text is not")
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
    check(child.recover(dir: dir) == .failed("recovering \(dir.path)"), "recover fails when --recover exits 1, with the last line it printed")
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

// ChildRecorder runs the recorder from the helper bundle (Gate 2). The recorder checks in with
// the window server, so LaunchServices registers the bundle its executable is in. From the
// app's own executable it was taken for the app itself, and a recorder orphaned by a crash
// left the app impossible to reopen. The helper has an identifier of its own.
do {
    let helperTail = "Contents/Helpers/meetingbox-recorder.app/Contents/MacOS/meetingbox-recorder"
    let app = URL(fileURLWithPath: "/Users/someone/Applications/meetingbox.app", isDirectory: true)
    check(ChildRecorder.helperExecutable(in: app).path == "/Users/someone/Applications/meetingbox.app/" + helperTail,
          "G2: the helper's executable is Contents/Helpers/meetingbox-recorder.app/Contents/MacOS/meetingbox-recorder")
    check(ChildRecorder().executable.path == Bundle.main.bundleURL.appendingPathComponent(helperTail).path,
          "G2: ChildRecorder uses the helper by default, for --record and --recover")

    let bin = freshRoot()
    func script(_ name: String, _ body: String) -> URL {
        let url = bin.appendingPathComponent(name)
        try! "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
    let helper = bin.appendingPathComponent("helper/meetingbox-recorder")
    let legacy = bin.appendingPathComponent("legacy/meetingbox")
    let dirA = bin.appendingPathComponent("Meetings/a b")
    let dirB = bin.appendingPathComponent("Meetings/b")
    let dirC = bin.appendingPathComponent("Meetings/c")
    let dirD = bin.appendingPathComponent("Meetings/d")
    // A fixed process listing, in the shape of `ps -axo pid=,command=`.
    let listing = [
        "  100 /usr/sbin/cfprefsd agent",
        "  201 \(helper.path) --record -o \(dirA.path) -n meeting -d USB Mic",
        "  202 \(legacy.path) --record -o \(dirB.path) -n meeting",
        "  203 \(helper.path) --recover \(dirC.path)",
        "  204 \(legacy.path) --recover \(dirC.path)",
        "  205 \(helper.path) -o \(dirD.path) -n meeting",
        "  206 \(legacy.path)",
    ].joined(separator: "\n")
    let listed = script("ps-listing", "cat <<'EOF'\n\(listing)\nEOF")
    let finder = ChildRecorder(executable: helper, legacyExecutable: legacy, ps: listed)
    check(finder.find(dir: dirA) == .found(201), "G2: find matches a recorder under the helper's prefix")
    check(finder.find(dir: dirB) == .found(202), "G2: find matches a recorder the previous build started, under the old prefix")
    check(finder.find(dir: dirC) == .notFound, "G2: find ignores --recover, under either prefix")
    check(finder.find(dir: dirD) == .notFound, "G2: find needs --record -o <dir> -n")
    check(finder.find(dir: dirA.deletingLastPathComponent().appendingPathComponent("a")) == .notFound,
          "G2: find does not take a folder for its longer neighbour")
    // The order of the listing decides when both are there; the main executable of another app
    // in the same position is not a recorder.
    let foreign = ChildRecorder(executable: bin.appendingPathComponent("elsewhere/meetingbox-recorder"),
                                legacyExecutable: bin.appendingPathComponent("elsewhere/meetingbox"), ps: listed)
    check(foreign.find(dir: dirA) == .notFound && foreign.find(dir: dirB) == .notFound,
          "G2: find matches this app's executables only")

    // A missing helper is a clear error: nothing is started, no fallback to the app's own executable.
    let before = freshRoot()
    let dir = try! MeetingFolder.create(in: before, at: Date())
    let missing = ChildRecorder(executable: bin.appendingPathComponent("no-such/meetingbox-recorder"),
                                legacyExecutable: script("legacy-recorder", "echo ran > \"\(bin.path)/legacy-ran\""))
    var message = ""
    do { _ = try missing.launch(dir: dir, mic: nil) { _ in } } catch { message = error.localizedDescription }
    check(message == "the recorder is missing; run meetingbox setup", "G2: a missing helper gives the clear error (\(message))")
    check(!fm.fileExists(atPath: bin.appendingPathComponent("legacy-ran").path), "G2: a missing helper never falls back to the app's own executable")
    check(!fm.fileExists(atPath: dir.appendingPathComponent("capture.log").path), "G2: a missing helper leaves no capture.log behind")
    // present but not executable is as good as missing
    let flat = bin.appendingPathComponent("flat/meetingbox-recorder")
    try! fm.createDirectory(at: flat.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "x".write(to: flat, atomically: true, encoding: .utf8)
    chmod(flat.path, 0o644)
    var flatMessage = ""
    do { _ = try ChildRecorder(executable: flat).launch(dir: dir, mic: nil) { _ in } } catch { flatMessage = error.localizedDescription }
    check(flatMessage == "the recorder is missing; run meetingbox setup", "G2: a helper that is not executable gives the same error")
    // and with no helper at the default place, as in this test run
    var defaultMessage = ""
    do { _ = try ChildRecorder().launch(dir: dir, mic: nil) { _ in } } catch { defaultMessage = error.localizedDescription }
    check(defaultMessage == "the recorder is missing; run meetingbox setup", "G2: the default helper path is checked too")

    // --recover goes through the executable it was given, the helper, not the app's own.
    let recoverLog = bin.appendingPathComponent("recover-args")
    let recoverer = script("helper-recover", "echo \"$@\" > \"\(recoverLog.path)\"")
    let recovered = ChildRecorder(executable: recoverer, legacyExecutable: legacy).recover(dir: dir)
    check(recovered == .recovered && ((try? String(contentsOf: recoverLog, encoding: .utf8)) ?? "") == "--recover \(dir.path)\n",
          "G2: recover runs --recover <dir> through the helper")
}

// MARK: - Gate 2 fix round 1

// I1: a helper that is not there must not turn every recovery into a quiet "busy". Recovery never
// touches the window server, so it runs from the app's own executable, and says so in capture.log.
// "Busy" is only ever exit 75.
do {
    let bin = freshRoot()
    func script(_ name: String, _ body: String, mode: mode_t = 0o755) -> URL {
        let url = bin.appendingPathComponent(name)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, mode)
        return url
    }
    func newDir() -> URL { try! MeetingFolder.create(in: freshRoot(), at: Date()) }
    func log(_ dir: URL) -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("capture.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
    let missingNote = "meetingbox: the recorder helper is missing; recovering with the app's own executable"
    let absent = bin.appendingPathComponent("no-such/meetingbox-recorder")
    let ran = bin.appendingPathComponent("ran")

    // helper missing, the app's executable recovers
    do {
        let dir = newDir()
        let legacy = script("a/meetingbox", "echo \"$@\" > \"\(ran.path)\"; echo from-the-app >&2")
        let result = ChildRecorder(executable: absent, legacyExecutable: legacy).recover(dir: dir)
        check(result == .recovered, "I1: a missing helper recovers through the app's own executable")
        check(((try? String(contentsOf: ran, encoding: .utf8)) ?? "") == "--recover \(dir.path)\n", "I1: with --recover <dir>")
        check(log(dir) == [missingNote, "from-the-app"], "I1: capture.log says the helper was missing, once, then carries the recovery's own lines (\(log(dir)))")
        try? fm.removeItem(at: ran)
    }
    // its exit statuses mean what they always meant: only 75 is busy
    for (status, expected) in [(75, RecoverResult.busy), (1, .failed(nil)), (3, .failed(nil)), (0, .recovered)] {
        let dir = newDir()
        let legacy = script("b\(status)/meetingbox", "exit \(status)")
        check(ChildRecorder(executable: absent, legacyExecutable: legacy).recover(dir: dir) == expected,
              "I1: through the app's executable, exit \(status) is \(expected)")
    }
    // present but not executable is as good as missing
    do {
        let dir = newDir()
        let flat = script("flat/meetingbox-recorder", "exit 0", mode: 0o644)
        let legacy = script("c/meetingbox", "exit 0")
        check(ChildRecorder(executable: flat, legacyExecutable: legacy).recover(dir: dir) == .recovered && log(dir).first == missingNote,
              "I1: a helper that is not executable is treated as missing")
    }
    // neither runs: failed, with the reason, never busy
    do {
        let dir = newDir()
        let result = ChildRecorder(executable: absent, legacyExecutable: bin.appendingPathComponent("no-such/meetingbox")).recover(dir: dir)
        var said: String? = nil
        if case .failed(let line) = result { said = line }
        check(said?.hasPrefix("meetingbox: cannot recover: the recorder could not be started") == true, "I1: no executable to run is failed, never busy, and says why")
        let lines = log(dir)
        check(lines.count == 2 && lines[0] == missingNote && lines[1] == said,
              "I1: and capture.log says why (\(lines))")
    }
    do {
        let dir = newDir()
        let flatApp = script("d/meetingbox", "exit 0", mode: 0o644)
        var failed = false
        if case .failed(let line?) = ChildRecorder(executable: absent, legacyExecutable: flatApp).recover(dir: dir) {
            failed = line.hasPrefix("meetingbox: cannot recover: the recorder could not be started")
        }
        check(failed, "I1: an app executable that cannot run is failed too, and says why")
    }
    // the helper there and working: the app's executable is not used, and nothing is said
    do {
        let dir = newDir()
        let helper = script("e/meetingbox-recorder", "echo helper > \"\(ran.path)\"; exit 75")
        let legacy = script("e/meetingbox", "echo legacy > \"\(ran.path)\"; exit 0")
        let result = ChildRecorder(executable: helper, legacyExecutable: legacy).recover(dir: dir)
        check(result == .busy && ((try? String(contentsOf: ran, encoding: .utf8)) ?? "") == "helper\n" && log(dir).isEmpty,
              "I1: with the helper there, 75 is busy, the app's executable is not used, nothing is added to capture.log")
    }
    // a folder that cannot be logged in does not stop the recovery, nor turn it into busy
    do {
        let gone = bin.appendingPathComponent("never-made")
        let legacy = script("f/meetingbox", "exit 0")
        check(ChildRecorder(executable: absent, legacyExecutable: legacy).recover(dir: gone) == .recovered,
              "I1: a folder with no capture.log to write still recovers")
    }
}

// M4: the app's own executable, for recognising a recorder the previous build started, is the
// running one by default. If that drifted, an upgraded app would stop adopting such a recorder.
do {
    check(ChildRecorder().legacyExecutable == Bundle.main.executableURL, "M4: the legacy executable defaults to the running executable")
    check(ChildRecorder.helperExecutable(in: URL(fileURLWithPath: "/x/meetingbox.app")).lastPathComponent == ChildRecorder.helperName
          && ChildRecorder.helperName == "meetingbox-recorder", "M2: the helper's executable is named meetingbox-recorder")
}

// M2: the helper opened by hand (open -b, a click) has no mode, and must not run as the whole app.
do {
    let name = ChildRecorder.helperName
    check(LaunchMode.choose(arguments: ["--record", "-o", "/x", "-n", "meeting"], executableName: name) == .record, "M2: the helper records")
    check(LaunchMode.choose(arguments: ["--record", "-l"], executableName: name) == .record, "M2: the helper lists microphones as --record")
    check(LaunchMode.choose(arguments: ["--recover", "/x"], executableName: name) == .recover, "M2: the helper recovers")
    check(LaunchMode.choose(arguments: [], executableName: name) == .refuse, "M2: the helper opened with no arguments refuses")
    check(LaunchMode.choose(arguments: ["-psn_0_12345"], executableName: name) == .refuse, "M2: and with anything else")
    check(LaunchMode.choose(arguments: ["recover", "/x"], executableName: name) == .refuse, "M2: a mode needs its two dashes")
    check(LaunchMode.choose(arguments: [], executableName: "meetingbox") == .app, "M2: the app with no arguments is the app")
    check(LaunchMode.choose(arguments: ["-psn_0_12345"], executableName: "meetingbox") == .app, "M2: and with anything else")
    check(LaunchMode.choose(arguments: ["--record"], executableName: "meetingbox") == .record
          && LaunchMode.choose(arguments: ["--recover", "/x"], executableName: "meetingbox") == .recover, "M2: the app still records and recovers")
    check(LaunchMode.choose(arguments: [], executableName: "meetingbox-recorder-2") == .app, "M2: the helper is told by its exact name")
    check(LaunchMode.refusal == "this is meetingbox's recorder; open meetingbox.app instead" && LaunchMode.refusalExit == 64,
          "M2: the one line, and exit 64")
    check(!LaunchMode.currentExecutableName.isEmpty && LaunchMode.currentExecutableName == Bundle.main.executableURL?.lastPathComponent,
          "M2: the name it was started under is the running executable's")
}

// I2: the app's floors leave room to finish, as the recorder's do. A stop at 200 MB cannot finalise a
// recording of more than about 90 minutes; the stop and the warning take the finalise need on top.
do {
    check(Session.startFloor == 2_000_000_000, "I2: the start floor is unchanged, 2 GB")
    check(Session.stopFloor(recordedSeconds: 0) == 200_000_000 && Session.lowFloor(recordedSeconds: 0) == 1_000_000_000,
          "I2: with nothing recorded the floors are 200 MB and 1 GB")
    check(Session.stopFloor(recordedSeconds: 3600) == 362_000_000, "I2: the stop floor after an hour is 200 MB plus 162 MB")
    check(Session.lowFloor(recordedSeconds: 3600) == 1_162_000_000, "I2: the warning after an hour is 1 GB plus 162 MB")
    check(Session.stopFloor(recordedSeconds: 7 * 3600) == 200_000_000 + Finaliser.finishNeed(seconds: 7 * 3600)
          && Session.lowFloor(recordedSeconds: 7 * 3600) == 1_000_000_000 + Finaliser.finishNeed(seconds: 7 * 3600),
          "I2: both add the same finalise need as the recorder's floor")
    check(Session.stopFloor(recordedSeconds: -5) == 200_000_000, "I2: a clock that ran backwards does not lower the floor")
    check(Session.diskStopped == "recording stopped because the disk was nearly full, so that it could be finished"
          && !Session.diskStopped.contains("200") && !Session.diskStopped.contains("MB"),
          "G2F2: the stop's message says why in plain words, with no figure to go stale")
    check(Session.diskStoppedLegacy == "recording stopped because the disk was nearly full (under 200 MB free)",
          "G2F2: the old message is kept, to be recognised in meetings written with it")
    check(Session.diskStoppedFailed == "recording stopped because the disk was nearly full; the recording was interrupted; its files are kept"
          && Session.interrupted == "the recording was interrupted; its files are kept",
          "I2: the other messages are as they were")
}
do {
    // After an hour: the stop is at 362 MB, not 200 MB.
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.free = 363 * MB
    r.at(3600)
    check(s.phase == .recording(dir) && r.rec.sent(SIGINT) == 0, "I2: 363 MB free after an hour does not stop it")
    r.free = 361 * MB
    r.at(3601)
    check(s.phase == .finalising(dir) && r.rec.sent(SIGINT) == 1, "I2: 361 MB free after an hour stops it, with room left to finish")
    check(r.json(dir)["error"] as? String == Session.diskStopped, "I2: and the reason is recorded, in the current words")
}
do {
    // The warning is at 1 GB plus the finalise need.
    let r = Rig()
    let s = r.make()
    _ = try! s.start(root: r.store.root, mic: nil)
    r.free = 1_100 * MB
    r.at(3600)
    check(s.health.disk == .low, "I2: 1.1 GB free after an hour is low (the line is 1.162 GB)")
    r.free = 1_200 * MB
    r.at(3601)
    check(s.health.disk == .ok, "I2: 1.2 GB free after an hour is not")
}
do {
    // Only recorded time counts: a long pause adds nothing to what finalising will need.
    let r = Rig()
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.clock.t = 60
    s.pause()
    r.free = 205 * MB
    r.at(7200)
    check(s.phase == .paused(dir) && r.rec.sent(SIGINT) == 0, "I2: two hours paused after one minute: the floor is for one minute (205 MB is enough)")
    r.free = 202 * MB
    r.at(7201)
    check(s.phase == .finalising(dir), "I2: but 202 MB is not (200 MB plus 2.7 MB for a minute)")
}

// MARK: - Processing queue (Task 5)

/// Records each run; the test ends a run by calling `finish`.
final class FakeRunner: PipelineRunner {
    struct Call {
        /// The job as the queue built it at launch: its kind, folder and the engine's arguments.
        let job: PipelineJob
        var audio: URL { job.folder.appendingPathComponent("audio.m4a") }
        var arguments: [String] { job.arguments }
        let progress: URL
        let attempt: String
        let done: (Int32, String) -> Void
        /// meeting.json as it was when the run began.
        let stateAtRun: String?
        let attemptsAtRun: Int?
        let attemptAtRun: String?
        let errorAtRun: String?
        /// `.process-log` as it was when the run began.
        let logAtRun: String?
    }
    var calls: [Call] = []
    func run(_ job: PipelineJob, progress: URL, attempt: String, done: @escaping (Int32, String) -> Void) -> Int32 {
        let json = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: job.folder
            .appendingPathComponent("meeting.json")))) as? [String: Any]) ?? [:]
        let log = try? String(contentsOf: job.folder.appendingPathComponent(".process-log"), encoding: .utf8)
        calls.append(Call(job: job, progress: progress, attempt: attempt, done: done,
                          stateAtRun: json["state"] as? String, attemptsAtRun: (json["attempts"] as? NSNumber)?.intValue,
                          attemptAtRun: json["attempt"] as? String, errorAtRun: json["error"] as? String, logAtRun: log))
        return Int32(40000 + calls.count)
    }
    var folders: [String] { calls.map { $0.audio.deletingLastPathComponent().lastPathComponent } }
    /// A run to finish that was never started is a failed check, not a crash that hides the checks after it.
    private func has(_ i: Int) -> Bool {
        if calls.indices.contains(i) { return true }
        check(false, "FakeRunner: there is no run \(i) to finish")
        return false
    }
    /// Ends run `i`: on success it writes the transcript and minutes, as `meetingbox process` does.
    func finish(_ i: Int, _ status: Int32, _ line: String = "", writeOutputs: Bool = true) {
        guard has(i) else { return }
        let dir = calls[i].audio.deletingLastPathComponent()
        if status == 0 && writeOutputs {
            try! "[00:00:01] Me: hello\n".write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try! "the minutes\n".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        }
        calls[i].done(status, line)
    }
    /// Ends run `i` writing only notes.md on success, as `meetingbox notes` does.
    func finishNotes(_ i: Int, _ status: Int32, _ line: String = "") {
        guard has(i) else { return }
        if status == 0 {
            try! "new minutes\n".write(to: calls[i].job.folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        }
        calls[i].done(status, line)
    }
    /// Ends run `i` as a run does that only finishes an interrupted swap: each file in `stage` is moved over
    /// its target and, unless `touch` is false, marked as written now; then it exits with `status`.
    func finishSwap(_ i: Int, _ status: Int32, stage: String, touch: Bool = true) {
        guard has(i) else { return }
        moveInStaged(calls[i].job.folder, stage: stage, touch: touch)
        calls[i].done(status, "")
    }
}

/// Files staged by a run that was killed before its swap finished, written an hour ago.
func stageFiles(_ dir: URL, _ stage: String, _ files: [String: String]) {
    let s = dir.appendingPathComponent(stage, isDirectory: true)
    try! fm.createDirectory(at: s, withIntermediateDirectories: true)
    for (f, body) in files {
        let u = s.appendingPathComponent(f)
        try! body.write(to: u, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: u.path)
    }
}
/// Moves every staged file over its target, as finishing a swap does, touching each to now unless told not to.
func moveInStaged(_ dir: URL, stage: String, touch: Bool) {
    let s = dir.appendingPathComponent(stage, isDirectory: true)
    for name in names(s) {
        let target = dir.appendingPathComponent(name)
        _ = Darwin.rename(s.appendingPathComponent(name).path, target.path)
        if touch { try! fm.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path) }
    }
    try? fm.removeItem(at: s)
}
/// Records, from any thread, whether each call came on the main thread.
final class MainSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    func note(_ main: Bool) {
        lock.lock()
        calls.append(main)
        lock.unlock()
    }
    var seen: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
/// Every plain file in the folder made an hour old, so only what a run writes counts as fresh.
func age(_ dir: URL) {
    for name in names(dir) {
        var isDir: ObjCBool = false
        let path = dir.appendingPathComponent(name).path
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: path)
        }
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

/// A count kept by a closure the code under test calls.
final class Tally {
    var count = 0
}

final class QRig {
    let root = freshRoot()
    let store: MeetingStore
    let runner = FakeRunner()
    var queue: ProcessingQueue!
    var finished: [(String, Bool)] = []
    /// The kind of each job `finished` reports, in the same order (nil: a kind this version cannot read).
    var kinds: [JobKind?] = []
    /// The reason each job `finished` reports gives, in the same order (nil: the record's own error).
    var reasons: [String?] = []
    var changes = 0
    /// How many times the store's roots were read: once for each scan or search of them (none while the queue
    /// finds a meeting in the folder it was last found in).
    let rootReads = Tally()

    init() {
        let reads = rootReads
        store = MeetingStore(root: root.appendingPathComponent("Meetings"), otherRoots: { reads.count += 1; return [] })
        try! fm.createDirectory(at: store.root, withIntermediateDirectories: true)
    }
    @discardableResult
    func make(settings: @escaping () -> RunSettings = { .defaults }, ps: URL = URL(fileURLWithPath: "/bin/ps")) -> ProcessingQueue {
        queue = ProcessingQueue(store: store, runner: runner, ps: ps, tickQueue: nil, settings: settings)
        queue.onFinished = { [unowned self] dir, ok, kind, reason in
            self.finished.append((dir.lastPathComponent, ok))
            self.kinds.append(kind)
            self.reasons.append(reason)
        }
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
    let job = PipelineJob(kind: .process, folder: dir, arguments: ScriptRunner.arguments(
        kind: .process, folder: dir, transcriber: .parakeet, room: nil, call: nil, tidy: true, writer: nil))
    let pid = runner.run(job, progress: progress, attempt: "the-attempt") { s, l in got = (s, l); sem.signal() }
    check(pid > 0, "ScriptRunner returns the worker's PID")
    check(sem.wait(timeout: .now() + 10) == .success, "ScriptRunner calls done")
    check(got?.0 == 3 && got?.1 == "the transcript came out empty", "ScriptRunner gives the exit status and the last stderr line")
    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check(text.contains("arg process\narg \(audio.path)\narg --parakeet\narg --tidy\narg --writer\narg apple\n"),
          "ScriptRunner runs <script> with the job's arguments: process <audio> --parakeet --tidy --writer apple")
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
    let plainJob = PipelineJob(kind: .process, folder: dir, arguments: ["process", audio.path])
    _ = ScriptRunner(script: quietScript, home: home, environment: [:]).run(plainJob, progress: progress, attempt: "q") { s, l in
        quiet = (s, l); sem3.signal() }
    check(sem3.wait(timeout: .now() + 10) == .success && quiet?.0 == 2 && quiet?.1 == "",
          "I2: the last line comes only from this run's part of the log")
    let missing = ScriptRunner(script: dir.appendingPathComponent("no-such-script"), home: home, environment: [:])
    var gone: (Int32, String)?
    let sem2 = DispatchSemaphore(value: 0)
    _ = missing.run(plainJob, progress: progress, attempt: "x") { s, l in gone = (s, l); sem2.signal() }
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
    check(h.reply(for: .toggle(mic: nil, dir: nil)) == "error the last recording is still being saved, so nothing new was started. Try again in a moment"
          && stopped == [dir] && started == [dir] && r.rec.launches.count == 1 && r.rec.sent(SIGINT) == 1 && r.session.phase == .finalising(dir),
          "B1: toggle while finalising is refused, so the command exits non-zero, and it neither stops nor starts anything")
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
    check(h.reply(for: .start(mic: nil, dir: nil)) == "error the last recording is still being saved, so nothing new was started. Try again in a moment"
          && r.rec.launches.count == 1, "B1: no start while finalising, in those words, and nothing launched")
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

// MARK: - Menu bar item and floating button (Task 7)

let meetingA = URL(fileURLWithPath: "/Meetings/2026-10-29_1000", isDirectory: true)
let meetingB = URL(fileURLWithPath: "/Meetings/2026-10-29_1100", isDirectory: true)
let allOk = Session.Health(mic: .ok, system: .ok, disk: .ok)

/// `ready` is the notice that a meeting's minutes are ready; `notice` gives any other.
func present(_ phase: Session.Phase = .idle, seconds: Int = 0, health: Session.Health = allOk, processing: URL? = nil,
             stage: String? = nil, ready: URL? = nil, notice: Notice? = nil, failure: Failure? = nil, floating: FloatingMode = .whileRecording,
             preferences: Bool = false) -> StatusPresentation {
    let shown = notice ?? ready.map { Notice(kind: .minutesReady, folder: $0, line: StatusPresentation.minutesReady) }
    return StatusPresentation(StatusInput(phase: phase, seconds: seconds, health: health, processing: processing, stage: stage,
                                          notice: shown, failure: failure, floating: floating, preferencesAvailable: preferences))
}
/// The menu as text: "-" for a separator, a disabled line in brackets.
func lines(_ p: StatusPresentation) -> [String] {
    p.menu.map { $0.action == .separator ? "-" : ($0.enabled ? $0.title : "(\($0.title))") }
}
func action(_ title: String, in p: StatusPresentation) -> MenuAction? { p.menu.first { $0.title == title }?.action }

// Every phase: the status button and the menu, in the exact words.
do {
    let tail = ["-", "Open meetingbox", "(Preferences…)", "-", "Quit meetingbox"]
    let idle = present()
    check(idle.button == StatusButton(symbol: "record.circle", tint: .plain, title: "", help: "meetingbox"), "status: idle is record.circle, untinted, no title")
    check(lines(idle) == ["Start recording"] + tail, "menu: idle (\(lines(idle)))")
    check(action("Start recording", in: idle) == .start && action("Open meetingbox", in: idle) == .openMeetingbox
          && action("Quit meetingbox", in: idle) == .quit && action("Preferences…", in: idle) == .preferences, "menu: idle actions")
    check(present(preferences: true).menu.first { $0.title == "Preferences…" }?.enabled == true, "menu: Preferences… is enabled once its window exists")

    let rec = present(.recording(meetingA), seconds: 7)
    check(rec.button == StatusButton(symbol: "circle.fill", tint: .red, title: "00:07", help: "Recording"), "status: recording is a red dot and the timer")
    check(lines(rec) == ["(Microphone: capturing)", "(System audio: capturing)", "-", "Pause", "Stop", "Show recording folder"] + tail,
          "menu: recording (\(lines(rec)))")
    check(action("Pause", in: rec) == .pause && action("Stop", in: rec) == .stop && action("Show recording folder", in: rec) == .showFolder(meetingA),
          "menu: recording actions, the folder is the recording's")

    let paused = present(.paused(meetingA), seconds: 65)
    check(paused.button == StatusButton(symbol: "pause.circle", tint: .plain, title: "01:05", help: "Paused"), "status: paused is pause.circle and the frozen timer")
    check(lines(paused) == ["(Microphone: capturing)", "(System audio: capturing)", "-", "Resume", "Stop", "Show recording folder"] + tail,
          "menu: paused (\(lines(paused)))")
    check(action("Resume", in: paused) == .resume, "menu: paused offers Resume")

    let fin = present(.finalising(meetingA), seconds: 90)
    check(fin.button == StatusButton(symbol: "ellipsis.circle", tint: .plain, title: "Saving the recording", help: "Saving the recording"),
          "B7: status: finalising says Saving the recording in the bar, no timer")
    check(lines(fin) == ["(Saving the recording)", "-", "(Saving the last recording…)", "Show recording folder"] + tail,
          "B7, B1: menu: finalising names the stage, and a disabled Saving the last recording… stands where Start would be (\(lines(fin)))")
    check(fin.menu.first { $0.title == "Saving the last recording…" } == MenuEntry(title: "Saving the last recording…", enabled: false, action: .start),
          "B1: the saving line is the Start entry, disabled")

    let proc = present(processing: meetingA, stage: "transcribing")
    check(proc.button == StatusButton(symbol: "ellipsis.circle", tint: .plain, title: "Transcribing", help: "Transcribing"), "B7: status: processing names the stage in the bar and the tooltip")
    check(lines(proc) == ["(Transcribing)", "-", "Start recording"] + tail, "B7: menu: processing while idle names the stage (\(lines(proc)))")
    check(present(processing: meetingA, stage: "minutes").button.title == "Writing minutes" && lines(present(processing: meetingA, stage: "speakers")).first == "(Finding speakers)",
          "B7: each stage in the window's words")
    check(present(processing: meetingA).button.help == "Processing" && present(processing: meetingA).button.title == "Processing"
          && lines(present(processing: meetingA)).first == "(Processing)", "B7: processing with no stage yet reads Processing, as the window's badge does")
    check(LibraryBadge.finalising.text == "Saving" && LibraryBadge.processing(stage: "transcribing").text == "Transcribing",
          "B7: the window's badges agree: Saving, then the stage")

    let ready = present(ready: meetingB)
    check(ready.button == StatusButton(symbol: "checkmark.circle", tint: .plain, title: "Minutes ready", help: "Minutes ready"),
          "status: minutes ready says so in the bar, with its own symbol")
    check(present(processing: meetingA, ready: meetingB).button == present(processing: meetingA).button, "status: busy wins over ready")
    check(present(.finalising(meetingA), ready: meetingB).button == fin.button, "status: finalising wins over ready too")
    check(present(.recording(meetingA), seconds: 7, ready: meetingB).button == rec.button
          && present(.paused(meetingA), seconds: 65, ready: meetingB).button == paused.button, "status: a recording or a pause hides ready in the bar")
    check(present(ready: meetingB, failure: Failure("start", "x")).button.symbol == "exclamationmark.triangle", "status: a failure wins over ready")
    check(lines(ready) == ["Minutes ready", "-", "Start recording"] + tail && action("Minutes ready", in: ready) == .openMinutes(meetingB),
          "menu: Minutes ready is a link to that meeting (\(lines(ready)))")
    check(lines(present(.recording(meetingA), processing: meetingB, ready: meetingB))
          == ["(Microphone: capturing)", "(System audio: capturing)", "(Processing)", "Minutes ready", "-", "Pause", "Stop", "Show recording folder"] + tail,
          "menu: recording while the last meeting is processed and another is ready")

    let failed = present(failure: Failure("start", "No input device matching \"USB\""))
    check(failed.button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "", help: "Could not start: No input device matching \"USB\""),
          "status: a failed start shows the warning triangle")
    check(lines(failed) == ["(Could not start: No input device matching \"USB\")", "-", "Start recording"] + tail
          && failed.menu[0].action == .info && !failed.menu[0].enabled, "menu: a failed start is the first line, disabled (\(lines(failed)))")
    let failedBusy = present(.finalising(meetingA), failure: Failure("start", "x"))
    check(lines(failedBusy).prefix(2) == ["(Could not start: x)", "(Saving the recording)"], "menu: the failed start comes before everything else")
    // M1: a pause or resume the recorder could not be reached for, shown while the recording goes on.
    let noPause = present(.recording(meetingA), seconds: 7, failure: Failure("pause", ControlHandler.cannotReach.replacingOccurrences(of: "error ", with: "")))
    check(noPause.button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "00:07",
                                         help: "Could not pause: cannot reach the recorder right now, try again"),
          "status: a refused pause shows the warning, and the timer keeps running beside it")
    check(lines(noPause) == ["(Could not pause: cannot reach the recorder right now, try again)", "(Microphone: capturing)", "(System audio: capturing)",
                             "-", "Pause", "Stop", "Show recording folder"] + tail, "menu: a refused pause is the first line, and Pause is still offered (\(lines(noPause)))")
    let noResume = present(.paused(meetingA), seconds: 65, failure: Failure("resume", "cannot reach the recorder right now, try again"))
    check(noResume.button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "01:05",
                                          help: "Could not resume: cannot reach the recorder right now, try again")
          && lines(noResume).first == "(Could not resume: cannot reach the recorder right now, try again)", "status and menu: a refused resume likewise")

    check(present(.recording(meetingA), seconds: 3725).button.title == "1:02:05" && present(.paused(meetingA), seconds: 0).button.title == "00:00",
          "status: the timer is mm:ss, then h:mm:ss")
}

// Health: every combination, while recording and while paused; none shown otherwise.
do {
    var combos = 0
    var wrong: [String] = []
    var shownWhenNot: [String] = []
    for mic in [Session.StreamHealth.ok, .stalled, .error] {
        for system in [Session.StreamHealth.ok, .stalled, .error] {
            for disk in [Session.DiskHealth.ok, .low] {
                let h = Session.Health(mic: mic, system: system, disk: disk)
                let good = mic == .ok && system == .ok && disk == .ok
                var expected = [mic == .ok ? "(Microphone: capturing)" : "(Microphone: not receiving audio)",
                                system == .ok ? "(System audio: capturing)" : "(System audio: not receiving audio)"]
                if disk == .low { expected.append("(Disk space low)") }
                for (phase, symbol, clean, name) in [(Session.Phase.recording(meetingA), "circle.fill", StatusTint.red, "recording"), (.paused(meetingA), "pause.circle", .plain, "paused")] {
                    combos += 1
                    let p = present(phase, seconds: 3, health: h)
                    let tint = good ? clean : StatusTint.amber
                    if p.button.symbol != symbol || p.button.tint != tint || p.panel.dot != tint
                        || Array(lines(p).prefix(expected.count)) != expected || lines(p)[expected.count] != "-" {
                        wrong.append("\(name) mic=\(mic) system=\(system) disk=\(disk)")
                    }
                }
                for phase in [Session.Phase.idle, .finalising(meetingA)] {
                    let p = present(phase, health: h)
                    if lines(p).contains(where: { $0.contains("Microphone") || $0.contains("System audio") || $0.contains("Disk space") })
                        || p.button.tint == .amber || p.panel.dot == .amber { shownWhenNot.append("mic=\(mic) system=\(system) disk=\(disk)") }
                }
            }
        }
    }
    check(combos == 36 && wrong.isEmpty, "health: all 18 combinations, recording and paused, give the right lines, an amber dot when not ok, red (or plain when paused) when ok (wrong: \(wrong))")
    check(shownWhenNot.isEmpty, "health: nothing about health shows while idle or finalising (shown: \(shownWhenNot))")
    let both = present(.recording(meetingA), health: Session.Health(mic: .error, system: .stalled, disk: .low))
    check(lines(both).prefix(3) == ["(Microphone: not receiving audio)", "(System audio: not receiving audio)", "(Disk space low)"]
          && both.button.help == "Recording, but some audio is not arriving", "health: stalled and error both read not receiving audio")
}

// M2: a menu whose entries differ only in their titles is updated in place.
do {
    let before = present(.recording(meetingA), seconds: 1).menu
    let flap = present(.recording(meetingA), seconds: 2, health: Session.Health(mic: .stalled, system: .ok, disk: .ok)).menu
    check(before != flap && MenuEntry.sameShape(before, flap), "menu shape: a stream flapping changes a title, not the shape")
    check(MenuEntry.sameShape(before, before), "menu shape: the same menu is the same shape")
    check(!MenuEntry.sameShape(before, present(.recording(meetingA), health: Session.Health(mic: .ok, system: .ok, disk: .low)).menu),
          "menu shape: a new line (disk space low) is a new shape")
    check(!MenuEntry.sameShape(present(.recording(meetingA)).menu, present(.paused(meetingA)).menu), "menu shape: Pause against Resume is a new shape")
    check(!MenuEntry.sameShape(present(.recording(meetingA)).menu, present(.recording(meetingB)).menu), "menu shape: another folder is a new shape")
    check(!MenuEntry.sameShape(present().menu, present(preferences: true).menu), "menu shape: enabling an entry is a new shape")
}

// The floating panel: shown per mode and phase, and what it holds.
do {
    let phases: [Session.Phase] = [.idle, .recording(meetingA), .paused(meetingA), .finalising(meetingA)]
    var grid: [String] = []
    for mode in FloatingMode.allCases {
        grid.append(phases.map { present($0, floating: mode).panel.visible ? "1" : "0" }.joined())
    }
    check(grid == ["1111", "0110", "0000"], "panel: always, while recording and never against idle, recording, paused, finalising (\(grid))")

    let idle = present(floating: .always).panel
    check(idle == PanelPresentation(visible: true, dot: .plain, label: "Ready", controls: [.start], help: nil), "panel: ready with a Record button when idle")
    check(present(processing: meetingA, stage: "minutes", floating: .always).panel.label == "Writing minutes"
          && present(processing: meetingA, stage: "transcribing", floating: .always).panel.label == "Transcribing"
          && present(processing: meetingA, floating: .always).panel.label == "Processing"
          && present(processing: meetingA, floating: .always).panel.controls == [.start], "B7: panel: idle while a meeting is processed names the stage, and still offers Record")
    let failed = present(failure: Failure("start", "No microphone"), floating: .always).panel
    check(failed.label == "Could not start" && failed.dot == .amber && failed.controls == [.start] && failed.help == "Could not start: No microphone",
          "panel: a failed start is named, with the reason as its tooltip")
    let panelNoPause = present(.recording(meetingA), seconds: 12, failure: Failure("pause", "cannot reach the recorder right now, try again")).panel
    check(panelNoPause == PanelPresentation(visible: true, dot: .amber, label: "00:12", controls: [.pause, .stop, .showFolder(meetingA)],
                                            help: "Could not pause: cannot reach the recorder right now, try again"),
          "panel: a refused pause turns the dot amber, names it in the tooltip, and keeps the timer and the controls")

    let rec = present(.recording(meetingA), seconds: 12).panel
    check(rec == PanelPresentation(visible: true, dot: .red, label: "00:12", controls: [.pause, .stop, .showFolder(meetingA)], help: nil),
          "panel: recording has a red dot, the timer, Pause, Stop and the folder")
    let paused = present(.paused(meetingA), seconds: 12).panel
    check(paused == PanelPresentation(visible: true, dot: .plain, label: "00:12", controls: [.resume, .stop, .showFolder(meetingA)], help: nil),
          "panel: paused holds the timer and offers Resume")
    let fin = present(.finalising(meetingA), floating: .always).panel
    check(fin == PanelPresentation(visible: true, dot: .plain, label: "Saving the recording", controls: [.showFolder(meetingA)], help: nil),
          "B7: panel: finalising reads Saving the recording and keeps the folder")
    check(MenuAction.start.title == "Start recording" && MenuAction.pause.title == "Pause" && MenuAction.resume.title == "Resume"
          && MenuAction.stop.title == "Stop" && MenuAction.showFolder(meetingA).title == "Show recording folder",
          "panel: its buttons carry the menu's words")
}

// Where the floating button is kept and put.
do {
    let d = testDefaults()
    let p = Preferences(defaults: d, home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
    check(p.floatingOrigin == nil, "floatingOrigin: nothing saved by default")
    p.floatingOrigin = CGPoint(x: 312.5, y: -40.25)
    let q = Preferences(defaults: d, home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
    check(q.floatingOrigin == CGPoint(x: 312.5, y: -40.25), "floatingOrigin: two Doubles round-trip, a negative one too")
    d.set(5.0, forKey: "floatingX")
    d.removeObject(forKey: "floatingY")
    check(Preferences(defaults: d).floatingOrigin == nil, "floatingOrigin: half a position is no position")
    d.set(Double.nan, forKey: "floatingX"); d.set(1.0, forKey: "floatingY")
    check(Preferences(defaults: d).floatingOrigin == nil, "floatingOrigin: a value that is not a number is no position")
    q.floatingOrigin = CGPoint(x: 1, y: 2)
    q.floatingOrigin = nil
    check(Preferences(defaults: d).floatingOrigin == nil, "floatingOrigin: cleared")

    let main = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let size = FloatingPlacement.size
    check(size == CGSize(width: 220, height: 44), "placement: about 220 x 44")
    let corner = CGPoint(x: 1440 - 220 - 16, y: 900 - 44 - 16)
    check(FloatingPlacement.origin(saved: nil, size: size, screens: [main], main: main) == corner, "placement: the first time, the top right of the main screen's visible frame")
    check(FloatingPlacement.origin(saved: CGPoint(x: 100, y: 100), size: size, screens: [main], main: main) == CGPoint(x: 100, y: 100), "placement: a saved position on a screen is kept")
    check(FloatingPlacement.origin(saved: CGPoint(x: 5000, y: 5000), size: size, screens: [main], main: main) == corner, "placement: a saved position off every screen goes back to the top right")
    check(FloatingPlacement.origin(saved: CGPoint(x: 1400, y: 500), size: size, screens: [main], main: main) == corner, "placement: a position with only a sliver on screen goes back too")
    check(FloatingPlacement.origin(saved: CGPoint(x: 1300, y: 500), size: size, screens: [main], main: main) == CGPoint(x: 1300, y: 500), "placement: partly off an edge but easy to grab is kept")
    check(FloatingPlacement.origin(saved: CGPoint(x: 2000, y: 400), size: size, screens: [main, side], main: main) == CGPoint(x: 2000, y: 400), "placement: a position on a second screen is kept")
    check(FloatingPlacement.origin(saved: CGPoint(x: 2000, y: 400), size: size, screens: [main], main: main) == corner, "placement: and goes back when that screen is unplugged")
}

// M3: the rules for the state the views show (the clock, the failure, the ready meeting) apart from AppKit.
do {
    let stalled = Session.Health(mic: .stalled, system: .ok, disk: .ok)
    var st = StatusInput()
    check(!st.clockRuns, "reducer: no clock when idle")
    st.apply(.tick(seconds: 5, health: stalled))
    check(st.seconds == 0 && st.health == allOk, "reducer: a tick when nothing is recording changes nothing")
    st.apply(.phase(.recording(meetingA)))
    check(st.clockRuns && st.phase == .recording(meetingA), "reducer: the clock runs while recording")
    st.apply(.tick(seconds: 5, health: stalled))
    check(st.seconds == 5 && st.health == stalled, "reducer: a tick sets the seconds and the health")
    st.apply(.phase(.paused(meetingA)))
    check(st.clockRuns && st.seconds == 5, "reducer: the clock runs while paused, and the seconds stay")
    st.apply(.phase(.recording(meetingA)))
    check(st.clockRuns && st.seconds == 5, "reducer: resuming keeps them")
    st.apply(.phase(.finalising(meetingA)))
    check(!st.clockRuns && st.seconds == 0, "reducer: the clock stops when finalising, and the seconds go")
    st.apply(.tick(seconds: 9, health: stalled))
    check(st.seconds == 0, "reducer: a late tick after the stop is ignored")
    st.apply(.phase(.idle))
    check(!st.clockRuns && st.phase == .idle, "reducer: and it is off when idle")
    var on = 0
    for _ in 0..<5 {
        st.apply(.phase(.recording(meetingA)))
        if st.clockRuns { on += 1 }
        st.apply(.phase(.finalising(meetingA)))
        st.apply(.phase(.idle))
        if st.clockRuns { on += 100 }
    }
    check(on == 5, "reducer: repeated starts turn the clock on once each and off again")

    var m = StatusInput()
    m.apply(.processing(meetingA, stage: "transcribing"))
    check(m.processing == meetingA && m.stage == "transcribing", "reducer: the job being processed and its stage")
    m.apply(.processing(nil, stage: nil))
    check(m.processing == nil && m.stage == nil, "reducer: and nothing once it is done")
    m.apply(.minutesReady(meetingB))
    check(m.ready == meetingB, "reducer: a finished job sets ready")
    m.apply(.minutesOpened(meetingA))
    check(m.ready == meetingB, "reducer: opening another meeting leaves it")
    m.apply(.minutesOpened(meetingB))
    check(m.ready == nil, "reducer: opening that meeting clears it")
    m.apply(.minutesReady(meetingB))
    m.apply(.phase(.paused(meetingA)))
    check(m.ready == meetingB, "reducer: a recording taken up as paused is not a new recording")
    m.apply(.phase(.idle))
    m.apply(.phase(.recording(meetingA)))
    check(m.ready == nil, "reducer: the next recording starting clears ready")
    m.apply(.minutesReady(meetingB))
    m.apply(.phase(.paused(meetingA)))
    m.apply(.phase(.recording(meetingA)))
    check(m.ready == meetingB, "reducer: resuming does not (ready arrived during the recording)")

    var f = StatusInput()
    f.apply(.failed(Failure("start", "no microphone")))
    check(f.failure == Failure("start", "no microphone") && f.failure?.line == "Could not start: no microphone", "reducer: a failure is kept, worded Could not <action>: <reason>")
    f.apply(.acted)
    check(f.failure == nil, "reducer: the next action clears it")
    f.apply(.failed(Failure("start", "no microphone")))
    f.apply(.phase(.finalising(meetingA)))
    check(f.failure != nil, "reducer: a recording ending does not clear it (the start's error arrives after the recorder has died)")
    f.apply(.phase(.idle))
    f.apply(.phase(.recording(meetingA)))
    check(f.failure == nil, "reducer: a recording starting clears it (a start from the command line)")
    f.apply(.failed(Failure("pause", "x")))
    f.apply(.phase(.paused(meetingA)))
    f.apply(.phase(.recording(meetingA)))
    check(f.failure != nil, "reducer: a pause that failed stays until the next action, whatever the phase does")

    let unreachable = "error " + "cannot reach the recorder right now, try again"
    check(ControlHandler.cannotReach == unreachable, "reducer: the reply it keys on is the handler's own")
    check(Failure.from(.start(mic: nil, dir: nil), reply: "error No input device") == Failure("start", "No input device"), "failure: a failed start is shown")
    check(Failure.from(.pause, reply: unreachable) == Failure("pause", "cannot reach the recorder right now, try again"), "failure: a pause that could not reach the recorder is shown")
    check(Failure.from(.resume, reply: unreachable) == Failure("resume", "cannot reach the recorder right now, try again"), "failure: and a resume")
    check(Failure.from(.pause, reply: "error not recording") == nil && Failure.from(.resume, reply: "error the recording in /x has already stopped") == nil,
          "failure: the races (not recording, already stopped) are only logged")
    check(Failure.from(.stop, reply: "error not recording") == nil && Failure.from(.stop, reply: unreachable) == nil, "failure: a stop is never shown")
    check(Failure.from(.start(mic: nil, dir: nil), reply: "ok recording /x") == nil && Failure.from(.pause, reply: "ok paused /x") == nil, "failure: an ok reply is not one")
    // B6: a start that lost the race to the recording now running is only logged.
    let lost = "error already recording in \(meetingA.path)"
    check(Failure.from(.start(mic: nil, dir: nil), reply: lost, phase: .recording(meetingA)) == nil
          && Failure.from(.start(mic: nil, dir: nil), reply: lost, phase: .paused(meetingA)) == nil,
          "B6: a start error naming the folder being recorded or paused into is not shown")
    check(Failure.from(.start(mic: nil, dir: nil), reply: lost, phase: .idle) == Failure("start", "already recording in \(meetingA.path)")
          && Failure.from(.start(mic: nil, dir: nil), reply: lost, phase: .recording(meetingB)) == Failure("start", "already recording in \(meetingA.path)")
          && Failure.from(.start(mic: nil, dir: nil), reply: "error No input device", phase: .recording(meetingA)) == Failure("start", "No input device"),
          "B6: one naming another folder, or none, still is")
    check(Failure.from(.start(mic: nil, dir: nil), reply: "error " + Session.stillSaving, phase: .finalising(meetingA)) == Failure("start", Session.stillSaving),
          "B1: a start refused while the last recording is saved is shown")
}

// Residual: what the app does with an answer, the same for the menus and the socket, and when the
// failure sound goes with it: only for a failed start over the socket (the hotkey or the command).
do {
    let start = ControlRequest.start(mic: nil, dir: nil)
    let unreachable = String(ControlHandler.cannotReach.dropFirst("error ".count))
    check(Failure.shown(start, reply: "error No input device", phase: .idle, overSocket: true)
          == ShownFailure(failure: Failure("start", "No input device"), sound: true),
          "shown: a failed start over the socket is shown, with one failure sound")
    check(Failure.shown(start, reply: "error No input device", phase: .idle, overSocket: false)
          == ShownFailure(failure: Failure("start", "No input device"), sound: false),
          "shown: a failed start from the menus is shown, silently, as before")
    check(Failure.shown(start, reply: "error " + Session.stillSaving, phase: .finalising(meetingA), overSocket: true)
          == ShownFailure(failure: Failure("start", Session.stillSaving), sound: false),
          "shown: the refusal while saving over the socket is shown, with no second sound (onRefused plays it)")
    let lost = "error already recording in \(meetingA.path)"
    check(Failure.shown(start, reply: lost, phase: .recording(meetingA), overSocket: true) == nil
          && Failure.shown(start, reply: lost, phase: .paused(meetingA), overSocket: true) == nil,
          "shown: a start over the socket naming the folder now recording gives nothing (B6)")
    check(Failure.shown(start, reply: "ok recording \(meetingA.path)", phase: .recording(meetingA), overSocket: true) == nil
          && Failure.shown(.stop, reply: "ok finalising \(meetingA.path)", phase: .finalising(meetingA), overSocket: true) == nil
          && Failure.shown(.status, reply: "ok idle -", phase: .idle, overSocket: true) == nil,
          "shown: an ok reply gives nothing")
    check(Failure.shown(.pause, reply: ControlHandler.cannotReach, phase: .recording(meetingA), overSocket: true)
          == ShownFailure(failure: Failure("pause", unreachable), sound: false)
          && Failure.shown(.resume, reply: ControlHandler.cannotReach, phase: .paused(meetingA), overSocket: true)
          == ShownFailure(failure: Failure("resume", unreachable), sound: false),
          "shown: a pause or resume over the socket that could not reach the recorder is shown as from the menu, with no sound")
    check(Failure.shown(.stop, reply: "error not recording", phase: .idle, overSocket: true) == nil
          && Failure.shown(.pause, reply: "error not recording", phase: .idle, overSocket: true) == nil,
          "shown: a stop, and the races, over the socket give nothing")
}

// Residual round 1: the refusal while saving goes once the save is over; any other failure stays,
// and the notice is never touched.
do {
    let refusal = Failure("start", Session.stillSaving)
    let note = Notice(kind: .minutesReady, folder: meetingB, line: StatusPresentation.minutesReady)
    var s = StatusInput()
    s.apply(.phase(.recording(meetingA)))
    s.apply(.phase(.finalising(meetingA)))
    s.apply(.minutesReady(meetingB))
    s.apply(.failed(refusal))
    s.apply(.phase(.finalising(meetingA)))
    check(s.failure == refusal && s.notice == note, "reducer: the refusal while saving stays through a repeated finalising phase, with the notice")
    s.apply(.phase(.idle))
    check(s.failure == nil && s.notice == note, "reducer: the refusal while saving goes once the save is over, and the notice stays")
    var t = StatusInput()
    t.apply(.phase(.recording(meetingA)))
    t.apply(.phase(.finalising(meetingA)))
    t.apply(.minutesReady(meetingB))
    let full = Failure("start", "not enough free disk space to record (2 GB needed)")
    t.apply(.failed(full))
    t.apply(.phase(.idle))
    check(t.failure == full && t.notice == note, "reducer: any other start failure stays once the save is over, and so does the notice")

    // The other order: a refusal that arrives after the save has already ended is not shown.
    var late = StatusInput()
    late.apply(.phase(.recording(meetingA)))
    late.apply(.phase(.finalising(meetingA)))
    late.apply(.minutesReady(meetingB))
    late.apply(.phase(.idle))
    late.apply(.failed(Failure.stillSaving))
    check(late.failure == nil && late.notice == note, "reducer: a refusal while saving that arrives once the save is over is not shown, and the notice stays")
    for (label, next) in [("recording", Session.Phase.recording(meetingB)), ("paused", .paused(meetingB))] {
        var s = StatusInput()
        s.apply(.phase(.recording(meetingA)))
        s.apply(.phase(.finalising(meetingA)))
        s.apply(.phase(.idle))
        s.apply(.phase(next))
        s.apply(.failed(Failure.stillSaving))
        check(s.failure == nil, "reducer: a refusal while saving that arrives once the session is \(label) again is not shown")
    }
    var during = StatusInput()
    during.apply(.phase(.recording(meetingA)))
    during.apply(.phase(.finalising(meetingA)))
    during.apply(.failed(Failure.stillSaving))
    check(during.failure == Failure.stillSaving, "reducer: a refusal while saving that arrives while saving is shown")
    var idle = StatusInput()
    idle.apply(.phase(.idle))
    idle.apply(.failed(full))
    check(idle.failure == full, "reducer: while idle, any other failure is still shown")
}

// One path for every action: perform answers like the socket, without ever waiting on the queue.
do {
    let q = DispatchQueue(label: "meetingbox.test.perform")
    let onQ = DispatchSpecificKey<Bool>()
    q.setSpecific(key: onQ, value: true)
    let (r, h, _) = handlerRig(tickQueue: q)
    var started = 0, stopped = 0, told = 0
    h.onStarted = { _ in started += 1 }
    h.onStopped = { _ in stopped += 1 }
    h.onAnswered = { _, _ in told += 1 }

    var now: String?
    q.sync { h.perform(.status) { now = $0 } }
    check(q.sync { now } == "ok idle -", "perform: a reply is delivered at once")
    q.sync { now = nil; h.perform(.pause) { now = $0 } }
    check(q.sync { now } == "error not recording", "perform: an error reply too")

    // A start whose recorder stays up.
    let done = DispatchSemaphore(value: 0)
    var answer: String?, answeredOnQueue = false, early = true, soundsAtAnswer = -1, answers = 0
    q.sync {
        h.perform(.start(mic: nil, dir: nil)) {
            answer = $0
            answers += 1
            answeredOnQueue = DispatchQueue.getSpecific(key: onQ) == true
            soundsAtAnswer = started
            done.signal()
        }
        early = answer == nil
    }
    check(q.sync { early } && q.sync { started } == 0, "perform: a start returns before it is settled, and plays nothing yet")
    // While it waits the queue is free: another request is answered straight away.
    var during: String?
    q.sync { h.perform(.status) { during = $0 } }
    let dir = q.sync { r.session.phase.folder }
    check(dir != nil && q.sync { during } == "ok recording \(dir!.path)", "perform: the queue is free while a start settles")
    check(done.wait(timeout: .now() + 15) == .success, "perform: a start that stays up is answered")
    let (okAnswer, onQueue, sounds) = q.sync { (answer, answeredOnQueue, soundsAtAnswer) }
    check(dir != nil && okAnswer == "ok recording \(dir!.path)", "perform: ok recording <dir> once the recorder has stayed up (\(okAnswer ?? "nil"))")
    check(onQueue, "perform: the completion arrives on the handler's queue")
    check(sounds == 1 && q.sync { started } == 1, "perform: the start sound is announced once, with the answer")
    usleep(900_000) // a few polls on: nothing more is announced and nothing is answered twice
    check(q.sync { started } == 1 && q.sync { answers } == 1, "perform: and not again by a later poll (M4)")
    // Every other action takes the same path.
    var paused: String?
    q.sync { h.perform(.pause) { paused = $0 } }
    check(q.sync { paused } == "ok paused \(dir!.path)", "perform: pause")
    var stop: String?
    q.sync { h.perform(.stop) { stop = $0 } }
    check(q.sync { stop } == "ok finalising \(dir!.path)" && q.sync { stopped } == 1, "perform: stop, and the stop sound is announced")
    var toggled: String?
    q.sync { h.perform(.toggle(mic: nil, dir: nil)) { toggled = $0 } }
    check(q.sync { toggled } == "error " + Session.stillSaving && q.sync { told } == 0,
          "perform: never tells onAnswered (the menus hear through the completion, and nothing is told twice)")
    q.sync {}
}
do {
    let q = DispatchQueue(label: "meetingbox.test.perform.dies")
    let (r, h, _) = handlerRig(tickQueue: q)
    var started = 0, told = 0
    h.onStarted = { _ in started += 1 }
    h.onAnswered = { _, _ in told += 1 }
    q.sync {
        r.rec.recoverResult = false
        r.rec.dieOnLaunch = (1, "No input device matching \"USB\"")
    }
    let done = DispatchSemaphore(value: 0)
    var answer: String?, early = true
    q.sync {
        h.perform(.start(mic: nil, dir: nil)) { answer = $0; done.signal() }
        early = answer == nil
    }
    check(q.sync { early }, "perform: a start that will fail is not answered before it returns")
    check(done.wait(timeout: .now() + 20) == .success, "perform: a recorder that dies at once is answered")
    let (reply, sounds, phase) = q.sync { (answer, started, r.session.phase) }
    check(reply == "error No input device matching \"USB\"" && sounds == 0 && phase == .idle,
          "perform: error <its reason>, no start sound, and idle (\(reply ?? "nil"))")
    check(q.sync { told } == 0, "perform: a start that fails after the wait never tells onAnswered either")
    q.sync {}
}

// I2: a start the user ends, or pauses, inside the grace is not a failed start, and plays no start sound.
/// Ends a recording the fake recorder keeps alive, as a real stop would: stop, the recorder exits, the
/// session settles to idle. Its timer then stops, so no tick is left to run after the rig is gone (the
/// session's callbacks hold the rig unowned, and a block that ends at the grace races the 2 s tick).
func settleToIdle(_ r: Rig, _ q: DispatchQueue) {
    q.sync {
        _ = r.session.stop()
        r.rec.exit(r.rec.nextPid, 0, verifies: true)
        r.session.tick()
    }
}

do {
    let q = DispatchQueue(label: "meetingbox.test.perform.stop")
    let (r, h, _) = handlerRig(tickQueue: q)
    var started = 0, stopped = 0
    h.onStarted = { _ in started += 1 }
    h.onStopped = { _ in stopped += 1 }
    let done = DispatchSemaphore(value: 0)
    var answer: String?
    q.sync { h.perform(.start(mic: nil, dir: nil)) { answer = $0; done.signal() } }
    let dir = q.sync { r.session.phase.folder }
    var stopReply: String?
    q.sync { h.perform(.stop) { stopReply = $0 } }
    check(dir != nil && q.sync { stopReply } == "ok finalising \(dir!.path)", "I2: a stop inside the grace is accepted")
    check(done.wait(timeout: .now() + 1.5) == .success, "I2: the start is answered at the next poll, not left waiting out the grace")
    let (reply, sounds, stops) = q.sync { (answer, started, stopped) }
    check(reply == "ok finalising \(dir!.path)" && sounds == 0 && stops == 1,
          "I2: the start's answer is the status, not an error, with no start sound and the one stop sound (\(reply ?? "nil"))")
    // The stop was of that folder only: a later start that fails is still an error.
    let pid = q.sync { r.rec.nextPid }
    q.sync { r.rec.exit(pid, 0, verifies: true); r.session.tick() }
    check(q.sync { r.session.phase } == .idle, "I2: the stopped recording settles to idle")
    q.sync { r.rec.recoverResult = false; r.rec.dieOnLaunch = (1, "No input device matching \"USB\"") }
    let again = DispatchSemaphore(value: 0)
    var second: String?
    q.sync { h.perform(.start(mic: nil, dir: nil)) { second = $0; again.signal() } }
    check(again.wait(timeout: .now() + 20) == .success && q.sync { second } == "error No input device matching \"USB\"",
          "I2: a later start that fails is still reported as an error (\(q.sync { second } ?? "nil"))")
    q.sync {}
}
do {
    let q = DispatchQueue(label: "meetingbox.test.perform.pause")
    let (r, h, _) = handlerRig(tickQueue: q)
    var started = 0
    h.onStarted = { _ in started += 1 }
    let done = DispatchSemaphore(value: 0)
    var answer: String?
    q.sync { h.perform(.start(mic: nil, dir: nil)) { answer = $0; done.signal() } }
    let dir = q.sync { r.session.phase.folder }
    q.sync { h.perform(.pause) { _ in } }
    check(q.sync { r.session.phase } == .paused(dir!), "I2: paused inside the grace")
    check(done.wait(timeout: .now() + 15) == .success, "I2: a start paused inside the grace is answered")
    let (reply, sounds) = q.sync { (answer, started) }
    check(reply == "ok paused \(dir!.path)" && sounds == 0, "I2: with the status and no start sound (\(reply ?? "nil"))")
    settleToIdle(r, q)
}
do {
    let q = DispatchQueue(label: "meetingbox.test.perform.resume")
    let (r, h, _) = handlerRig(tickQueue: q)
    var started = 0
    h.onStarted = { _ in started += 1 }
    let done = DispatchSemaphore(value: 0)
    var answer: String?
    q.sync { h.perform(.start(mic: nil, dir: nil)) { answer = $0; done.signal() } }
    let dir = q.sync { r.session.phase.folder }
    q.sync { h.perform(.pause) { _ in } }
    q.sync { h.perform(.resume) { _ in } }
    check(done.wait(timeout: .now() + 15) == .success, "I2: a start paused and resumed inside the grace is answered")
    let (reply, sounds) = q.sync { (answer, started) }
    check(reply == "ok recording \(dir!.path)" && sounds == 1, "I2: it is a recording, and the start sound plays once (\(reply ?? "nil"))")
    settleToIdle(r, q)
}

// MARK: - The window: library, minutes, transcript, rename (Task 8)

// ProcessingQueue.process: an unprocessed (or failed) meeting with audio is written queued, then queued;
// nothing else is changed.
do {
    let r = QRig()
    let q = r.make()
    let busy = r.meeting("2026-10-30_0800", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let a = r.meeting("2026-10-30_0900", files: ["audio.m4a": "a"]) { $0.state = .unprocessed }
    q.process(a)
    check(r.state(a) == "queued" && r.attempts(a) == nil && r.runner.calls.count == 1,
          "P1: process writes queued through the store before anything runs, and waits its turn behind a running job")
    q.process(a); q.process(busy)
    check(r.runner.calls.count == 1 && q.current?.lastPathComponent == busy.lastPathComponent,
          "P1: a meeting already queued or running is not added twice")
    r.runner.finish(0, 0)
    check(r.runner.folders == [busy, a].map { $0.lastPathComponent } && r.runner.calls[1].stateAtRun == "processing"
          && r.runner.calls[1].attemptsAtRun == 1 && r.runner.calls[1].audio.lastPathComponent == "audio.m4a",
          "P1: it then runs as any queued job: processing, attempt 1, its audio.m4a")
    r.runner.finish(1, 0)
    check(r.state(a) == "done" && r.finished.last.map { $0.0 == a.lastPathComponent && $0.1 } ?? false, "P1: and ends done")
}
do {
    // v1.2 folders have no meeting.json at all: a scan says unprocessed
    let r = QRig()
    let q = r.make()
    let a = r.meeting("2026-10-30_1000", files: ["audio.m4a": "a"])
    check(!fm.fileExists(atPath: a.appendingPathComponent("meeting.json").path), "P2: the folder has no meeting.json to begin with")
    q.process(a)
    check(r.runner.calls.count == 1 && r.runner.calls[0].stateAtRun == "processing" && r.attempts(a) == 1,
          "P2: a folder with no meeting.json and no notes is unprocessed, so it is processed")
    r.runner.finish(0, 0)
    check(r.state(a) == "done", "P2: and ends done")
}
do {
    let r = QRig()
    let q = r.make()
    let failed = r.meeting("2026-10-30_1100", files: ["audio.m4a": "a"]) { $0.state = .failed; $0.error = "it broke"; $0.attempts = 3; $0.attempt = "old" }
    q.process(failed)
    check(r.runner.calls.count == 1 && r.runner.calls[0].errorAtRun == nil && r.runner.calls[0].attemptsAtRun == 1
          && r.runner.calls[0].attemptAtRun != "old", "P3: a failed meeting with audio is run again from a clean record, as retry does")
}
do {
    // without the audio the queue would run, nothing happens: the state, and the absence of a record, stay
    let r = QRig()
    let q = r.make()
    let noAudio = r.meeting("2026-10-30_1200") { $0.state = .unprocessed }
    let noRecord = r.meeting("2026-10-30_1210")
    let v12 = r.meeting("2026-10-30_1220", files: ["2026-10-30_1220_meeting.m4a": "a"])
    let failedNoAudio = r.meeting("2026-10-30_1230") { $0.state = .failed; $0.error = "it broke"; $0.attempts = 3 }
    for dir in [noAudio, noRecord, v12, failedNoAudio] { q.process(dir) }
    check(r.runner.calls.isEmpty && q.current == nil, "P4: without audio.m4a nothing is queued or run")
    check(r.state(noAudio) == "unprocessed" && r.state(failedNoAudio) == "failed" && r.error(failedNoAudio) == "it broke"
          && r.attempts(failedNoAudio) == 3, "P4: and the records are as they were")
    check(!fm.fileExists(atPath: noRecord.appendingPathComponent("meeting.json").path)
          && !fm.fileExists(atPath: v12.appendingPathComponent("meeting.json").path), "P4: no record is made for a folder that is refused")
}
do {
    // any other state is left alone, with audio there
    let r = QRig()
    let q = r.make()
    var dirs: [(String, URL)] = []
    for (i, s) in [MeetingState.done, .recording, .finalising, .queued, .processing].enumerated() {
        dirs.append((s.rawValue, r.meeting("2026-10-30_13\(i)0", files: ["audio.m4a": "a"]) { $0.state = s }))
    }
    let inferredDone = r.meeting("2026-10-30_1390", files: ["audio.m4a": "a", "notes.md": "minutes"])
    for (_, dir) in dirs { q.process(dir) }
    q.process(inferredDone)
    check(r.runner.calls.isEmpty && q.current == nil && dirs.allSatisfy { r.state($0.1) == $0.0 },
          "P5: done, recording, finalising, queued and processing meetings are not touched or run")
    check(!fm.fileExists(atPath: inferredDone.appendingPathComponent("meeting.json").path),
          "P5: nor is a folder a scan would call done (notes.md and no meeting.json) given a record")
}

// An unfinished recording (no .recording-complete, a working .caf still there) is never processed or retried:
// the engine's own definition (recording_unfinished in the meetingbox script), in one place.
do {
    let root = freshRoot()
    func folder(_ files: [String]) -> URL {
        counter += 1
        return make(root, "folder\(counter)", files: Dictionary(uniqueKeysWithValues: files.map { ($0, "x") }))
    }
    check(MeetingFolder.recordingUnfinished(folder(["audio.m4a", "mic.caf"])), "U1: a working file and no marker: unfinished")
    check(MeetingFolder.recordingUnfinished(folder(["audio.m4a", "call.caf"])), "U1: either working file")
    check(!MeetingFolder.recordingUnfinished(folder(["audio.m4a", "mic.caf", "call.caf", Finaliser.marker])), "U1: the marker makes it finished, whatever is left over")
    check(!MeetingFolder.recordingUnfinished(folder(["audio.m4a", Finaliser.marker])), "U1: marker and no working files: finished")
    check(!MeetingFolder.recordingUnfinished(folder(["audio.m4a"])), "U1: a recording from before this version has neither: finished")
    check(!MeetingFolder.recordingUnfinished(folder([])), "U1: an empty folder is not an unfinished recording")
    check(Finaliser.marker == ".recording-complete" && Finaliser.working == ["mic.caf", "call.caf"], "U1: the names are the recorder's own")
}
do {
    let r = QRig()
    let q = r.make()
    // a finalise that failed part way: audio.m4a published, no marker, the working files kept; the record says why
    let broken = r.meeting("2026-10-30_1400", files: ["audio.m4a": "a", "mic.caf": "c", "call.caf": "c"]) {
        $0.state = .failed; $0.error = "no room to finish the recording"; $0.attempts = 3
    }
    let brokenJSON = try? Data(contentsOf: broken.appendingPathComponent("meeting.json"))
    let neverRecorded = r.meeting("2026-10-30_1410", files: ["audio.m4a": "a", "call.caf": "c"])
    q.process(broken); q.retry(broken); q.process(neverRecorded)
    check(r.runner.calls.isEmpty && q.current == nil, "U2: process and retry queue nothing for an unfinished recording")
    check((try? Data(contentsOf: broken.appendingPathComponent("meeting.json"))) == brokenJSON && r.error(broken) == "no room to finish the recording"
          && r.attempts(broken) == 3, "U2: its record is exactly as it was, its own failure reason kept")
    check(!fm.fileExists(atPath: neverRecorded.appendingPathComponent("meeting.json").path), "U2: no record is made for one that has none")

    // finished: a Stage 2 folder with its marker (leftover working files do not matter), and one from before Stage 2
    let busy = r.meeting("2026-10-30_1300", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let finished = r.meeting("2026-10-30_1420", files: ["audio.m4a": "a", Finaliser.marker: "", "mic.caf": "c"]) { $0.state = .failed; $0.error = "it broke" }
    let older = r.meeting("2026-10-30_1430", files: ["audio.m4a": "a"]) { $0.state = .unprocessed }
    let olderFailed = r.meeting("2026-10-30_1440", files: ["audio.m4a": "a"]) { $0.state = .failed; $0.error = "it broke" }
    q.retry(finished); q.process(older); q.process(olderFailed)
    check(r.state(finished) == "queued" && r.state(older) == "queued" && r.state(olderFailed) == "queued" && r.error(finished) == nil,
          "U3: a finished recording, and one from before Stage 2, are queued")
}

// The library's decisions: rows, search, actions, busy, rename. Foundation only.
let libRoot = URL(fileURLWithPath: "/Meetings", isDirectory: true)
/// A meeting as a scan reports it, without a disk: its record (unless `record` is false) carries `state`.
func libMeeting(_ name: String, _ state: MeetingState = .done, title: String? = nil, seconds: Int = 0, stage: String? = nil,
                error: String? = nil, record: Bool = true) -> Meeting {
    let folder = MeetingFolder.parse(libRoot.appendingPathComponent(name, isDirectory: true))!
    var rec = MeetingRecord(title: title, started: folder.date, seconds: seconds, state: state)
    rec.stage = stage
    rec.error = error
    return Meeting(folder: folder, record: record ? rec : nil, state: state)
}
func libURL(_ name: String) -> URL { libRoot.appendingPathComponent(name, isDirectory: true) }
/// The same folder, however each side spells its path (a scan gives `/private/var/...`, a test makes `/var/...`).
func isAt(_ url: URL?, _ expected: URL) -> Bool { url.map { LibraryPresentation.key($0) } == LibraryPresentation.key(expected) }

// Rows: title, date, length, badge, in the exact words.
do {
    let titled = LibraryPresentation.row(libMeeting("2026-10-28_1508", title: "Weekly sync", seconds: 2530))
    check(titled.title == "Weekly sync" && titled.date == "28 Oct 2026, 15:08" && titled.length == "42 min" && titled.badge == nil,
          "L1: a titled meeting: title, date, length, no badge (\(titled))")
    check(titled.caption == "28 Oct 2026, 15:08 · 42 min", "L1: its caption is the date and the length (\(titled.caption))")
    let untitled = LibraryPresentation.row(libMeeting("2026-10-28_1508", seconds: 2530))
    check(untitled.title == "28 October 2026, 15:08" && untitled.caption == "42 min",
          "L1: an untitled meeting is titled by its date, which its caption does not repeat (\(untitled.title) / \(untitled.caption))")
    let v12 = LibraryPresentation.row(libMeeting("2026-10-28 0900 Standup", record: false))
    check(v12.title == "Standup" && v12.length == nil && v12.caption == "28 Oct 2026, 09:00" && v12.badge == nil,
          "L1: a folder with no record takes its title from the folder name and has no length (\(v12))")
    let blank = LibraryPresentation.row(libMeeting("2026-10-28 0900 Standup", title: "  "))
    check(blank.title == "Standup", "L1: a blank title in the record falls back to the folder's")
    check(titled.id == LibraryPresentation.key(libURL("2026-10-28_1508")) && titled.id == "/Meetings/2026-10-28_1508",
          "L1: a row's id is its folder's path")
    let spellings = ["/var/folders/x/Meetings/2026-10-28_1508", "/private/var/folders/x/Meetings/2026-10-28_1508/", "/var/folders/x/./Meetings/2026-10-28_1508/",
                     "/var/folders/x/Meetings/../Meetings/2026-10-28_1508"]
    check(Set(spellings.map { LibraryPresentation.key(URL(fileURLWithPath: $0)) }).count == 1
          && LibraryPresentation.key(URL(fileURLWithPath: "/private/tmp/a")) == "/tmp/a" && LibraryPresentation.key(URL(fileURLWithPath: "/private/other/a")) == "/private/other/a",
          "L1: one folder, one key, however it is spelled, whether or not it is still there")
    let lengths: [(Int, String?)] = [(-5, nil), (0, nil), (1, "1 s"), (59, "59 s"), (60, "1 min"), (119, "1 min"), (120, "2 min"),
                                     (3599, "59 min"), (3600, "1 h 00 min"), (3900, "1 h 05 min"), (7260, "2 h 01 min")]
    let wrong = lengths.filter { LibraryPresentation.lengthText($0.0) != $0.1 }.map { "\($0.0) -> \(LibraryPresentation.lengthText($0.0) ?? "nil")" }
    check(wrong.isEmpty, "L1: length in words, from under a minute to hours (\(wrong))")
}
do {
    // why a meeting failed
    let name = "2026-10-28_1508"
    func problem(_ m: Meeting) -> String? { LibraryPresentation.row(m).problem }
    check(problem(libMeeting(name, .failed, error: "transcription failed on both sides")) == "transcription failed on both sides",
          "F1: a failed meeting carries the reason it failed")
    check(problem(libMeeting(name, .failed)) == nil && problem(libMeeting(name, .failed, error: "  \n ")) == nil, "F1: no reason, no line")
    check(problem(libMeeting(name, .failed, error: "\nfirst line\nsecond line")) == "first line", "F1: one line: the first with text")
    check(problem(libMeeting(name, .done, error: "left over")) == nil && problem(libMeeting(name, .queued, error: "left over")) == nil,
          "F1: only a failed meeting shows one")
    check(problem(libMeeting(name, .failed, error: "it broke", record: false)) == nil, "F1: a folder with no record has none")
    // the Unprocessed badge says there is something to do about it
    let unprocessed = libMeeting(name, .unprocessed)
    check(LibraryPresentation.row(unprocessed, processable: true).badge?.text == "Unprocessed"
          && LibraryPresentation.row(unprocessed, processable: false).badge == nil, "F2: Unprocessed only when Process is offered")
    check(LibraryPresentation.row(libMeeting(name, .failed), processable: false).badge?.text == "Failed", "F2: Failed is shown whatever Process offers")
}
do {
    let name = "2026-10-28_1508"
    let here = libURL(name)
    func badge(_ m: Meeting, _ phase: Session.Phase = .idle, processing: URL? = nil, stage: String? = nil) -> String? {
        LibraryPresentation.row(m, phase: phase, processing: processing, stage: stage).badge?.text
    }
    check(badge(libMeeting(name, .done)) == nil, "L2: done has no badge")
    check(badge(libMeeting(name, .recording), .recording(here)) == "Recording", "L2: the session's folder, recording: Recording")
    check(badge(libMeeting(name, .recording), .paused(here)) == "Paused", "L2: the session's folder, paused: Paused")
    check(badge(libMeeting(name, .finalising), .finalising(here)) == "Saving", "B7: the session's folder, finalising: Saving")
    check(badge(libMeeting(name, .recording)) == "Recording", "L2: a record that says recording, with no session on it: Recording")
    check(badge(libMeeting(name, .finalising)) == "Saving", "B7: a record that says finalising: Saving")
    check(badge(libMeeting(name, .queued)) == "Queued", "L2: queued")
    check(badge(libMeeting(name, .processing)) == "Processing", "L2: processing, no stage known")
    check(badge(libMeeting(name, .processing, stage: "minutes")) == "Writing minutes", "L2: processing, with the stage its record holds")
    check(badge(libMeeting(name, .processing, stage: "transcribing"), processing: here, stage: "speakers") == "Finding speakers",
          "L2: processing, the live stage wins over the record's")
    check(badge(libMeeting(name, .queued), processing: here) == "Processing", "L2: the queue's current job is processing even if the record still says queued")
    check(badge(libMeeting(name, .queued), processing: here, stage: "transcribing") == "Transcribing", "L2: with its stage in words")
    check(badge(libMeeting(name, .processing, stage: ProcessingQueue.waitingStage), processing: here, stage: ProcessingQueue.waitingStage)
          == "Waiting for another meetingbox", "L2: waiting on another meetingbox says so")
    check(badge(libMeeting(name, .queued), processing: libURL("2026-10-28_1600"), stage: "minutes") == "Queued",
          "L2: another meeting being processed does not touch this one's badge")
    check(badge(libMeeting(name, .failed)) == "Failed", "L2: failed")
    check(badge(libMeeting(name, .unprocessed)) == "Unprocessed", "L2: unprocessed")
    check(badge(libMeeting(name, .done), .recording(libURL("2026-10-28_1600"))) == nil, "L2: a recording elsewhere does not touch this one's badge")
    check(badge(libMeeting(name, .queued), .recording(URL(fileURLWithPath: "/Meetings/./2026-10-28_1508/"))) == "Recording",
          "L2: folders are the same place however they are spelled")
    check(LibraryBadge.processing(stage: "done").text == "Done" && LibraryBadge.processing(stage: "odd").text == "odd",
          "L2: any stage the queue labels, or its own words")
}
do {
    // newest first, as the store gives them, through rows
    let root = freshRoot()
    for n in ["2026-10-26_1000", "2026-10-28_1508", "2026-10-27 0900 Standup"] { _ = make(root, n) }
    let rows = LibraryPresentation.rows(MeetingStore(root: root).scan())
    check(rows.map(\.title) == ["28 October 2026, 15:08", "Standup", "26 October 2026, 10:00"], "L3: rows are newest first (\(rows.map(\.title)))")
}

// Search: through the store's own matches, after indexTranscripts.
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    let a = make(root, "2026-10-28_1508", files: ["transcript.txt": "We went through the Café budget"])
    _ = make(root, "2026-10-27 0900 Standup", files: ["transcript.txt": "nothing to see"])
    let c = make(root, "2026-10-26_1000")
    try! store.update(c) { $0.title = "Budget review" }
    let sem = DispatchSemaphore(value: 0)
    store.indexTranscripts { sem.signal() }
    check(sem.wait(timeout: .now() + 10) == .success, "L4: the transcripts are indexed")
    let all = store.scan()
    func found(_ q: String) -> [String] { LibraryPresentation.visible(all, query: q, store: store).map { $0.folder.url.lastPathComponent } }
    check(found("") == all.map { $0.folder.url.lastPathComponent } && found("   ") == found(""), "L4: a blank search shows every meeting, in order")
    check(found("cafe") == [a.lastPathComponent], "L4: a transcript word, case and accents ignored (\(found("cafe")))")
    check(found("standup") == ["2026-10-27 0900 Standup"], "L4: a title in a folder name (\(found("standup")))")
    check(found("budget") == [a.lastPathComponent, c.lastPathComponent], "L4: a title in a record and a transcript, newest first (\(found("budget")))")
    check(found("nonesuch").isEmpty, "L4: nothing matches nothing")
}

// Actions.
do {
    let name = "2026-10-28_1508"
    let here = libURL(name)
    let audio = MeetingFiles(audio: here.appendingPathComponent("audio.m4a"), runnable: true)
    let old = MeetingFiles(audio: here.appendingPathComponent("2026-10-28_1508_meeting.m4a"), runnable: false)
    let none = MeetingFiles()
    func acts(_ m: Meeting, _ files: MeetingFiles, _ phase: Session.Phase = .idle) -> [LibraryAction] {
        LibraryPresentation.actions(for: m, phase: phase, files: files, processing: nil)
    }
    check(acts(libMeeting(name, .done), audio) == [.rename, .showInFinder, .playAudio, .transcribeAgain],
          "L5: a done meeting: Rename, Show in Finder, Play audio, and Transcribe again for the audio a job runs")
    check(acts(libMeeting(name, .done), none) == [.rename, .showInFinder], "L5: no audio, no Play")
    check(acts(libMeeting(name, .done), old) == [.rename, .showInFinder, .playAudio], "L5: a v1.2 audio file plays")
    check(acts(libMeeting(name, .unprocessed), audio) == [.rename, .showInFinder, .playAudio, .process], "L5: unprocessed with audio: Process too")
    check(acts(libMeeting(name, .failed), audio) == [.rename, .showInFinder, .playAudio, .process], "L5: failed with audio: Process too")
    check(acts(libMeeting(name, .unprocessed), none) == [.rename, .showInFinder] && acts(libMeeting(name, .failed), none) == [.rename, .showInFinder],
          "L5: Process is not offered without audio")
    check(acts(libMeeting(name, .unprocessed), old) == [.rename, .showInFinder, .playAudio],
          "L5: nor for audio the queue does not run (a v1.2 *_meeting.m4a)")
    for s in [MeetingState.done, .queued, .processing] {
        check(!acts(libMeeting(name, s), audio).contains(.process), "L5: no Process for \(s)")
    }
    check(acts(libMeeting(name, .recording), audio, .idle) == [.rename, .showInFinder, .playAudio], "L5: a stale recording record is just a meeting")
    check(LibraryAction.allCases.map(\.title) == ["Pause", "Resume", "Stop", "Rename…", "Show in Finder", "Open in QuickTime Player", "Process",
                                                  "Redo minutes…", "Transcribe again…"], "L5, T9: the words; the meeting page's Play audio is Open in QuickTime Player")
    // the meeting being recorded
    let live = libMeeting(name, .recording)
    check(acts(live, none, .recording(here)) == [.pause, .stop, .showInFinder], "L5: recording: Pause, Stop, Show in Finder")
    check(acts(live, none, .paused(here)) == [.resume, .stop, .showInFinder], "L5: paused: Resume, Stop, Show in Finder")
    check(acts(live, none, .finalising(here)) == [.showInFinder], "L5: finalising: only Show in Finder")
    // C5: nothing is played while a recording or a pause is under way: system audio would take it in
    check(acts(libMeeting(name, .done), audio, .recording(libURL("2026-10-28_1600"))) == [.rename, .showInFinder, .transcribeAgain],
          "L5, C5: while another meeting records, no Play audio (a redo is still offered)")
    check(acts(libMeeting(name, .unprocessed), audio, .paused(libURL("2026-10-28_1600"))) == [.rename, .showInFinder, .process],
          "L5, C5: nor while it is paused; Process is still offered")
    check(acts(libMeeting(name, .done), audio, .finalising(libURL("2026-10-28_1600"))) == [.rename, .showInFinder, .playAudio, .transcribeAgain],
          "L5, C5: once it is only being saved, Play audio again")
}
do {
    // what is on disk
    let root = freshRoot()
    let main = MeetingFolder.parse(make(root, "2026-10-28_1508", files: ["audio.m4a": "a", "2026-10-28_1508_meeting.m4a": "b"]))!
    let old = MeetingFolder.parse(make(root, "2026-10-28_1600", files: ["2026-10-28_1600_meeting.m4a": "b"]))!
    let empty = MeetingFolder.parse(make(root, "2026-10-28_1700"))!
    let m = MeetingFiles.read(main), o = MeetingFiles.read(old), e = MeetingFiles.read(empty)
    check(m.audio?.lastPathComponent == "audio.m4a" && m.runnable, "L5: audio.m4a plays and is what the queue runs")
    check(o.audio?.lastPathComponent == "2026-10-28_1600_meeting.m4a" && !o.runnable, "L5: a v1.2 file plays, but the queue does not run it")
    check(e.audio == nil && !e.runnable, "L5: nothing there, nothing to play")
    // an unfinished recording plays what there is, but is not run
    let unfinished = MeetingFolder.parse(make(root, "2026-10-28_1800", files: ["audio.m4a": "a", "mic.caf": "c"]))!
    let done = MeetingFolder.parse(make(root, "2026-10-28_1810", files: ["audio.m4a": "a", Finaliser.marker: "", "mic.caf": "c"]))!
    check(MeetingFiles.read(unfinished).audio != nil && !MeetingFiles.read(unfinished).runnable && !MeetingFiles.canRun(unfinished.url),
          "U4: an unfinished recording has audio to play and nothing for the queue")
    check(MeetingFiles.read(done).runnable && MeetingFiles.canRun(done.url) && MeetingFiles.canRun(main.url), "U4: a finished one, and one from before Stage 2, are run")
}

// Busy, and rename, in words.
do {
    let name = "2026-10-28_1508"
    let here = libURL(name)
    let other = libURL("2026-10-28_1600")
    func busy(_ recorded: MeetingState?, phase: Session.Phase = .idle, current: URL? = nil) -> Bool {
        LibraryPresentation.isBusy(here, phase: phase, current: current, recorded: recorded)
    }
    check(busy(.recording) && busy(.finalising) && busy(.queued) && busy(.processing), "R1: recording, finalising, queued and processing records are busy")
    check(!busy(.done) && !busy(.failed) && !busy(.unprocessed) && !busy(nil), "R1: done, failed, unprocessed and no record are not")
    check(busy(.done, phase: .recording(here)) && busy(.done, phase: .paused(here)) && busy(nil, phase: .finalising(here)),
          "R1: the session's folder is busy in any phase but idle")
    check(!busy(.done, phase: .recording(other)) && !busy(.done, phase: .idle), "R1: another meeting recording does not make this one busy")
    check(busy(.done, current: here) && !busy(.done, current: other), "R1: the queue's current job is busy")
    check(LibraryPresentation.renameMessage(RenameError.busy) == "That meeting is busy"
          && LibraryPresentation.renameMessage(RenameError.exists) == "A meeting with that name already exists"
          && LibraryPresentation.renameMessage(RenameError.emptyTitle) == "Type a title", "R1: the three messages, exactly")
    check(LibraryPresentation.renameMessage(POSIXError(.EACCES)).hasPrefix("Could not rename"), "R1: any other error is said to be a failure to rename")
}
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    func folder(_ name: String, _ state: MeetingState? = nil) -> MeetingFolder {
        let dir = make(root, name)
        if let state = state { try! store.update(dir) { $0.state = state } }
        return MeetingFolder.parse(dir)!
    }
    func rename(_ f: MeetingFolder, _ title: String, phase: Session.Phase = .idle, current: URL? = nil) -> (MeetingFolder?, Error?) {
        let meeting = store.scan().first { LibraryPresentation.key($0.folder.url) == LibraryPresentation.key(f.url) }!
        do { return (try LibraryPresentation.rename(meeting, to: title, store: store, phase: phase, current: current), nil) }
        catch { return (nil, error) }
    }
    func says(_ e: Error?) -> String? { e.map(LibraryPresentation.renameMessage) }

    let f1 = folder("2026-10-28_1508", .done)
    let (r1, e1) = rename(f1, "Weekly sync")
    let named = root.appendingPathComponent("2026-10-28 1508 Weekly sync")
    check(e1 == nil && isAt(r1?.url, named) && r1?.title == "Weekly sync" && fm.fileExists(atPath: named.path)
          && !fm.fileExists(atPath: f1.url.path), "R2: the folder is renamed to 'YYYY-MM-DD HHMM Title'")
    let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: named.appendingPathComponent("meeting.json")))) as? [String: Any]
    check(json?["title"] as? String == "Weekly sync" && json?["state"] as? String == "done", "R2: and the title is written to meeting.json beside it, the state kept")
    let scanned = store.scan().first
    check(scanned?.record?.title == "Weekly sync" && scanned?.folder.url.lastPathComponent == "2026-10-28 1508 Weekly sync", "R2: a scan then shows it")

    let f2 = folder("2026-10-28_1600")
    let (r2, _) = rename(f2, "a/b: c")
    check(r2?.title == "a-b- c" && (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("2026-10-28 1600 a-b- c/meeting.json"))) as? [String: Any])?["title"] as? String == "a-b- c",
          "R2: unsafe characters become hyphens, in the folder and the title; a folder with no record is given one")

    // a folder already named as the rename would name it
    let f4 = folder("2026-10-28_1800")
    _ = make(root, "2026-10-28 1800 Review")
    let (r4, e4) = rename(f4, "Review")
    check(r4 == nil && says(e4) == "A meeting with that name already exists" && fm.fileExists(atPath: f4.url.path)
          && fm.fileExists(atPath: root.appendingPathComponent("2026-10-28 1800 Review").path), "R2: a name that is taken is refused, and nothing moves")

    for title in ["", "   ", "...", " . "] {
        let (r, e) = rename(f4, title)
        check(r == nil && says(e) == "Type a title" && fm.fileExists(atPath: f4.url.path), "R2: '\(title)' is refused as 'Type a title'")
    }

    // busy: checked now, on the record on disk and on the session and the queue
    for (i, s) in [MeetingState.recording, .finalising, .queued, .processing].enumerated() {
        let f = folder("2026-10-29_10\(i)0", s)
        let (r, e) = rename(f, "Busy one")
        check(r == nil && says(e) == "That meeting is busy" && fm.fileExists(atPath: f.url.path), "R3: a \(s) meeting is busy")
    }
    let f5 = folder("2026-10-29_1400", .done)
    let (r5, e5) = rename(f5, "Busy one", phase: .recording(f5.url))
    check(r5 == nil && says(e5) == "That meeting is busy", "R3: the session's folder is busy")
    let f6 = folder("2026-10-29_1410", .done)
    let (r6, e6) = rename(f6, "Busy one", current: f6.url)
    check(r6 == nil && says(e6) == "That meeting is busy", "R3: the queue's current job is busy")
    let f7 = folder("2026-10-29_1420", .done)
    let (r7, e7) = rename(f7, "Fine", phase: .recording(f6.url), current: f6.url)
    check(r7?.title == "Fine" && e7 == nil, "R3: a meeting nothing is using renames")
    // the moment of renaming: a record that changed since the list was read
    let f8 = folder("2026-10-29_1430", .done)
    try! store.update(f8.url) { $0.state = .queued }
    let (r8, e8) = rename(f8, "Late")
    check(r8 == nil && says(e8) == "That meeting is busy", "R3: the state is read from the disk at the moment, not from a list read earlier")
    let f9 = folder("2026-10-29_1440", .failed)
    check(rename(f9, "After failure").0?.title == "After failure", "R3: failed and unprocessed meetings rename")
    check(rename(folder("2026-10-29_1450", .unprocessed), "Never run").0?.title == "Never run", "R3: unprocessed too")
}

// A rename whose folder and title do not agree, or whose title cannot be saved: made right, or said so.
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    func meeting(_ dir: URL) -> Meeting { store.scan().first { LibraryPresentation.key($0.folder.url) == LibraryPresentation.key(dir) }! }
    func rename(_ dir: URL, _ title: String, phase: Session.Phase = .idle) -> (MeetingFolder?, Error?) {
        do { return (try LibraryPresentation.rename(meeting(dir), to: title, store: store, phase: phase, current: nil), nil) }
        catch { return (nil, error) }
    }
    func recordTitle(_ dir: URL) -> String? { meeting(dir).record?.title }
    func recordBytes(_ dir: URL) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("meeting.json")) }

    // the folder has the title but the record says another: the move is skipped, the record is written, the row shows it
    let a = make(root, "2026-10-28 1508 Weekly sync")
    try! store.update(a) { $0.title = "Old name"; $0.state = .done }
    check(LibraryPresentation.row(meeting(a)).title == "Old name", "R6: the row shows the record's title, not the folder's")
    let inodeA = inode(a)
    let (ra, ea) = rename(a, "Weekly sync")
    check(ea == nil && isAt(ra?.url, a) && inode(a) == inodeA && recordTitle(a) == "Weekly sync" && LibraryPresentation.row(meeting(a)).title == "Weekly sync",
          "R6: renaming to the folder's own title writes only the record, and the row then shows it")
    // already the same in both: nothing is written
    let before = recordBytes(a)
    let (rb, eb) = rename(a, "Weekly sync")
    check(eb == nil && isAt(rb?.url, a) && recordBytes(a) == before, "R6: the same title in the folder and the record: nothing is touched")
    // a v1.2 folder: its title is in its name and there is no record: the folder stays, the record is made with the title
    let v12 = make(root, "2026-10-27 0900 Standup")
    let inodeV = inode(v12)
    let (rc, ec) = rename(v12, "Standup")
    check(ec == nil && isAt(rc?.url, v12) && inode(v12) == inodeV && recordTitle(v12) == "Standup" && meeting(v12).state == .unprocessed,
          "R6: a titled folder with no record, renamed to its title: not moved, and its record is made, state as a scan infers it")
    // the record's title is the one shown and it is what is typed, but the folder says another: the folder follows
    let d = make(root, "2026-10-26 1000 New")
    try! store.update(d) { $0.title = "Old"; $0.state = .done }
    let (rd, ed) = rename(d, "Old")
    let movedD = root.appendingPathComponent("2026-10-26 1000 Old")
    check(ed == nil && isAt(rd?.url, movedD) && fm.fileExists(atPath: movedD.path) && !fm.fileExists(atPath: d.path) && recordTitle(movedD) == "Old",
          "R6: a title that is only the record's moves the folder to match")
    // a busy meeting is not touched, record-only writes included
    let e = make(root, "2026-10-25 0900 Queued one")
    try! store.update(e) { $0.title = "Other"; $0.state = .queued }
    let (re, ee) = rename(e, "Queued one")
    check(re == nil && ee.map(LibraryPresentation.renameMessage) == "That meeting is busy" && recordTitle(e) == "Other", "R6: a busy meeting's record is not written either")
    check(rename(e, "  ").1.map(LibraryPresentation.renameMessage) == "Type a title", "R6: an empty title is still 'Type a title' first")

    // the title cannot be saved after the folder has moved: a folder nobody can write into (a real permission failure)
    let g = make(root, "2026-10-24_1900")
    try! store.update(g) { $0.state = .done }
    let inodeG = inode(g)
    chmod(g.path, 0o500)
    let (rg, eg) = rename(g, "Late title")
    let movedG = root.appendingPathComponent("2026-10-24 1900 Late title")
    let notSaved = eg as? TitleNotSaved
    check(rg == nil && isAt(notSaved?.folder.url, movedG) && notSaved?.folder.title == "Late title"
          && eg.map(LibraryPresentation.renameMessage) == "Renamed, but the title could not be saved",
          "R7: the folder moved but the title could not be written: an error that says so and names the moved folder")
    check(fm.fileExists(atPath: movedG.path) && !fm.fileExists(atPath: g.path) && inode(movedG) == inodeG && recordTitle(movedG) == nil,
          "R7: the folder is on disk under its new name and its record is as it was")
    chmod(movedG.path, 0o700)
    let (rh, eh) = rename(movedG, "Late title")
    check(eh == nil && isAt(rh?.url, movedG) && inode(movedG) == inodeG && recordTitle(movedG) == "Late title",
          "R7: once it can be written, the same text writes the title and moves nothing again")
    check(LibraryPresentation.renameMessage(RenameError.busy) == "That meeting is busy" && LibraryPresentation.renameMessage(RenameError.exists) == "A meeting with that name already exists"
          && LibraryPresentation.renameMessage(RenameError.emptyTitle) == "Type a title", "R7: the three other messages are as they were")
}

// LibraryModel: the window's state, driven as the views drive it. The work it hands to background
// queues comes back to the main queue, so these wait on the main run loop. Never Show in Finder or Play
// (they would open the real Finder).
func settle(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if MainActor.assumeIsolated(condition) { return true }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return MainActor.assumeIsolated(condition)
}
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let runner = FakeRunner()
    let queue = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil)
    let model = LibraryModel(store: r.store, session: session, queue: queue)
    var controlled: [MenuAction] = []
    model.control = { controlled.append($0) }
    let root = r.store.root
    let a = make(root, "2026-10-28_1508", files: ["notes.md": "**Decisions**\n- ship on Friday", "transcript.txt": "[00:00:01] Me: the café budget",
                                                  "audio.m4a": "a"])
    try! r.store.update(a) { $0.state = .done; $0.seconds = 2530 }
    let b = make(root, "2026-10-27 0900 Standup", files: ["transcript.txt": "[00:00:02] Me: nothing to see"])
    let c = make(root, "2026-10-26_1000", files: ["audio.m4a": "a"])
    let keyA = LibraryPresentation.key(a), keyB = LibraryPresentation.key(b), keyC = LibraryPresentation.key(c)

    check(!model.hasScanned && model.rows.isEmpty && model.selectedMeeting == nil, "W1: before anything is read there is nothing, and it is not 'no meetings'")
    model.reload()
    check(settle { model.hasScanned && model.meetings.count == 3 }, "W1: reload reads the meetings off the main queue and publishes them")
    check(model.rows.map(\.id) == [keyA, keyB, keyC] && model.visible.count == 3, "W1: newest first, all listed")
    check(model.rows.map { $0.badge?.text } == [nil, nil, "Unprocessed"],
          "W1: done has no badge; a folder with no notes is Unprocessed only if it has the audio to process (\(model.rows.map { $0.badge?.text ?? "-" }))")

    // selection reads the files off the main queue; another meeting's text is never shown for this one
    model.select(keyA)
    check(model.shownContent == nil && model.selectedMeeting != nil, "W2: selected, not yet read: nothing shown")
    check(settle { model.shownContent != nil }, "W2: the minutes and the transcript are read")
    let shownMinutes = model.shownContent?.minutes.map { String($0.characters) }
    check(shownMinutes == "Decisions\n- ship on Friday" && model.shownContent?.transcript == "[00:00:01] Me: the café budget"
          && model.shownContent?.files.audio?.lastPathComponent == "audio.m4a" && model.shownContent?.files.runnable == true,
          "W2: notes.md as inline markdown, transcript.txt as it is, the audio")
    check(model.actions(for: model.selectedMeeting!) == [.rename, .showInFinder, .playAudio, .redoMinutes, .transcribeAgain], "W2: its actions")
    model.select(keyB)
    check(model.shownContent == nil, "W2: the previous meeting's text is gone at once")
    check(settle { model.shownContent?.key == keyB }, "W2: and the new one's arrives")
    check(model.shownContent.map { $0.minutes == nil && $0.transcript != nil && $0.files.audio == nil } ?? false, "W2: a meeting with no minutes and no audio says so (nil)")
    check(model.actions(for: model.selectedMeeting!) == [.rename, .showInFinder], "W2: and offers no Play")

    // search: off the main queue, through the store's matches; a newer keystroke wins
    model.search("café")
    check(settle { model.visible.map(\.folder.url.lastPathComponent) == ["2026-10-28_1508"] }, "W3: a transcript word narrows the list")
    check(model.rows.count == 1 && model.meetings.count == 3, "W3: the rows are the narrowed list, the meetings are all of them")
    model.search("sta"); model.search("stand"); model.search("standup")
    check(settle { model.visible.map(\.folder.url.lastPathComponent) == ["2026-10-27 0900 Standup"] }, "W3: typing on, the last search is the one shown")
    model.search("nonesuch")
    check(settle { model.visible.isEmpty }, "W3: no match, an empty list")
    model.search("")
    check(model.visible.count == 3, "W3: a blank search lists all of them at once")

    // show: a meeting's minutes, whatever was searched
    model.search("nonesuch")
    model.show(a)
    check(model.searchText == "" && model.selection == keyA && model.pane == .minutes, "W4: show clears the search, selects the meeting and opens its minutes")
    check(settle { model.visible.count == 3 && model.shownContent?.key == keyA }, "W4: and the list and the text follow")

    // rename: the sheet, the checks, the folder, the record, the selection
    model.select(keyC)
    model.beginRename()
    check(model.renaming?.key == keyC && model.renaming?.text == "", "R4: the sheet opens empty for an untitled meeting")
    model.renameText("Budget review")
    model.commitRename()
    let renamedC = root.appendingPathComponent("2026-10-26 1000 Budget review")
    check(model.renaming == nil && fm.fileExists(atPath: renamedC.path) && !fm.fileExists(atPath: c.path), "R4: the folder is renamed and the sheet closes")
    check(model.selection == LibraryPresentation.key(renamedC) && model.selectedMeeting?.folder.title == "Budget review",
          "R4: the selection follows the folder at once")
    check(model.rows.last?.title == "Budget review" && model.rows.last?.badge?.text == "Unprocessed",
          "R4: titled in its row at once, and still badged (the folder has the audio to process)")
    check(settle { model.meetings.last?.record?.title == "Budget review" && model.shownContent?.key == model.selection },
          "R4: the list is read again, now with the title in meeting.json, and the text follows")
    model.beginRename()
    check(model.renaming?.text == "Budget review", "R4: the sheet opens with the title as it is")
    model.commitRename()
    check(model.renaming == nil && fm.fileExists(atPath: renamedC.path), "R4: an unchanged title closes the sheet and changes nothing")
    model.cancelRename()

    model.select(keyB)
    model.beginRename()
    model.renameText("   ")
    model.commitRename()
    check(model.renaming?.error == "Type a title" && fm.fileExists(atPath: b.path), "R5: an empty title is said to be, and the sheet stays")
    model.renameText("Standup")
    check(model.renaming?.error == nil, "R5: typing clears the message")
    _ = make(root, "2026-10-27 0900 Standup copy")
    model.renameText("Standup copy")
    model.commitRename()
    check(model.renaming?.error == "A meeting with that name already exists" && fm.fileExists(atPath: b.path), "R5: a taken name is said to be")
    try! r.store.update(b) { $0.state = .queued }
    model.renameText("Fresh name")
    model.commitRename()
    check(model.renaming?.error == "That meeting is busy" && fm.fileExists(atPath: b.path), "R5: a meeting that became busy since the list was read is busy")
    model.cancelRename()
    check(model.renaming == nil, "R5: Cancel closes the sheet")

    // Process: unprocessed goes through process, failed through retry
    let u = make(root, "2026-10-25_0900", files: ["audio.m4a": "a"])
    let f = make(root, "2026-10-24_0900", files: ["audio.m4a": "a"])
    try! r.store.update(f) { $0.state = .failed; $0.error = "it broke" }
    model.reload()
    check(settle { model.meetings.count == 6 }, "P6: two more meetings are read")
    model.select(LibraryPresentation.key(u))
    check(settle { model.shownContent?.files.runnable == true }, "P6: the audio is found")
    check(model.actions(for: model.selectedMeeting!).contains(.process), "P6: an unprocessed meeting with audio offers Process")
    model.perform(.process)
    check(runner.calls.count == 1 && runner.calls[0].audio.deletingLastPathComponent().lastPathComponent == "2026-10-25_0900"
          && runner.calls[0].stateAtRun == "processing", "P6: Process queues it, and it runs")
    model.update(StatusInput(processing: u, stage: "transcribing"))
    check(model.rows.first { $0.id == LibraryPresentation.key(u) }?.badge?.text == "Transcribing", "P6: its row says what the queue is doing, from the live stage")
    model.select(LibraryPresentation.key(f))
    check(settle { model.shownContent?.key == LibraryPresentation.key(f) && model.shownContent?.files.runnable == true }, "P6: the failed meeting's audio is found")
    check(model.actions(for: model.selectedMeeting!).contains(.process), "P6: a failed meeting with audio offers Process")
    model.perform(.process)
    check(r.store.scan().first { $0.folder.url.lastPathComponent == "2026-10-24_0900" }?.state == .queued && runner.calls.count == 1,
          "P6: a failed meeting is written queued behind the running job (retry)")

    // the session: a new recording appears at once, and its row has the controls
    let live = make(root, "2026-10-29_0900")
    try! r.store.update(live) { $0.state = .recording }
    model.update(StatusInput(phase: .recording(live)))
    check(settle { model.meetings.count == 7 }, "S1: a new phase reads the list again, so the recording is in it")
    check(model.rows.first?.badge == .recording && model.rows.first?.id == LibraryPresentation.key(live), "S1: newest first, badged Recording")
    model.select(LibraryPresentation.key(live))
    check(model.actions(for: model.selectedMeeting!) == [.pause, .stop, .showInFinder], "S1: and it offers Pause, Stop and Show in Finder")
    model.perform(.pause); model.perform(.stop)
    model.update(StatusInput(phase: .paused(live)))
    model.perform(.resume)
    check(controlled == [.pause, .stop, .resume], "S1: Pause, Stop and Resume go through the control path, never the session")
    check(session.phase == .idle, "S1: the model did not touch the session")

    // a rename whose title cannot be saved: the sheet stays and says so, the list shows the disk, and the same text finishes it
    let half = make(root, "2026-10-22_0900")
    model.reload()
    check(settle { model.meetings.contains { LibraryPresentation.key($0.folder.url) == LibraryPresentation.key(half) } }, "R8: the new folder is read")
    model.select(LibraryPresentation.key(half))
    model.beginRename()
    model.renameText("Half done")
    let halfInode = inode(half)
    chmod(half.path, 0o500)
    model.commitRename()
    let moved = root.appendingPathComponent("2026-10-22 0900 Half done")
    check(model.renaming?.error == "Renamed, but the title could not be saved" && fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: half.path),
          "R8: the folder moved, and the sheet stays open saying the title could not be saved (\(model.renaming?.error ?? "closed"))")
    check(model.renaming?.key == LibraryPresentation.key(moved) && model.selection == LibraryPresentation.key(moved) && isAt(model.selectedMeeting?.folder.url, moved),
          "R8: the sheet and the selection follow the folder to its new name")
    check(settle { model.meetings.contains { $0.folder.url.lastPathComponent == "2026-10-22 0900 Half done" && $0.record?.title == nil } },
          "R8: the list is read again and shows what is on the disk")
    chmod(moved.path, 0o700)
    model.commitRename()
    check(model.renaming == nil && inode(moved) == halfInode && fm.fileExists(atPath: moved.path), "R8: the same text again closes the sheet and moves nothing")
    check(settle { model.meetings.first { $0.folder.url.lastPathComponent == "2026-10-22 0900 Half done" }?.record?.title == "Half done" },
          "R8: and the title is in meeting.json")
    check(model.rows.first { $0.id == LibraryPresentation.key(moved) }?.title == "Half done", "R8: the row shows it")
}

// The window comes forward for finished minutes unless a recording is running.
check(LibraryPresentation.shouldOpenMinutes(openMinutes: true, phase: .idle), "O1: minutes ready, nothing recording: open them")
check(LibraryPresentation.shouldOpenMinutes(openMinutes: true, phase: .finalising(libURL("2026-10-28_1508"))), "O1: a recording only being finalised does not hold them back")
check(!LibraryPresentation.shouldOpenMinutes(openMinutes: true, phase: .recording(libURL("2026-10-28_1508"))), "O1: never over a recording")
check(!LibraryPresentation.shouldOpenMinutes(openMinutes: true, phase: .paused(libURL("2026-10-28_1508"))), "O1: nor a paused one")
check(!LibraryPresentation.shouldOpenMinutes(openMinutes: false, phase: .idle), "O1: nor when the setting is off")

// Minutes: inline markdown, whitespace kept, plain text when it will not parse.
do {
    let text = "**Decisions**\n- ship on Friday\n\n  indented _note_"
    let rendered = LibraryPresentation.minutes(text)
    check(String(rendered.characters) == "Decisions\n- ship on Friday\n\n  indented note", "M1: markdown marks go, line breaks and spaces stay (\(String(rendered.characters).debugDescription))")
    let strong = rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false }
    check(strong, "M1: bold is bold")
    check(String(LibraryPresentation.minutes("").characters) == "" && String(LibraryPresentation.minutes("a [b](").characters).contains("b"),
          "M1: an empty text, and a broken link, still give text")
}

// MARK: - Preferences, the Dock icon and quitting (Task 9)

// The Dock icon only when asked for; the menu bar item when asked for or when there is no Dock icon,
// and then the setting is written back on, so the checkbox shows what is on screen.
do {
    let all = [(true, true), (true, false), (false, true), (false, false)].map {
        PreferencesPresentation.visibility(showInDock: $0.0, showMenuBar: $0.1)
    }
    check(all.map(\.dockIcon) == [true, true, false, false], "T9 dock: the Dock icon only when Show in Dock is on")
    check(all.map(\.menuBarItem) == [true, false, true, true], "T9 dock: the menu bar item when asked for, or when there is no Dock icon")
    check(all.map(\.writeBackMenuBar) == [false, false, false, true], "T9 dock: only with both off is the menu bar setting written back on")
    check(all.map(\.menuBarLocked) == [false, false, true, true], "T9 dock: without the Dock icon the menu bar checkbox cannot be turned off")
    check(FloatingMode.allCases.map(PreferencesPresentation.floatingTitle) == ["Always", "While recording", "Never"],
          "T9 floating: the three modes, in words")
}

// Quitting asks only while a recording is running or paused (a start in its grace is already recording).
do {
    let dir = libURL("2026-11-05_0900")
    check(!PreferencesPresentation.asksToQuit(.idle) && PreferencesPresentation.asksToQuit(.recording(dir))
          && PreferencesPresentation.asksToQuit(.paused(dir)) && !PreferencesPresentation.asksToQuit(.finalising(dir)),
          "T9 quit: asks while recording or paused, never when idle or finalising")
    check(PreferencesPresentation.quitMessage == "A recording is running."
          && PreferencesPresentation.quitInformation == "Stop and quit finishes the recording first. Keep recording and quit leaves it running, and meetingbox picks it up when it opens again.",
          "T9 quit: the question and its explanation, word for word")
    check(PreferencesPresentation.quitButtons == ["Stop and quit", "Keep recording and quit", "Cancel"], "T9 quit: the three buttons, in this order")
    check([0, 1, 2, 3, -1].map { PreferencesPresentation.quitChoice(button: $0) } == [.stopAndQuit, .keepRecordingAndQuit, .cancel, .cancel, .cancel],
          "T9 quit: each button is its choice, and anything else cancels")
    check(PreferencesPresentation.quitPlan(.stopAndQuit) == QuitPlan(stop: true, reply: .later), "T9 quit: Stop and quit sends Stop and waits")
    check(PreferencesPresentation.quitPlan(.keepRecordingAndQuit) == QuitPlan(stop: false, reply: .now), "T9 quit: Keep recording and quit quits at once and touches nothing")
    check(PreferencesPresentation.quitPlan(.cancel) == QuitPlan(stop: false, reply: .cancel), "T9 quit: Cancel changes nothing")

    // Log out, restart and shut down never ask (it would hold up the Mac): they keep recording and quit.
    let system = [UInt32(kAELogOut), UInt32(kAEReallyLogOut), UInt32(kAEShowRestartDialog), UInt32(kAEShowShutdownDialog),
                  UInt32(kAERestart), UInt32(kAEShutDown), UInt32(kAEQuitAll)]
    check(PreferencesPresentation.systemQuitReasons == Set(system), "T9 quit: the log out, restart and shut down reasons are the SDK's")
    var asked = 0
    let ask = { () -> QuitChoice in asked += 1; return .stopAndQuit }
    let keep = QuitPlan(stop: false, reply: .now)
    check(system.allSatisfy { PreferencesPresentation.quit(phase: .recording(dir), reason: $0, ask: ask) == keep }
          && PreferencesPresentation.quit(phase: .paused(dir), reason: UInt32(kAEReallyLogOut), ask: ask) == keep && asked == 0,
          "T9 quit: log out, restart or shut down while recording keeps recording and quits, without asking")
    check(PreferencesPresentation.quit(phase: .idle, reason: nil, ask: ask) == keep
          && PreferencesPresentation.quit(phase: .finalising(dir), reason: nil, ask: ask) == keep && asked == 0,
          "T9 quit: idle or finalising quits at once, without asking")
    check(PreferencesPresentation.quit(phase: .recording(dir), reason: nil, ask: ask) == QuitPlan(stop: true, reply: .later) && asked == 1,
          "T9 quit: Cmd-Q or the menu while recording asks, and does what was chosen")
    check(PreferencesPresentation.quit(phase: .paused(dir), reason: 0x6162_6364, ask: { .cancel }) == QuitPlan(stop: false, reply: .cancel),
          "T9 quit: any other quit event while paused asks too")
}

// The microphone list: the recorder's `--record -l` lines, "System default" first.
do {
    let listing = "  Built-in Microphone (default)\n  USB Mic\n  Studio (default) Mic\n\n   \nNo audio input devices found.\n  USB Mic\n"
    check(PreferencesPresentation.microphoneNames(listing) == ["Built-in Microphone", "USB Mic", "Studio (default) Mic"],
          "T9 mic: each indented line is a device, its (default) marker taken off, once each")
    check(PreferencesPresentation.microphoneNames("No audio input devices found.\n").isEmpty, "T9 mic: none found is none")
    func titles(_ c: MicrophoneChoice) -> [String] { c.options.map(\.title) }
    let plain = PreferencesPresentation.microphoneChoice(devices: ["Built-in Microphone", "USB Mic"], saved: nil)
    check(titles(plain) == ["System default", "Built-in Microphone", "USB Mic"] && plain.options.map(\.name) == [nil, "Built-in Microphone", "USB Mic"]
          && plain.selected == 0, "T9 mic: System default first and chosen when nothing is saved")
    let usb = PreferencesPresentation.microphoneChoice(devices: ["Built-in Microphone", "USB Mic"], saved: "USB Mic")
    check(titles(usb) == titles(plain) && usb.selected == 2, "T9 mic: a saved microphone that is connected is chosen")
    let gone = PreferencesPresentation.microphoneChoice(devices: ["Built-in Microphone"], saved: "USB Mic")
    check(titles(gone) == ["System default", "Built-in Microphone", "USB Mic (not connected)"] && gone.selected == 2 && gone.options[2].name == "USB Mic",
          "T9 mic: a saved microphone that is not connected still shows, says so, and stays chosen")
    let none = PreferencesPresentation.microphoneChoice(devices: [], saved: "USB Mic")
    check(titles(none) == ["System default", "USB Mic (not connected)"] && none.selected == 1, "T9 mic: with no devices at all too")
    let unknown = PreferencesPresentation.microphoneChoice(devices: nil, saved: nil)
    check(titles(unknown) == ["System default"] && unknown.selected == 0, "T9 mic: a listing that failed shows only System default")
    let unknownSaved = PreferencesPresentation.microphoneChoice(devices: nil, saved: "USB Mic")
    check(titles(unknownSaved) == ["System default", "USB Mic"] && unknownSaved.selected == 1,
          "T9 mic: a listing that failed keeps a saved microphone chosen, without claiming it is gone")

    // Listing runs the helper with --record -l; anything that goes wrong is no listing.
    func helper(_ body: String) -> URL {
        counter += 1
        let u = scratch.appendingPathComponent("helper\(counter)")
        try! ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        chmod(u.path, 0o755)
        return u
    }
    let argsFile = scratch.appendingPathComponent("helper-args")
    let good = helper("echo \"$@\" > '\(argsFile.path)'\nprintf '  Built-in Microphone (default)\\n  USB Mic\\n'")
    check(PreferencesPresentation.listMicrophones(helper: good) == ["Built-in Microphone", "USB Mic"], "T9 mic: the helper's list is read")
    check((try? String(contentsOf: argsFile, encoding: .utf8)) == "--record -l\n", "T9 mic: the helper is run as --record -l")
    check(PreferencesPresentation.listMicrophones(helper: helper("echo 'No audio input devices found.'")) == [], "T9 mic: a helper that finds none gives none")
    check(PreferencesPresentation.listMicrophones(helper: helper("printf '  USB Mic\\n'\nexit 1")) == nil, "T9 mic: a helper that fails gives no listing")
    check(PreferencesPresentation.listMicrophones(helper: scratch.appendingPathComponent("no-such-helper")) == nil, "T9 mic: a missing helper gives no listing")
    // A helper that hangs is ended after the time limit (5 s in the app; 1 s here), and gives no listing.
    let pidFile = scratch.appendingPathComponent("helper-pid")
    let hang = helper("echo $$ > '\(pidFile.path)'\nexec sleep 30")
    let began = Date()
    check(PreferencesPresentation.listMicrophones(helper: hang, timeout: 1) == nil && Date().timeIntervalSince(began) < 10,
          "T9 mic: a helper that hangs is given up on, and gives no listing")
    let hungPid = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    check(hungPid > 0 && kill(hungPid, 0) != 0, "T9 mic: and the helper is ended")
}

// The meetings folder moves only once nothing in the current one is in progress: queued, processing,
// recording or finalising. A recording the recorder never finished that is failed or never processed
// does not hold it up: nothing would ever finish it, in this folder or any other.
do {
    check(PreferencesPresentation.folderStillFinishing == "Some meetings in the current folder are still being finished. Try again when they are done.",
          "T9 move: the refusal, word for word")
    let root = freshRoot()
    let store = MeetingStore(root: root)
    _ = make(root, "2026-11-01_0900", files: ["notes.md": "minutes from before meeting.json"])
    let failed = make(root, "2026-11-02_0900")
    try! store.update(failed) { $0.state = .failed; $0.error = "it broke" }
    _ = make(root, "2026-11-03_0900", files: ["audio.m4a": "a"])
    check(!PreferencesPresentation.stillFinishing(store.scan()), "T9 move: done, failed and never processed meetings are finished with")
    for busy in [MeetingState.queued, .processing, .recording, .finalising] {
        let other = freshRoot()
        let otherStore = MeetingStore(root: other)
        _ = make(other, "2026-11-01_0900", files: ["notes.md": "a"])
        let dir = make(other, "2026-11-04_0900")
        try! otherStore.update(dir) { $0.state = busy }
        check(PreferencesPresentation.stillFinishing(otherStore.scan()), "T9 move: a \(busy.rawValue) meeting is still being finished")
    }
    let cut = make(root, "2026-11-05_0900", files: ["mic.caf": "x"])
    try! store.update(cut) { $0.state = .failed; $0.error = Session.interrupted }
    _ = make(root, "2026-11-06_0900", files: ["call.caf": "x"]) // no meeting.json: never processed
    check(MeetingFolder.recordingUnfinished(cut) && !PreferencesPresentation.stillFinishing(store.scan()),
          "T9 move: a recording the recorder never finished, failed or never processed, does not hold up the move")
    try! store.update(cut) { $0.state = .finalising }
    check(PreferencesPresentation.stillFinishing(store.scan()), "T9 move: the same recording still finalising does")
}

// The recording entries the Dock menu, the main menu's Recording menu and New meeting share: the menu bar
// item's own recording entries that apply now, in its order, and nothing else.
do {
    let phases: [(String, Session.Phase, [MenuAction])] = [("idle", .idle, [.start]), ("recording", .recording(meetingA), [.pause, .stop]),
                                                          ("paused", .paused(meetingA), [.resume, .stop]), ("finalising", .finalising(meetingA), [.start])]
    for (name, phase, actions) in phases {
        for p in [present(phase), present(phase, processing: meetingB, ready: meetingB, failure: Failure("start", "No microphone"), preferences: true)] {
            let entries = PreferencesPresentation.recordingEntries(p.menu)
            let statusOwn = p.menu.filter { [MenuAction.start, .pause, .resume, .stop].contains($0.action) }
            check(entries.map(\.action) == actions && entries == statusOwn,
                  "T9 recording entries: \(name) gives the menu bar item's own \(actions.map(\.title)) (\(entries.map(\.title)))")
        }
    }
    // B1: while the last recording is saved, Start's place holds a disabled line saying so, in every menu and on New meeting.
    let saving = PreferencesPresentation.recordingEntries(present(.finalising(meetingA)).menu)
    check(saving == [MenuEntry(title: "Saving the last recording…", enabled: false, action: .start)],
          "B1: finalising: the recording entries are one disabled Saving the last recording… line")
    check(PreferencesPresentation.newMeetingTitle(saving) == "Saving the last recording…"
          && PreferencesPresentation.newMeetingTitle(PreferencesPresentation.recordingEntries(present().menu)) == "New meeting"
          && PreferencesPresentation.newMeetingTitle(PreferencesPresentation.recordingEntries(present(.recording(meetingA)).menu)) == "New meeting",
          "B1: New meeting reads Saving the last recording… while finalising, and New meeting otherwise")
}

// The quit reason, in whichever form the quit event carries it: an enumeration or a type code, as an
// attribute or as a parameter.
do {
    func quitEvent(_ id: UInt32 = UInt32(kAEQuitApplication)) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(id), targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    let key = AEKeyword(kAEQuitReason)
    let logOut = UInt32(kAEReallyLogOut), shutDown = UInt32(kAEShutDown)
    let enumAttribute = quitEvent()
    enumAttribute.setAttribute(NSAppleEventDescriptor(enumCode: logOut), forKeyword: key)
    let typeAttribute = quitEvent()
    typeAttribute.setAttribute(NSAppleEventDescriptor(typeCode: logOut), forKeyword: key)
    let enumParameter = quitEvent()
    enumParameter.setParam(NSAppleEventDescriptor(enumCode: shutDown), forKeyword: key)
    let typeParameter = quitEvent()
    typeParameter.setParam(NSAppleEventDescriptor(typeCode: shutDown), forKeyword: key)
    check([enumAttribute, typeAttribute, enumParameter, typeParameter].map { PreferencesPresentation.quitReason($0) } == [logOut, logOut, shutDown, shutDown] as [UInt32?],
          "T9 quit: the reason is read as an enumeration or a type code, from an attribute or a parameter")
    let open = quitEvent(UInt32(kAEOpenApplication))
    open.setAttribute(NSAppleEventDescriptor(enumCode: logOut), forKeyword: key)
    check(PreferencesPresentation.quitReason(nil) == nil && PreferencesPresentation.quitReason(quitEvent()) == nil
          && PreferencesPresentation.quitReason(open) == nil,
          "T9 quit: no event (Cmd-Q, the menus), a quit with no reason, and an event that is not a quit give no reason")
}

// The meetings folder: an existing folder this user can write to, nothing else; never while recording.
do {
    let ok = freshRoot()
    check(PreferencesPresentation.folderProblem(ok) == nil, "T9 folder: an existing folder this user can write to is accepted")
    let file = ok.appendingPathComponent("a-file")
    fm.createFile(atPath: file.path, contents: Data())
    let locked = freshRoot()
    chmod(locked.path, 0o500)
    let refused = [file, ok.appendingPathComponent("not-there"), locked, URL(string: "https://example.com/Meetings")!]
        .map(PreferencesPresentation.folderProblem)
    check(refused.allSatisfy { $0 == "meetingbox cannot use that folder" }, "T9 folder: a file, a missing folder, a read-only folder and a web address are refused, in those words")
    chmod(locked.path, 0o700)
    let dir = libURL("2026-11-05_0900")
    check(PreferencesPresentation.canChooseFolder(.idle) && !PreferencesPresentation.canChooseFolder(.recording(dir))
          && !PreferencesPresentation.canChooseFolder(.paused(dir)) && !PreferencesPresentation.canChooseFolder(.finalising(dir)),
          "T9 folder: Choose… only while nothing is recording, paused or finalising")
}

// A recording that finished while the app was closed (quit while finalising, or stopped from the command
// with no app): the recorder has gone and its audio is complete. The next launch settles it once: queued,
// its length from the audio, the state files cleared, nothing signalled.
for state in [MeetingState.finalising, .recording] {
    let r = Rig()
    let dir = r.meeting("2026-11-05_0800") { $0.state = state; $0.seconds = 1190 }
    r.writeState(dir)
    r.rec.durations[dir.path] = 1199.6
    let s = r.make()
    s.adopt()
    check(r.rec.recovered == [dir] && r.stateOf(dir) == "queued" && (r.json(dir)["seconds"] as? Int) == 1200 && s.phase == .idle,
          "T9 adopt: a recording that finished while the app was closed is verified and queued (\(state.rawValue))")
    check(r.finished.count == 1 && r.finished[0].1 && r.rec.signals.isEmpty && r.rec.launches.isEmpty && !fm.fileExists(atPath: r.dirFile.path),
          "T9 adopt: once, with no signal and no new recorder, and its state files cleared (\(state.rawValue))")
}

// AppModel over a fake recorder and runner: every change applies at once, the folder moves the library
// and the next recording, Stop and quit waits for the recording to finish, and Keep recording and quit
// (and everything that runs as the app goes) never touches the recorder.
MainActor.assumeIsolated {
    func stateOf(_ dir: URL) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meeting.json")))) as? [String: Any])?["state"] as? String
    }
    let state = shortTemp()
    let root = freshRoot()
    let meetingsA = root.appendingPathComponent("A", isDirectory: true)
    let meetingsB = root.appendingPathComponent("B", isDirectory: true)
    try! fm.createDirectory(at: meetingsA, withIntermediateDirectories: true)
    try! fm.createDirectory(at: meetingsB, withIntermediateDirectories: true)
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = meetingsA
    prefs.sounds = false // never a real sound from a test
    prefs.showInDock = false
    prefs.showMenuBar = false
    let rec = FakeRecorder()
    let runner = FakeRunner()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: runner, freeBytes: { _ in 50 * GB })
    check(prefs.showMenuBar && model.visibility == Visibility(dockIcon: false, menuBarItem: true, writeBackMenuBar: false),
          "T9 app: with both off at launch the menu bar item is back, and the setting says so")

    var told = 0
    model.onVisibilityChange = { told += 1 }
    var changes = 0
    let watch = model.objectWillChange.sink { _ in changes += 1 }
    model.setShowInDock(true)
    check(told == 1 && prefs.showInDock && model.visibility.dockIcon && model.visibility.menuBarItem, "T9 app: Show in Dock on: the Dock icon at once")
    model.setShowMenuBar(false)
    check(told == 2 && !prefs.showMenuBar && !model.visibility.menuBarItem, "T9 app: Show in menu bar off: the item goes at once")
    model.setShowInDock(false)
    check(told == 3 && !model.visibility.dockIcon && model.visibility.menuBarItem && prefs.showMenuBar,
          "T9 app: the Dock icon off with the menu bar item off: the item comes back, and the setting is written back")
    model.setShowInDock(true)
    check(told == 4 && model.visibility == Visibility(dockIcon: true, menuBarItem: true, writeBackMenuBar: false), "T9 app: both on again")

    var before = changes
    model.setFloating(.always)
    check(changes > before && prefs.floating == .always && model.presentation.panel.visible, "T9 app: floating Always shows the button at once")
    before = changes
    model.setFloating(.never)
    check(changes > before && prefs.floating == .never && !model.presentation.panel.visible, "T9 app: floating Never hides it at once")
    model.setFloating(.whileRecording)
    before = changes
    model.setOpenMinutes(false)
    check(changes > before && !prefs.openMinutes, "T9 app: open the minutes when ready, off")
    before = changes
    model.setSounds(false)
    check(changes > before && !prefs.sounds, "T9 app: sounds off")

    check(model.presentation.menu.first { $0.action == .preferences }?.enabled == false, "T9 app: no Preferences… until there is a window to open")
    var opened = 0
    model.onOpenPreferences = { opened += 1 }
    check(model.presentation.menu.first { $0.action == .preferences }?.enabled == true, "T9 app: then Preferences… is offered")
    model.perform(.preferences)
    check(opened == 1, "T9 app: and opens the window")

    model.launch()
    model.setMicrophone("USB Mic")
    check(prefs.microphone == "USB Mic" && model.microphoneChoice.options[model.microphoneChoice.selected].name == "USB Mic",
          "T9 app: the microphone is saved and shown chosen")

    // the meetings folder: not while the current one still has meetings being finished
    let stillFinishing = "Some meetings in the current folder are still being finished. Try again when they are done."
    _ = make(meetingsA, "2026-11-01_0900", files: ["notes.md": "a"])
    _ = make(meetingsB, "2026-11-02_0900", files: ["notes.md": "b"])
    _ = make(meetingsB, "2026-11-03_0900", files: ["notes.md": "b"])
    model.library.reload()
    check(settle { model.library.meetings.map(\.folder.url.lastPathComponent) == ["2026-11-01_0900"] }, "T9 folder: the library starts on the folder setting")
    let waiting = make(meetingsA, "2026-10-30_0900")
    try! model.store.update(waiting) { $0.state = .queued } // left queued on disk; the queue has not taken it up
    model.setMeetingsFolder(meetingsB)
    check(settle { model.folderProblem == stillFinishing } && prefs.meetingsFolder.path == meetingsA.path && model.store.root.path == meetingsA.path,
          "T9 move: a queued meeting in the current folder refuses the move, in those words, and nothing changes")
    try! model.store.update(waiting) { $0.state = .done }
    // recordings the recorder never finished, one failed and one never processed: nothing would finish
    // them, here or anywhere else, so they do not hold the move up
    let cutFailed = make(meetingsA, "2026-10-29_0900", files: ["mic.caf": "x"])
    try! model.store.update(cutFailed) { $0.state = .failed; $0.error = Session.interrupted }
    let cutNever = make(meetingsA, "2026-10-28_0900", files: ["call.caf": "x"])
    model.clearFolderProblem()
    model.setMeetingsFolder(meetingsB)
    check(settle { prefs.meetingsFolder.path == meetingsB.path } && model.folderProblem == nil && model.store.root.path == meetingsB.path,
          "T9 move: with nothing in progress the folder moves, past recordings never finished, failed or never processed")
    check(MeetingFolder.recordingUnfinished(cutFailed) && MeetingFolder.recordingUnfinished(cutNever) && stateOf(cutFailed) == "failed" && stateOf(cutNever) == nil,
          "T9 move: and those recordings are left exactly as they were")
    check(settle { model.library.meetings.map(\.folder.url.lastPathComponent) == ["2026-11-03_0900", "2026-11-02_0900"] },
          "T9 folder: the library reads the new folder at once")
    // a valid choice whose read of the folder is still running is overtaken by a later choice that is refused
    model.setMeetingsFolder(meetingsA)
    model.setMeetingsFolder(meetingsB.appendingPathComponent("2026-11-03_0900/notes.md"))
    check(model.folderProblem == "meetingbox cannot use that folder" && prefs.meetingsFolder.path == meetingsB.path && model.store.root.path == meetingsB.path,
          "T9 folder: one meetingbox cannot use is refused, in those words, and nothing moves")
    _ = settle({ false }, timeout: 1)
    check(model.folderProblem == "meetingbox cannot use that folder" && prefs.meetingsFolder.path == meetingsB.path && model.store.root.path == meetingsB.path,
          "T9 move: an earlier choice still being checked never lands after a later refused one")

    // the next recording: the microphone and the folder chosen
    model.perform(.start)
    check(settle { model.session.phase.folder != nil }, "T9 app: Start records")
    let pid = rec.nextPid
    let recording = model.session.phase.folder ?? meetingsB
    check(rec.launches.count == 1 && rec.launches[0].mic == "USB Mic" && rec.launches[0].dir.deletingLastPathComponent().path == meetingsB.path,
          "T9 app: the next recording uses the microphone and the folder chosen")
    model.setMeetingsFolder(meetingsA)
    check(model.folderProblem == PreferencesPresentation.folderBusy && prefs.meetingsFolder.path == meetingsB.path && model.store.root.path == meetingsB.path,
          "T9 folder: not while a recording is running")

    // Stop and quit: Stop through the one path, then the answer once the session is idle again
    var replied = false
    model.stopForQuit { replied = true }
    check(settle { rec.sent(SIGINT) == 1 } && !replied && model.session.phase == .finalising(recording),
          "T9 quit: Stop and quit sends Stop through the one path, and waits while it finalises")
    rec.exit(pid, 0, verifies: true)
    check(settle { replied }, "T9 quit: and answers once the recording is finished")
    check(model.session.phase == .idle && rec.signals.count == 1 && rec.signals[0].pid == pid && ["queued", "processing"].contains(stateOf(recording) ?? "-"),
          "T9 quit: finished and queued, and Stop was the only signal")

    // while the finished recording is processed the folder stays; once it is done the move takes up
    // what is waiting in the new folder by itself (nothing here calls resume or adopt)
    check(settle { runner.calls.count == 1 }, "T9 folder: the finished recording is being processed")
    let meetingsC = root.appendingPathComponent("C", isDirectory: true)
    try! fm.createDirectory(at: meetingsC, withIntermediateDirectories: true)
    _ = make(meetingsC, "2026-10-31_0900", files: ["notes.md": "c"])
    let queuedC = make(meetingsC, "2026-10-28_0900", files: ["audio.m4a": "a"])
    try! model.store.update(queuedC) { $0.state = .queued }
    let orphan = make(meetingsC, "2026-11-04_0900")
    try! model.store.update(orphan) { $0.state = .recording }
    model.clearFolderProblem()
    model.setMeetingsFolder(meetingsC)
    check(settle { model.folderProblem == stillFinishing } && prefs.meetingsFolder.path == meetingsB.path && model.store.root.path == meetingsB.path,
          "T9 move: not while a meeting is being processed")
    runner.finish(0, 0)
    check(settle { stateOf(recording) == "done" }, "T9 folder: the job finishes in its own folder")
    model.clearFolderProblem()
    model.setMeetingsFolder(meetingsC)
    check(settle { prefs.meetingsFolder.path == meetingsC.path } && model.folderProblem == nil && model.store.root.path == meetingsC.path,
          "T9 move: once it is done, the folder moves")
    check(settle { runner.calls.count == 2 } && runner.calls[1].audio.deletingLastPathComponent().lastPathComponent == "2026-10-28_0900",
          "T9 move: the move itself takes up a meeting left queued in the new folder")
    check(settle { rec.recovered.map(\.lastPathComponent) == ["2026-11-04_0900"] && ["queued", "processing"].contains(stateOf(orphan) ?? "-") },
          "T9 move: and recovers a recording left interrupted there")
    check(settle { model.library.meetings.map(\.folder.url.lastPathComponent) == ["2026-11-04_0900", "2026-10-31_0900", "2026-10-28_0900"] },
          "T9 move: the library is on the new folder")
    watch.cancel()
    model.shutDown()

    // the Dock menu, the main menu's Recording menu, New meeting, and Stop and quit when idle or paused,
    // on a model of its own
    let state3 = shortTemp()
    let prefs3 = Preferences(defaults: testDefaults(), home: root)
    prefs3.meetingsFolder = meetingsA
    prefs3.sounds = false
    let rec3 = FakeRecorder()
    let m3 = AppModel(stateDir: state3, preferences: prefs3, recorder: rec3, runner: FakeRunner(), freeBytes: { _ in 50 * GB })
    m3.launch()
    var idleReplied = false
    m3.stopForQuit { idleReplied = true }
    check(settle { idleReplied } && rec3.signals.isEmpty && rec3.launches.isEmpty && m3.session.phase == .idle,
          "T9 quit: Stop and quit with nothing recording answers at once and sends nothing")
    let menus = RecordingMenu(model: m3)
    /// The Dock asks for a fresh menu each time it opens; the main menu's Recording menu is kept up to date.
    @MainActor func dockTitles() -> [String] { menus.dockMenu().items.map(\.title) }
    @MainActor func mainTitles() -> [String] { menus.menu.items.map(\.title) }
    /// Chooses an item as AppKit does: its action, sent to its target.
    @MainActor func choose(_ menu: NSMenu, _ title: String) {
        guard let item = menu.items.first(where: { $0.title == title }) else { return }
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }
    @MainActor func paused() -> Bool { if case .paused = m3.session.phase { return true }; return false }
    @MainActor func recordingNow() -> Bool { if case .recording = m3.session.phase { return true }; return false }
    /// Both menus offer exactly these, and New meeting is enabled only with Start recording among them.
    @MainActor func offers(_ titles: [String]) -> Bool {
        dockTitles() == titles && mainTitles() == titles && m3.canStartNewMeeting == titles.contains("Start recording")
    }
    check(offers(["Start recording"]), "T9 recording entries: idle: the Dock and Recording menus offer Start recording, and New meeting is enabled")
    m3.newMeeting()
    check(settle { recordingNow() } && rec3.launches.count == 1, "T9 new meeting: it starts a recording through the one path")
    check(settle { offers(["Pause", "Stop"]) }, "T9 recording entries: recording: both menus offer Pause and Stop, and New meeting is disabled")
    m3.newMeeting()
    _ = settle({ false }, timeout: 0.3)
    check(rec3.launches.count == 1 && recordingNow(), "T9 new meeting: while recording it starts nothing")
    choose(menus.dockMenu(), "Pause")
    check(settle { paused() } && rec3.sent(SIGUSR1) == 1, "T9 dock menu: Pause pauses, through the one path")
    check(settle { offers(["Resume", "Stop"]) }, "T9 recording entries: paused: both menus offer Resume and Stop, and New meeting is disabled")
    choose(menus.menu, "Resume")
    check(settle { recordingNow() } && rec3.sent(SIGUSR2) == 1, "T9 recording menu: Resume resumes, through the one path")
    check(settle { offers(["Pause", "Stop"]) }, "T9 recording entries: recording again: both menus follow, with no tick or choice needed")
    choose(menus.menu, "Pause")
    check(settle { paused() } && rec3.sent(SIGUSR1) == 2, "T9 recording menu: Pause pauses again")
    // Stop and quit while paused; an idle delivered late, as for an earlier recording, does not answer for this one
    let pid3 = rec3.nextPid
    let folder3 = m3.session.phase.folder ?? meetingsA
    var pausedReplied = false
    m3.stopForQuit { pausedReplied = true }
    check(settle { rec3.sent(SIGINT) == 1 } && !pausedReplied && m3.session.phase == .finalising(folder3),
          "T9 quit: Stop and quit while paused sends Stop and waits while it finalises")
    check(settle { offers(["Saving the last recording…"]) } && menus.dockMenu().items.allSatisfy { !$0.isEnabled }
          && menus.menu.items.allSatisfy { !$0.isEnabled } && m3.newMeetingTitle == "Saving the last recording…",
          "B1: finalising: both menus show Saving the last recording…, disabled, and New meeting says so, disabled")
    m3.session.onChange?(.idle)
    _ = settle({ false }, timeout: 0.3)
    check(!pausedReplied, "T9 quit: an idle delivered late, while this recording finalises, does not answer")
    rec3.exit(pid3, 0, verifies: true)
    check(settle { pausedReplied } && m3.session.phase == .idle, "T9 quit: it answers once the paused recording is finished")
    check(settle { offers(["Start recording"]) }, "T9 recording entries: idle again: Start recording, and New meeting is enabled")
    choose(menus.dockMenu(), "Start recording")
    check(settle { recordingNow() } && rec3.launches.count == 2, "T9 dock menu: Start recording starts a recording, through the one path")
    check(settle { offers(["Pause", "Stop"]) }, "T9 recording entries: and both menus follow it")
    choose(menus.menu, "Stop")
    check(settle { rec3.sent(SIGINT) == 2 } && rec3.signals.last?.pid == rec3.nextPid, "T9 recording menu: Stop stops it, through the one path")
    rec3.exit(rec3.nextPid, 0, verifies: true)
    _ = settle { m3.session.phase == .idle }
    m3.shutDown()
    try? fm.removeItem(at: state3)

    // Keep recording and quit: nothing is sent to the recorder, by the quit, the shutdown or any deinit
    let state2 = shortTemp()
    let prefs2 = Preferences(defaults: testDefaults(), home: root)
    prefs2.meetingsFolder = meetingsB
    prefs2.sounds = false
    let rec2 = FakeRecorder()
    let runner2 = FakeRunner()
    weak var goneModel: AppModel?
    weak var goneSession: Session?
    var pid2: Int32 = 0
    var folder2: URL? = nil
    do {
        let m = AppModel(stateDir: state2, preferences: prefs2, recorder: rec2, runner: runner2, freeBytes: { _ in 50 * GB })
        m.launch()
        m.perform(.start)
        _ = settle { m.session.phase.folder != nil }
        _ = settle({ false }, timeout: 2.6) // the start's grace passes, so nothing of it is left waiting
        folder2 = m.session.phase.folder
        pid2 = rec2.nextPid
        // Keep recording and quit sends nothing ("T9 quit: Keep recording and quit quits at once and
        // touches nothing"); what is left to prove is that the shutdown and the deinits send nothing either.
        m.shutDown() // what applicationWillTerminate does
        goneModel = m
        goneSession = m.session
    }
    check(settle { goneModel == nil && goneSession == nil }, "T9 keep: the model and its session are let go, so their deinits have run")
    check(folder2 != nil && rec2.signals.isEmpty && rec2.alive.contains(pid2),
          "T9 keep: shutDown and the model's and session's deinits sent the recorder nothing; it is still recording")
    check((try? String(contentsOf: state2.appendingPathComponent("recording.dir"), encoding: .utf8)) == folder2?.path
          && folder2.flatMap(stateOf) == "recording" && !fm.fileExists(atPath: state2.appendingPathComponent("control.sock").path),
          "T9 keep: recording.dir and meeting.json still say recording; only the socket has gone")
    let next = AppModel(stateDir: state2, preferences: prefs2, recorder: rec2, runner: runner2, freeBytes: { _ in 50 * GB })
    next.launch()
    check(folder2.map { next.session.phase == .recording($0) } == true && rec2.launches.count == 1,
          "T9 keep: the next launch adopts the recording, starting nothing new")
    next.perform(.stop)
    check(settle { rec2.sent(SIGINT) == 1 } && rec2.signals.first?.pid == pid2, "T9 keep: and its Stop reaches the same recorder")
    next.shutDown()
    try? fm.removeItem(at: state)
    try? fm.removeItem(at: state2)
}

// MARK: - Which build this is (Task 10, item 12)

do {
    let hash = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809"
    let full: [String: Any] = ["CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "202611051430",
                               "MBSourceHash": hash, "MBCommit": "9602459"]
    check(BuildInfo(full)?.line == "meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4, 9602459)",
          "T10 build: version, build time, the first 7 of the source hash and the commit, in one line")
    var noCommit = full
    noCommit["MBCommit"] = nil
    check(BuildInfo(noCommit)?.line == "meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4)",
          "T10 build: no commit (not a git checkout), no commit in the line")
    var emptyCommit = full
    emptyCommit["MBCommit"] = ""
    check(BuildInfo(emptyCommit)?.line == "meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4)", "T10 build: an empty commit is no commit")
    // A build from before builds were stamped: the version alone, as `meetingbox version` gives it.
    check(BuildInfo(["CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "2.0.0"])?.line == "meetingbox 2.0.0",
          "T10 build: a version number in place of the build time gives the version alone")
    var noHash = full
    noHash["MBSourceHash"] = nil
    check(BuildInfo(noHash)?.line == "meetingbox 2.0.0", "T10 build: no source hash gives the version alone")
    var shortHash = full
    shortHash["MBSourceHash"] = "1a2b3c"
    check(BuildInfo(shortHash)?.line == "meetingbox 2.0.0", "T10 build: a source hash shorter than 7 gives the version alone")
    var badBuild = full
    badBuild["CFBundleVersion"] = "2026110514301"
    check(BuildInfo(badBuild)?.line == "meetingbox 2.0.0", "T10 build: a build time that is not 12 digits gives the version alone")
    check(BuildInfo(["CFBundleVersion": "202611051430", "MBSourceHash": hash]) == nil, "T10 build: no version, no line")
    check(BuildInfo(nil) == nil, "T10 build: no Info.plist, no line")

    // The menu bar item's menu: the line last, disabled, after a separator; nothing without one.
    let menu = StatusPresentation(StatusInput()).menu
    let withLine = StatusPresentation.withBuild(menu, "meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4)")
    check(withLine.count == menu.count + 2 && Array(withLine.prefix(menu.count)) == menu
          && withLine[menu.count] == MenuEntry(title: "", enabled: false, action: .separator)
          && withLine.last == MenuEntry(title: "meetingbox 2.0.0 (build 2026-11-05 14:30, 1a2b3c4)", enabled: false, action: .info),
          "T10 build: the menu bar item's menu ends with the build line, disabled, after a separator")
    check(StatusPresentation.withBuild(menu, nil) == menu, "T10 build: no build line, the menu as it was")
}

// MARK: - Final fix round, part 2: the session, status and control

let stillSavingReply = "error the last recording is still being saved, so nothing new was started. Try again in a moment"

// B1: while the last recording is being saved, start and toggle are refused and launch nothing; stop
// still answers ok finalising; each refusal is announced, for the app's failure sound.
do {
    check(Session.stillSaving == String(stillSavingReply.dropFirst("error ".count)), "B1: the refusal's words")
    let (r, h, _) = handlerRig()
    var started = 0, stopped = 0, refused = 0
    h.onStarted = { _ in started += 1 }
    h.onStopped = { _ in stopped += 1 }
    h.onRefused = { refused += 1 }
    _ = h.reply(for: .start(mic: nil, dir: nil))
    let dir = r.session.phase.folder ?? r.store.root
    check(h.reply(for: .stop) == "ok finalising \(dir.path)", "B1: stop moves to finalising")
    let folders = names(r.store.root)
    let elsewhere = freshRoot()
    check(h.reply(for: .start(mic: nil, dir: nil)) == stillSavingReply, "B1: start while saving is refused in those words")
    check(h.reply(for: .start(mic: "USB", dir: elsewhere.path)) == stillSavingReply && names(elsewhere).isEmpty,
          "B1: and with a folder and a microphone of its own, making nothing there")
    check(h.reply(for: .toggle(mic: nil, dir: nil)) == stillSavingReply, "B1: toggle while saving is refused in the same words")
    check(r.rec.launches.count == 1 && names(r.store.root) == folders && r.rec.sent(SIGINT) == 1 && r.session.phase == .finalising(dir),
          "B1: toggle (or start) while saving neither stops nor starts anything")
    check(started == 1 && stopped == 1 && refused == 3, "B1: no start or stop sound for them; each refusal is announced (\(refused))")
    check(h.reply(for: .stop) == "ok finalising \(dir.path)" && stopped == 1 && refused == 3, "B1: stop while saving still answers ok finalising, and is not a refusal")
    check(h.reply(for: .pause) == "error the recording in \(dir.path) has already stopped" && refused == 3, "B1: pause while saving is not a refusal either")
    check(errorText { _ = try r.session.start(root: r.store.root, mic: nil) } == Session.stillSaving && r.rec.launches.count == 1,
          "B1: Session.start while finalising throws the same words and launches nothing")
    r.rec.exit(r.rec.nextPid, 0, verifies: true)
    r.at(1)
    check(r.session.phase == .idle && h.reply(for: .start(mic: nil, dir: nil)).hasPrefix("ok recording ") && r.rec.launches.count == 2 && refused == 3,
          "B1: once it is saved, a start records again")
}

// N4: a start over the socket that another client stops inside the grace (a double-pressed hotkey) is
// answered as stopped, not as a start that failed.
do {
    let tmp = shortTemp()
    defer { try? fm.removeItem(at: tmp) }
    let q = DispatchQueue(label: "meetingbox.test.n4")
    let (r, h, _) = handlerRig(tickQueue: q)
    var started = 0
    h.onStarted = { _ in started += 1 }
    let sock = tmp.appendingPathComponent("control.sock")
    let server = try? ControlServer(socket: sock, handler: h)
    server?.start()
    let lock = NSLock()
    var first: String?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let reply = ControlClient.send("toggle", to: sock, timeout: 20)
        lock.lock(); first = reply; lock.unlock()
        done.signal()
    }
    var dir: URL?
    for _ in 0..<100 where dir == nil {
        usleep(20_000)
        dir = q.sync { r.session.phase.folder }
    }
    let second = ControlClient.send("toggle", to: sock, timeout: 20)
    check(dir != nil && second == "ok finalising \(dir?.path ?? "-")", "N4: a second toggle inside the grace stops the recording (\(second ?? "nil"))")
    let answered = done.wait(timeout: .now() + 20) == .success
    lock.lock(); let firstReply = first; lock.unlock()
    check(answered && firstReply == "ok finalising \(dir?.path ?? "-")" && q.sync { started } == 0,
          "N4: the first is answered ok finalising, not as a failed start, with no start sound (\(firstReply ?? "nil"))")
    server?.stop()
    q.sync {
        r.rec.exit(r.rec.nextPid, 0, verifies: true)
        r.session.tick()
    }
    q.sync {}
}

// Residual: every request on the socket reaches the app once, on the handler's queue, with the line
// the client reads, after the start wait; a toggle as the start or the stop it became.
do {
    let tmp = shortTemp()
    defer { try? fm.removeItem(at: tmp) }
    let q = DispatchQueue(label: "meetingbox.test.answered")
    let onQ = DispatchSpecificKey<Bool>()
    q.setSpecific(key: onQ, value: true)
    let (r, h, _) = handlerRig(tickQueue: q)
    var told: [(request: ControlRequest, reply: String)] = []
    var offQueue = 0
    h.onAnswered = { request, reply in
        if DispatchQueue.getSpecific(key: onQ) != true { offQueue += 1 }
        told.append((request, reply))
    }
    let sock = tmp.appendingPathComponent("control.sock")
    let server = try? ControlServer(socket: sock, handler: h)
    server?.start()
    func last() -> (count: Int, request: ControlRequest?, reply: String?) { q.sync { (told.count, told.last?.request, told.last?.reply) } }

    // (d) status
    let idle = ControlClient.send("status", to: sock)
    let d = last()
    check(idle == "ok idle -" && d.count == 1 && d.request == .status && d.reply == "ok idle -"
          && Failure.shown(.status, reply: "ok idle -", phase: .idle, overSocket: true) == nil,
          "answered: status is told once, with ok idle -, and nothing is shown (\(d))")

    // (a) a toggle while idle whose start throws at once (less than 2 GB free), with its own mic and dir
    let elsewhere = tmp.appendingPathComponent("Elsewhere").path
    q.sync { r.free = 1 * GB }
    let full = ControlClient.send("toggle mic=USB dir=\(elsewhere)", to: sock, timeout: 15)
    let a = last()
    check(full == "error not enough free disk space to record (2 GB needed)" && a.count == 2
          && a.request == .start(mic: "USB", dir: elsewhere) && a.reply == full,
          "answered: a toggle while idle whose start throws is told once, as the start with its mic and dir, with the line the client read (\(a))")
    q.sync { r.free = 50 * GB }

    // (c) a toggle whose recorder dies inside the grace: told once, after the wait, with its reason
    q.sync {
        r.rec.recoverResult = false
        r.rec.dieOnLaunch = (1, "No input device matching \"USB\"")
    }
    let died = ControlClient.send("toggle", to: sock, timeout: 20)
    let c = last()
    check(died == "error No input device matching \"USB\"" && c.count == 3 && c.request == .start(mic: nil, dir: nil) && c.reply == died
          && q.sync { r.rec.launches.count } == 1,
          "answered: a toggle whose recorder dies inside the grace is told once, as the start, with the error after the wait (\(c))")
    q.sync { r.rec.dieOnLaunch = nil }

    // (b) a toggle while recording; reply(for:) tells nothing
    let before = last().count
    let recording = q.sync { h.reply(for: .start(mic: nil, dir: nil)) }
    let dir = q.sync { r.session.phase.folder }
    check(dir != nil && recording == "ok recording \(dir!.path)" && last().count == before, "answered: reply(for:) never tells onAnswered")
    let stopped = ControlClient.send("toggle", to: sock, timeout: 15)
    let b = last()
    check(dir != nil && stopped == "ok finalising \(dir!.path)" && b.count == 4 && b.request == .stop && b.reply == stopped,
          "answered: a toggle while recording is told once, as the stop, with ok finalising <dir> (\(b))")

    // a toggle while the last recording is saved is a start, refused
    let refused = ControlClient.send("toggle mic=USB", to: sock, timeout: 15)
    let e = last()
    check(refused == "error " + Session.stillSaving && e.count == 5 && e.request == .start(mic: "USB", dir: nil) && e.reply == refused,
          "answered: a toggle while saving is told once, as the start it was refused as (\(e))")
    check(q.sync { offQueue } == 0, "answered: always on the handler's queue")
    server?.stop()
    q.sync {
        r.rec.exit(r.rec.nextPid, 0, verifies: true)
        r.session.tick()
    }
    q.sync {}
}

// B2: an end nobody asked for is announced with its reason, and the reason is kept in meeting.json
// (stopReason) through queued, processing and done.
func stopReason(_ r: Rig, _ dir: URL) -> String? { r.json(dir)["stopReason"] as? String }
/// Takes a queued meeting through the queue to done, over the rig's store.
func processToDone(_ r: Rig, _ dir: URL) -> (processing: String?, done: String?) {
    let runner = FakeRunner()
    let q = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil)
    q.enqueue(dir)
    let whileProcessing = r.stateOf(dir) == "processing" ? stopReason(r, dir) : "not processing"
    if !runner.calls.isEmpty { runner.finish(0, 0) }
    return (whileProcessing, r.stateOf(dir) == "done" ? stopReason(r, dir) : "not done")
}
do {
    let r = Rig()
    let s = r.make()
    var ended: [(URL, String)] = []
    s.onEnded = { ended.append(($0, $1)) }
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(20)
    check(Session.recorderStopped == "the recorder stopped unexpectedly", "B2: the words for a recorder that stopped")
    check(ended.count == 1 && ended[0].0 == dir && ended[0].1 == Session.recorderStopped, "B2: a recorder that stops on its own is announced, with why")
    check(r.stateOf(dir) == "queued" && stopReason(r, dir) == Session.recorderStopped && r.json(dir)["error"] == nil,
          "B2: its reason is in meeting.json as stopReason, and queued keeps it")
    let after = processToDone(r, dir)
    check(after.processing == Session.recorderStopped && after.done == Session.recorderStopped, "B2: processing and done keep it (\(after))")
}
do {
    let r = Rig()
    let s = r.make()
    var ended: [(URL, String)] = []
    s.onEnded = { ended.append(($0, $1)) }
    let dir = try! s.start(root: r.store.root, mic: nil)
    r.free = 199 * MB
    r.at(30)
    // 8(a): the reason does not say "recording stopped" again; the error keeps its own words.
    let bare = "the disk was nearly full, so that it could be finished"
    check(Session.diskStopReason == bare && StatusPresentation.recordingStopped(Session.diskStopReason) == "Recording stopped: \(bare)",
          "8(a): the disk stop's reason is bare, so the line reads Recording stopped: the disk was nearly full…")
    check(ended.count == 1 && ended[0].0 == dir && ended[0].1 == bare && stopReason(r, dir) == bare && r.json(dir)["error"] as? String == Session.diskStopped,
          "B2: the disk stop is announced with its reason, and the reason is kept (\(ended.map(\.1)))")
    r.rec.exit(r.rec.nextPid, 0, verifies: true)
    r.at(31)
    check(ended.count == 1 && r.stateOf(dir) == "queued" && stopReason(r, dir) == bare && r.json(dir)["error"] == nil,
          "B2: once queued the reason stays (the error goes), and it is announced once")
    let after = processToDone(r, dir)
    check(after.processing == bare && after.done == bare, "B2: through processing and done (\(after))")
}
do {
    // an adopted recorder that stops is announced however long ago it started
    let r = Rig()
    let dir = r.meeting("2026-10-29_0955") { $0.started = r.clock.base.addingTimeInterval(-300); $0.state = .recording }
    r.writeState(dir)
    r.rec.alive.insert(4242)
    r.rec.running[dir.path] = 4242
    let s = r.make()
    var ended: [(URL, String)] = []
    s.onEnded = { ended.append(($0, $1)) }
    s.adopt()
    r.rec.exit(4242, 1, verifies: false)
    r.rec.exitCodes[4242] = nil
    r.at(1)
    check(ended.count == 1 && ended[0].0 == dir && stopReason(r, dir) == Session.recorderStopped, "B2: an adopted recorder that stops is announced")
}
do {
    // nothing is announced for a stop the user asked for, nor for a start whose recorder died at once
    let r = Rig()
    let s = r.make()
    var ended: [(URL, String)] = []
    s.onEnded = { ended.append(($0, $1)) }
    let asked = try! s.start(root: r.store.root, mic: nil)
    r.clock.t = 30
    _ = s.stop()
    r.rec.exit(r.rec.nextPid, 0, verifies: true)
    r.at(31)
    check(ended.isEmpty && stopReason(r, asked) == nil && r.stateOf(asked) == "queued", "B2: a stop that was asked for is not announced, and has no stopReason")
    r.clock.t = 100
    let failedStart = try! s.start(root: r.store.root, mic: nil)
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(101)
    check(ended.isEmpty && stopReason(r, failedStart) == nil,
          "B2: a recorder that dies inside the start grace is a failed start, which the start's reply reports, not an end")
    r.clock.t = 200
    let late = try! s.start(root: r.store.root, mic: nil)
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(200 + Session.startGrace)
    check(ended.count == 1 && ended[0].0 == late && ControlHandler.startGrace == Session.startGrace,
          "B2: one that dies once the grace is over is announced; the grace is the handler's")
}

// A3: a recovery that finds the folder busy leaves the meeting finalising and the session idle, and the
// tick alone tries it again, no sooner than 15 s after each busy result, until it settles.
do {
    // the stop path
    let r = Rig()
    r.rec.recoverBusy = true
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    _ = s.stop()
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(1)
    check(r.rec.recovered == [dir] && r.stateOf(dir) == "finalising" && s.phase == .idle && r.finished.isEmpty,
          "A3: stop path, busy: meeting.json still says finalising, and the session is idle")
    r.at(15)
    check(r.rec.recovered.count == 1, "A3: not tried again sooner than 15 s after")
    r.at(16)
    check(r.rec.recovered.count == 2 && r.stateOf(dir) == "finalising" && r.finished.isEmpty, "A3: tried again at 15 s; still busy, still finalising")
    r.rec.recoverBusy = false // the other holder lets go
    r.at(30)
    check(r.rec.recovered.count == 2, "A3: the next try waits 15 s from the last busy result")
    r.at(31)
    check(r.rec.recovered.count == 3 && r.stateOf(dir) == "queued" && r.finished.count == 1 && r.finished[0].0 == dir && r.finished[0].1,
          "A3: once it is free, ticks alone take it to queued")
    r.at(60)
    check(r.rec.recovered.count == 3, "A3: and nothing more once it has settled")
}
do {
    // the orphan path, while a new recording runs
    let r = Rig()
    r.rec.recoverBusy = true
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .finalising }
    let s = r.make()
    s.adopt()
    check(r.rec.recovered == [orphan] && r.stateOf(orphan) == "finalising" && s.phase == .idle && r.finished.isEmpty,
          "A3: orphan path, busy: still finalising, idle")
    let dir = try? s.start(root: r.store.root, mic: nil)
    check(dir != nil && s.phase == .recording(dir!), "A3: a new recording can start meanwhile")
    r.rec.recoverBusy = false
    r.at(14)
    check(r.rec.recovered.count == 1, "A3: not before 15 s")
    r.at(15)
    check(r.rec.recovered.count == 2 && r.stateOf(orphan) == "queued" && r.finished.count == 1 && r.finished[0].0 == orphan
          && dir.map { s.phase == .recording($0) } == true, "A3: the tick takes the orphan to queued while the new recording goes on")
}
do {
    // a folder that has gone, or that something else has settled, is not tried again
    let r = Rig()
    r.rec.recoverBusy = true
    let gone = r.meeting("2026-10-28_0900") { $0.state = .finalising }
    let settled = r.meeting("2026-10-28_1000") { $0.state = .finalising }
    let s = r.make()
    s.adopt()
    check(r.rec.recovered.count == 2, "A3: two busy orphans")
    try! fm.removeItem(at: gone)
    try! r.store.update(settled) { $0.state = .done }
    r.rec.recoverBusy = false
    r.at(15)
    check(r.rec.recovered.count == 2 && r.finished.isEmpty && !fm.fileExists(atPath: gone.path) && r.stateOf(settled) == "done",
          "A3: neither is recovered again, and nothing is written")
}
do {
    // the session's own 1 s timer runs the retry, with nothing recording
    let q = DispatchQueue(label: "meetingbox.test.a3")
    let r = Rig()
    r.rec.recoverBusy = true
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .finalising }
    q.sync {
        let s = r.make(tickQueue: q)
        s.adopt()
        r.rec.recoverBusy = false
        r.clock.t = 15
    }
    var queuedNow = false
    for _ in 0..<80 where !queuedNow {
        usleep(50_000)
        queuedNow = q.sync { r.stateOf(orphan) == "queued" }
    }
    check(queuedNow && q.sync { r.rec.recovered.count } == 2, "A3: the session's timer keeps running for the retry, and takes it to queued")
    q.sync {}
}

// B3 with B2: one line about a meeting, the most recent of minutes ready, recording stopped and
// unfinished. It opens that meeting, and goes when that meeting is opened or the next recording starts.
do {
    let tail = ["-", "Open meetingbox", "(Preferences…)", "-", "Quit meetingbox"]
    let notWritten = "Minutes could not be written: processing failed (exit 1)"
    let stopped = "Recording stopped: the recorder stopped unexpectedly"
    check(StatusPresentation.minutesNotWritten("processing failed (exit 1)") == notWritten
          && StatusPresentation.recordingNotFinished == "The recording could not be finished; its files are kept", "B3: the words")

    // the review's case: A's minutes are ready, then B's job fails
    var s = StatusInput()
    s.apply(.minutesReady(meetingA))
    check(s.notice == Notice(kind: .minutesReady, folder: meetingA, line: "Minutes ready") && s.ready == meetingA, "B3: A's minutes ready")
    s.apply(.unfinished(meetingB, line: notWritten))
    check(s.notice == Notice(kind: .unfinished, folder: meetingB, line: notWritten) && s.ready == nil, "B3: then B's job fails: one line, and it is B's")
    let p = StatusPresentation(s)
    check(lines(p) == [notWritten, "-", "Start recording"] + tail && action(notWritten, in: p) == .openMinutes(meetingB),
          "B3: the menu line names the failure and opens B, not A (\(lines(p)))")
    check(p.button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "", help: notWritten), "B3: with the amber icon")
    s.apply(.minutesOpened(meetingA))
    check(s.notice?.folder == meetingB, "B3: opening A leaves B's line")
    s.apply(.minutesOpened(meetingB))
    check(s.notice == nil && StatusPresentation(s).button.symbol == "record.circle", "B3: opening B clears it")

    // recording stopped, then the most recent wins
    s.apply(.recordingStopped(meetingA, reason: "the recorder stopped unexpectedly"))
    check(s.notice == Notice(kind: .recordingStopped, folder: meetingA, line: stopped), "B2: Recording stopped: <reason>")
    let q = StatusPresentation(s)
    check(q.button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "", help: stopped)
          && action(stopped, in: q) == .openMinutes(meetingA), "B2: amber, and the line opens that meeting")
    s.apply(.unfinished(meetingA, line: StatusPresentation.recordingNotFinished))
    check(s.notice?.line == StatusPresentation.recordingNotFinished, "B3: a recording that could not be finished replaces it")
    s.apply(.minutesReady(meetingB))
    check(s.notice == Notice(kind: .minutesReady, folder: meetingB, line: "Minutes ready") && StatusPresentation(s).button.tint == .plain,
          "B3: minutes ready after it wins, and is not amber")

    // the next recording clears it; a pause taken up, or resumed, does not
    s.apply(.unfinished(meetingB, line: notWritten))
    s.apply(.phase(.paused(meetingA)))
    check(s.notice?.line == notWritten, "B3: a recording taken up as paused does not clear it")
    s.apply(.phase(.idle))
    s.apply(.phase(.recording(meetingA)))
    check(s.notice == nil, "B3: the next recording starting clears it")
    s.apply(.unfinished(meetingB, line: notWritten))
    s.apply(.phase(.paused(meetingA)))
    s.apply(.phase(.recording(meetingA)))
    check(s.notice?.line == notWritten, "B3: resuming does not")

    // shown while a new recording goes on: the line is in the menu, and the icon stays the recording's (8(b))
    let live = present(.recording(meetingA), seconds: 7, notice: Notice(kind: .unfinished, folder: meetingB, line: notWritten))
    check(live.button == StatusButton(symbol: "circle.fill", tint: .red, title: "00:07", help: "Recording")
          && lines(live) == ["(Microphone: capturing)", "(System audio: capturing)", notWritten, "-", "Pause", "Stop", "Show recording folder"] + tail,
          "B3, 8(b): during a recording the line is in the menu and the recording keeps the icon and the timer (\(lines(live)))")
    // a failed start still wins the icon, and both lines are in the menu
    let both = present(notice: Notice(kind: .unfinished, folder: meetingB, line: notWritten), failure: Failure("start", "x"))
    check(both.button.help == "Could not start: x" && lines(both) == ["(Could not start: x)", notWritten, "-", "Start recording"] + tail,
          "B3: a failed start comes first, then the line")
    // while busy, an amber line wins the icon; minutes ready does not
    check(present(processing: meetingA, stage: "transcribing", notice: Notice(kind: .recordingStopped, folder: meetingB, line: stopped)).button.symbol == "exclamationmark.triangle"
          && present(processing: meetingA, stage: "transcribing", ready: meetingB).button.title == "Transcribing",
          "B3: an amber line wins over busy, minutes ready does not")
}

// 9(d) with C7 and D2: recovery's last line is the reason a recording could not be finished, and a failed
// recording that was never finished says how to finish it.
let tooFull = "the disk is too full to finish the recording; free some space, then run: meetingbox recover /Meetings/x"
do {
    let bin = freshRoot()
    func script(_ name: String, _ body: String) -> URL {
        let url = bin.appendingPathComponent(name)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
    func newDir() -> URL { try! MeetingFolder.create(in: freshRoot(), at: Date()) }
    let says = script("says/meetingbox-recorder", "echo 'checking' >&2; echo '\(tooFull)' >&2; echo '' >&2; exit 1")
    let dir = newDir()
    try! "No input device matching \"USB\"\n".write(to: dir.appendingPathComponent("capture.log"), atomically: true, encoding: .utf8)
    check(ChildRecorder(executable: says, legacyExecutable: says).recover(dir: dir) == .failed(tooFull),
          "9(d): a failed --recover gives the last line it printed")
    let silent = script("silent/meetingbox-recorder", "exit 1")
    check(ChildRecorder(executable: silent, legacyExecutable: silent).recover(dir: dir) == .failed(nil),
          "9(d): one that printed nothing gives no line, never an earlier line of capture.log")
    let legacySilent = script("legacy/meetingbox", "exit 1")
    check(ChildRecorder(executable: bin.appendingPathComponent("no-such/meetingbox-recorder"), legacyExecutable: legacySilent).recover(dir: newDir()) == .failed(nil),
          "9(d): nor the note that the helper is missing")
}
do {
    // the stop path: recovery's line when the recorder gave none of its own
    let r = Rig()
    r.rec.recoverResult = false
    r.rec.recoverSays = tooFull
    let s = r.make()
    let dir = try! s.start(root: r.store.root, mic: nil)
    _ = s.stop()
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(1)
    check(r.stateOf(dir) == "failed" && r.json(dir)["error"] as? String == tooFull, "9(d): a stop whose recovery is refused for room says to free space")
    // the recorder's own reason still comes first
    let dir2 = try! s.start(root: r.store.root, mic: nil)
    r.log(dir2, "No input device matching \"USB\"")
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(10)
    check(r.json(dir2)["error"] as? String == "No input device matching \"USB\"", "9(d): the recorder's own reason still wins")
    // the disk stop keeps its words and adds recovery's
    r.clock.t = 100
    let dir3 = try! s.start(root: r.store.root, mic: nil)
    r.free = 199 * MB
    r.at(130)
    r.rec.exit(r.rec.nextPid, 1, verifies: false)
    r.at(131)
    check(r.json(dir3)["error"] as? String == "recording stopped because the disk was nearly full; \(tooFull)",
          "9(d): a disk stop that cannot be finished says both")
}
do {
    // the orphan path
    let r = Rig()
    r.rec.recoverResult = false
    r.rec.recoverSays = tooFull
    let orphan = r.meeting("2026-10-28_0900") { $0.state = .recording }
    let s = r.make()
    s.adopt()
    check(r.stateOf(orphan) == "failed" && r.json(orphan)["error"] as? String == tooFull, "9(d): an orphan's recovery line is its reason")
}
do {
    // the window: the failure line, then how to finish it; and why a recording stopped early
    func meeting(_ name: String, _ state: MeetingState, error: String? = nil, stopReason: String? = nil) -> Meeting {
        let m = libMeeting(name, state, error: error)
        var rec = m.record!
        rec.stopReason = stopReason
        return Meeting(folder: m.folder, record: rec, state: state)
    }
    func notes(_ m: Meeting, unfinished: Bool, phase: Session.Phase = .idle) -> [String] {
        LibraryPresentation.notes(for: m, row: LibraryPresentation.row(m, phase: phase), files: MeetingFiles(audio: nil, runnable: false, unfinished: unfinished))
    }
    let cut = meeting("2026-10-28_1508", .failed, error: tooFull)
    check(notes(cut, unfinished: true) == [tooFull, "To finish it, run: meetingbox recover /Meetings/2026-10-28_1508, then choose Process here."],
          "9(d): a failed recording that was never finished is followed by how to finish it")
    check(notes(cut, unfinished: false) == [tooFull], "9(d): one that is finished is not")
    check(notes(meeting("2026-10-28_1508", .unprocessed), unfinished: true).isEmpty, "9(d): nor one that has not failed")
    let titled = meeting("2026-10-28 1508 O'Brien review", .failed, error: Session.interrupted)
    check(notes(titled, unfinished: true).last == "To finish it, run: meetingbox recover '/Meetings/2026-10-28 1508 O'\\''Brien review', then choose Process here.",
          "9(d): a folder with spaces or quotes is quoted for the shell (\(notes(titled, unfinished: true).last ?? "nil"))")
    let early = meeting("2026-10-28_1600", .done, stopReason: Session.recorderStopped)
    check(notes(early, unfinished: false) == ["Recording stopped early: the recorder stopped unexpectedly"], "B2: the window says why a recording stopped early")
    let both = meeting("2026-10-28_1700", .failed, error: tooFull, stopReason: Session.diskStopReason)
    check(notes(both, unfinished: true) == [tooFull, "To finish it, run: meetingbox recover /Meetings/2026-10-28_1700, then choose Process here.",
                                            "Recording stopped early: the disk was nearly full, so that it could be finished"],
          "B2, 9(d), 8(a): all three, in that order, and the stop reason reads Recording stopped early: the disk was nearly full…")
    // what is on disk
    let root = freshRoot()
    let unfinishedFolder = MeetingFolder.parse(make(root, "2026-10-28_1800", files: ["mic.caf": "c"]))!
    let finishedFolder = MeetingFolder.parse(make(root, "2026-10-28_1810", files: ["audio.m4a": "a", Finaliser.marker: "", "mic.caf": "c"]))!
    check(MeetingFiles.read(unfinishedFolder).unfinished && !MeetingFiles.read(finishedFolder).unfinished,
          "9(d): the folder is read as unfinished only with working files and no marker")
}

// B1, B2 and B3 in the app: each failure is a menu bar line with the amber icon and Basso (only with
// sounds on); the stop reason stays in meeting.json through queued and done.
MainActor.assumeIsolated {
    func json(_ dir: URL) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meeting.json")))) as? [String: Any]) ?? [:]
    }
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = true
    prefs.openMinutes = false
    var played: [String] = []
    let rec = FakeRecorder()
    let runner = FakeRunner()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: runner, freeBytes: { _ in 50 * GB },
                         playSound: { played.append($0) })
    model.launch()

    // B2: a recording whose recorder stops on its own, after the start grace
    model.perform(.start)
    check(settle { model.session.phase.folder != nil }, "app B2: Start records")
    let first = model.session.phase.folder ?? root
    _ = settle({ false }, timeout: 2.6)
    check(played == ["Tink"], "app B2: the start sound once the grace is over (\(played))")
    rec.exit(rec.nextPid, 1, verifies: false)
    let stoppedLine = "Recording stopped: the recorder stopped unexpectedly"
    check(settle { model.status.notice?.kind == .recordingStopped }, "app B2: the end is announced")
    check(model.status.notice?.line == stoppedLine && isAt(model.status.notice?.folder, first)
          && model.presentation.button.tint == .amber
          && model.presentation.menu.contains { $0.title == stoppedLine && $0.action == model.status.notice.map { MenuAction.openMinutes($0.folder) } },
          "app B2: Recording stopped: <reason>, amber, and the line opens the meeting")
    check(played == ["Tink", "Basso"], "app B2: with Basso (\(played))")
    check(settle { runner.calls.count == 1 } && json(first)["stopReason"] as? String == Session.recorderStopped,
          "app B2: recovered and queued, with its stop reason")

    // B3: its job fails
    runner.finish(0, 1, "the transcript could not be made")
    let notWritten = "Minutes could not be written: the transcript could not be made"
    check(settle { model.status.notice?.kind == .unfinished }, "app B3: a failed job is announced")
    check(model.status.notice?.line == notWritten && isAt(model.status.notice?.folder, first) && model.presentation.button.tint == .amber
          && played == ["Tink", "Basso", "Basso"], "app B3: Minutes could not be written: <reason>, about that meeting, amber, Basso (\(played))")
    check(json(first)["stopReason"] as? String == Session.recorderStopped, "app B2: a failed job keeps the stop reason")
    model.queue.retry(first)
    check(settle { runner.calls.count == 2 }, "app B3: tried again")
    runner.finish(1, 0)
    check(settle { model.status.notice?.kind == .minutesReady } && played == ["Tink", "Basso", "Basso", "Glass"]
          && json(first)["state"] as? String == "done" && json(first)["stopReason"] as? String == Session.recorderStopped,
          "app B2: done keeps the stop reason, and Minutes ready replaces the line (\(played))")

    // B1: a start while the last recording is saved is refused with Basso, and the menus say so
    model.perform(.start)
    check(settle { model.session.phase.folder != nil && model.session.phase.folder != first }, "app B1: another recording")
    let second = model.session.phase.folder ?? root
    _ = settle({ false }, timeout: 2.6)
    model.perform(.stop)
    check(settle { model.session.phase == .finalising(second) && model.recordingEntries.first?.title == "Saving the last recording…" },
          "app B1: finalising: the recording entries say Saving the last recording…")
    check(model.recordingEntries == [MenuEntry(title: "Saving the last recording…", enabled: false, action: .start)] && !model.canStartNewMeeting
          && model.newMeetingTitle == "Saving the last recording…", "app B1: disabled, and New meeting says so, disabled")
    let launches = rec.launches.count
    model.perform(.start)
    check(settle { model.status.failure != nil } && model.status.failure == Failure("start", Session.stillSaving) && rec.launches.count == launches,
          "app B1: a start is refused in those words and launches nothing")
    check(settle { played == ["Tink", "Basso", "Basso", "Glass", "Tink", "Pop", "Basso"] }, "app B1: with Basso (\(played))")

    // B3: the recording cannot be finished
    rec.recoverResult = false
    rec.exit(rec.nextPid, 1, verifies: false)
    check(settle { model.status.notice?.kind == .unfinished && model.session.phase == .idle }, "app B3: a recording that could not be finished is announced")
    check(model.status.notice?.line == StatusPresentation.recordingNotFinished && isAt(model.status.notice?.folder, second)
          && played == ["Tink", "Basso", "Basso", "Glass", "Tink", "Pop", "Basso", "Basso"] && json(second)["stopReason"] == nil,
          "app B3: The recording could not be finished; its files are kept, with Basso; a stop that was asked for has no stop reason (\(played))")
    if let shown = model.status.notice?.folder { model.perform(.openMinutes(shown)) } // as its menu line does
    check(model.status.notice == nil, "app B3: opening that meeting clears the line")

    // only with sounds on
    prefs.sounds = false
    model.play("Basso")
    check(played.count == 8, "app: no sound at all with sounds off")
    model.shutDown()
    try? fm.removeItem(at: state)
}

/// A line over an app's socket. The socket's answers are worked out on the main queue, so the line is
/// sent from another thread while this one runs the main run loop.
func socketCommand(_ line: String, to sock: URL) -> String? {
    let lock = NSLock()
    var reply: String?? = nil
    DispatchQueue.global().async {
        let got = ControlClient.send(line, to: sock, timeout: 20)
        lock.lock(); reply = .some(got); lock.unlock()
    }
    _ = settle({ lock.lock(); defer { lock.unlock() }; return reply != nil }, timeout: 25)
    lock.lock(); defer { lock.unlock() }
    return reply ?? nil
}

// Residual in the app: a start that fails from the hotkey or the command shows as one from the menus
// does, in amber, with Basso once; one from the menus stays silent; the refusal while saving plays
// Basso once, not twice, and goes once the save is over.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = true
    prefs.openMinutes = false
    var played: [String] = []
    let rec = FakeRecorder()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                         playSound: { played.append($0) })
    model.launch()
    let sock = state.appendingPathComponent("control.sock")
    func command(_ line: String) -> String? { socketCommand(line, to: sock) }

    rec.launchError = FakeError(text: "Failed to start system audio: denied")
    let denied = command("toggle")
    let deniedLine = "Could not start: Failed to start system audio: denied"
    check(denied == "error Failed to start system audio: denied", "app socket: a toggle whose start fails is an error to the command (\(denied ?? "nil"))")
    check(settle { model.status.failure != nil } && model.status.failure == Failure("start", "Failed to start system audio: denied")
          && model.presentation.button.tint == .amber && model.presentation.menu.contains { $0.title == deniedLine },
          "app socket: the app shows Could not start: <reason>, in amber")
    _ = settle({ false }, timeout: 0.3)
    check(played == ["Basso"], "app socket: with Basso, once (\(played))")

    rec.launchError = FakeError(text: "No input device")
    let soundsBefore = played
    model.perform(.start)
    check(settle { model.status.failure == Failure("start", "No input device") }, "app menus: a failed start from the menus is shown")
    _ = settle({ false }, timeout: 0.3)
    check(played == soundsBefore, "app menus: silently, as before (\(played))")

    rec.launchError = nil
    let started = command("start")
    let dir = model.session.phase.folder
    check(dir != nil && started == "ok recording \(dir!.path)" && model.status.failure == nil,
          "app socket: a start that records clears the failure (\(started ?? "nil"))")
    check(dir != nil && command("stop") == "ok finalising \(dir!.path)", "app socket: stop")
    let refused = command("toggle")
    check(refused == "error " + Session.stillSaving, "app socket: a toggle while saving is refused (\(refused ?? "nil"))")
    check(settle { model.status.failure == Failure("start", Session.stillSaving) }, "app socket: and the refusal is shown")
    _ = settle({ false }, timeout: 0.3)
    check(played == ["Basso", "Tink", "Pop", "Basso"], "app socket: with Basso once, not twice (\(played))")
    let shownBefore = model.status
    let soundsThen = played
    let saving = command("status")
    _ = settle({ false }, timeout: 0.3)
    check(saving == "ok finalising \(dir?.path ?? "-")" && model.status == shownBefore && played == soundsThen,
          "app socket: an ok reply changes nothing shown, and plays nothing")

    rec.exit(rec.nextPid, 0, verifies: true)
    check(settle { model.session.phase == .idle }, "app socket: the recording is saved")
    check(settle({ model.status.phase == .idle && model.status.failure == nil }, timeout: 3)
          && model.presentation.button.symbol != "exclamationmark.triangle" && model.presentation.button.tint != .amber,
          "app socket: once the save is over and idle, the refusal is no longer shown, nor the amber triangle (\(model.presentation.button))")
    model.shutDown()
    try? fm.removeItem(at: state)
}

// Residual round 1 in the app: a command over the socket that acts on the recording clears an old
// failure, as a menu choice does; status leaves it; a retry that fails shows its own failure.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = true
    prefs.openMinutes = false
    let rec = FakeRecorder()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                         playSound: { _ in })
    // An adopted recorder, so pause and resume check its identity (`find`) and can fail to reach it.
    let live = Session.folderURL(root.appendingPathComponent("2026-11-08_0955").path)
    try! fm.createDirectory(at: live, withIntermediateDirectories: true)
    try! model.store.update(live) { $0.started = Date().addingTimeInterval(-300); $0.state = .recording }
    try! live.path.write(to: state.appendingPathComponent("recording.dir"), atomically: true, encoding: .utf8)
    rec.alive.insert(4242)
    rec.running[live.path] = 4242
    model.launch()
    check(model.session.phase == .recording(live), "app socket retry: an adopted recording")
    let sock = state.appendingPathComponent("control.sock")
    func command(_ line: String) -> String? { socketCommand(line, to: sock) }
    let reason = String(ControlHandler.cannotReach.dropFirst("error ".count))

    rec.findUnknown = true
    let unreached = command("pause")
    check(unreached == ControlHandler.cannotReach && settle { model.status.failure == Failure("pause", reason) },
          "app socket retry: a pause that cannot reach the recorder is shown (\(unreached ?? "nil"))")
    rec.findUnknown = false
    let paused = command("pause")
    _ = settle({ false }, timeout: 0.3)
    check(paused == "ok paused \(live.path)" && model.status.failure == nil && model.presentation.button.tint != .amber,
          "app socket retry: a pause that then works leaves no failure shown (\(model.presentation.button))")

    rec.findUnknown = true
    check(command("resume") == ControlHandler.cannotReach && settle { model.status.failure == Failure("resume", reason) },
          "app socket retry: a resume that cannot reach the recorder is shown")
    let status = command("status")
    _ = settle({ false }, timeout: 0.3)
    check(status == "ok paused \(live.path)" && model.status.failure == Failure("resume", reason),
          "app socket retry: status over the socket leaves the failure shown")

    rec.findUnknown = false
    check(command("resume") == "ok recording \(live.path)", "app socket retry: resume")
    rec.findUnknown = true
    check(command("pause") == ControlHandler.cannotReach && settle { model.status.failure == Failure("pause", reason) },
          "app socket retry: another pause that cannot reach the recorder is shown")
    rec.findUnknown = false
    rec.exit(4242, 0, verifies: true) // the recording ends on its own; the old pause failure stays
    check(settle { model.status.phase == .idle } && model.status.failure == Failure("pause", reason),
          "app socket retry: the pause failure outlives the recording")
    rec.launchError = FakeError(text: "Failed to start system audio: denied")
    let denied = command("toggle")
    check(denied == "error Failed to start system audio: denied"
          && settle { model.status.failure == Failure("start", "Failed to start system audio: denied") }
          && model.presentation.button.help == "Could not start: Failed to start system audio: denied",
          "app socket retry: after the old pause failure, a toggle whose start fails shows the new start failure")
    model.shutDown()
    try? fm.removeItem(at: state)
}

// MARK: - Final fix round, part 3: the library and the folders

// 8(b): a line about another meeting that arrives while one records or is paused waits in the menu; the
// recording keeps the icon and its timer, and the line takes the icon once that recording ends.
do {
    let notWritten = "Minutes could not be written: processing failed (exit 1)"
    let stopped = "Recording stopped: the recorder stopped unexpectedly"
    var s = StatusInput()
    s.apply(.phase(.recording(meetingB)))
    s.apply(.tick(seconds: 65, health: allOk))
    s.apply(.unfinished(meetingA, line: notWritten))
    let during = StatusPresentation(s)
    check(during.button == StatusButton(symbol: "circle.fill", tint: .red, title: "01:05", help: "Recording"),
          "8(b): a failure about A while B records leaves B's recording icon and timer (\(during.button))")
    check(action(notWritten, in: during) == .openMinutes(meetingA) && during.menu.first { $0.title == notWritten }?.enabled == true,
          "8(b): the line is in the menu, and opens A")
    s.apply(.phase(.paused(meetingB)))
    s.apply(.recordingStopped(meetingA, reason: Session.recorderStopped))
    let paused = StatusPresentation(s)
    check(paused.button == StatusButton(symbol: "pause.circle", tint: .plain, title: "01:05", help: "Paused") && action(stopped, in: paused) == .openMinutes(meetingA),
          "8(b): a Recording stopped line about A while B is paused leaves B's paused icon and timer, and is in the menu (\(paused.button))")
    // a failed pause is about this recording: it keeps its amber icon
    s.apply(.phase(.recording(meetingB)))
    s.apply(.failed(Failure("pause", "x")))
    check(StatusPresentation(s).button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "01:05", help: "Could not pause: x"),
          "8(b): a failed pause still turns the icon amber, with the timer")
    s.apply(.acted)
    check(StatusPresentation(s).button.symbol == "circle.fill" && s.notice?.folder == meetingA, "8(b): once it is cleared, the recording's icon again, and A's line is still there")
    // B stops: A's line takes the icon until A is opened
    s.apply(.phase(.finalising(meetingB)))
    check(StatusPresentation(s).button == StatusButton(symbol: "exclamationmark.triangle", tint: .amber, title: "", help: stopped),
          "8(b): after B stops, A's line turns the icon amber")
    s.apply(.phase(.idle))
    check(StatusPresentation(s).button.tint == .amber && StatusPresentation(s).button.help == stopped, "8(b): and keeps it once B is saved")
    s.apply(.minutesOpened(meetingA))
    check(s.notice == nil && StatusPresentation(s).button.symbol == "record.circle", "8(b): until A is opened")
}

// C8: the Preferences window says that choosing a new folder moves nothing.
check(PreferencesPresentation.folderMovesNothing
      == "Choosing a new folder moves nothing: meetings already recorded stay where they are, and the window lists only the folder chosen here.",
      "C8: the words under the meetings folder")

// C2: every folder a recording was started in (dir=, --dir, MB_DIR) is remembered, as a standardised full
// path, once, and never the meetings folder.
do {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let d = testDefaults()
    let p = Preferences(defaults: d, home: home)
    check(p.otherRoots.isEmpty, "C2: Preferences: no other folders at first")
    p.addOtherRoot(URL(fileURLWithPath: "/Volumes/Work/x/../Calls/", isDirectory: true))
    p.addOtherRoot(URL(fileURLWithPath: "/Volumes/Work/Calls", isDirectory: true))
    p.addOtherRoot(URL(fileURLWithPath: "/Users/someone/./Meetings/", isDirectory: true))
    p.addOtherRoot(URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true))
    check(p.otherRoots == ["/Volumes/Work/Calls", "/Volumes/Archive"],
          "C2: Preferences: other folders are standardised full paths, each once, never the meetings folder (\(p.otherRoots))")
    check(Preferences(defaults: d, home: home).otherRoots == ["/Volumes/Work/Calls", "/Volumes/Archive"], "C2: Preferences: and they persist")
}
do {
    let (r, h, prefs) = handlerRig()
    let parent = freshRoot()
    let work = parent.appendingPathComponent("Work Calls", isDirectory: true)
    let reply = h.reply(for: .start(mic: nil, dir: parent.path + "/x/../Work Calls/"))
    let made = names(work)
    check(made.count == 1 && reply == "ok recording \(work.path)/\(made.first ?? "-")" && r.rec.launches.first?.dir.path == "\(work.path)/\(made.first ?? "-")",
          "C2: a start with its own folder records there, the folder spelt as a standardised path (\(reply))")
    check(prefs.otherRoots == [work.standardizedFileURL.path], "C2: a dir= start remembers its folder (\(prefs.otherRoots))")
    func finish(_ t: TimeInterval) {
        _ = h.reply(for: .stop)
        r.rec.exit(r.rec.nextPid, 0, verifies: true)
        r.at(t)
    }
    finish(1)
    _ = h.reply(for: .start(mic: nil, dir: work.path))
    finish(2)
    _ = h.reply(for: .start(mic: nil, dir: r.store.root.path + "/"))
    finish(3)
    _ = h.reply(for: .start(mic: nil, dir: nil))
    finish(4)
    check(r.rec.launches.count == 4 && prefs.otherRoots == [work.standardizedFileURL.path],
          "C2: the same folder again, the meetings folder and no folder add nothing (\(prefs.otherRoots))")
    check(h.reply(for: .start(mic: nil, dir: "Calls")).hasPrefix("error ") && prefs.otherRoots.count == 1, "C2: nor does a start that is refused")
}

// C2: the sweep at launch looks in every other folder too, spelling each meeting's folder from that root
// as the start did, so a live recorder there is left alone; a folder that is not there is skipped.
do {
    var others: [URL] = []
    let r = Rig(otherRoots: { others })
    let work = r.root.appendingPathComponent("Work Calls", isDirectory: true)
    let unplugged = r.root.appendingPathComponent("Unplugged", isDirectory: true)
    others = [unplugged, work, r.store.root]
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    func meeting(_ name: String, _ state: MeetingState) -> URL {
        let dir = Session.folderURL(work.appendingPathComponent(name).path)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! r.store.update(dir) { $0.state = state }
        return dir
    }
    let orphan = meeting("2026-10-28_0900", .finalising)
    let live = meeting("2026-10-28_1000", .recording)
    r.rec.alive.insert(4242)
    r.rec.running[live.path] = 4242
    let inMeetings = r.meeting("2026-10-28_1100") { $0.state = .recording }
    let s = r.make()
    s.adopt()
    check(r.rec.recovered.map(\.path).sorted() == [inMeetings.path, orphan.path].sorted() && r.stateOf(orphan) == "queued" && r.stateOf(inMeetings) == "queued",
          "C2: the sweep recovers an orphan in another folder, as well as the meetings folder's, once each (\(r.rec.recovered.map(\.lastPathComponent)))")
    check(r.stateOf(live) == "recording" && r.rec.signals.isEmpty && s.phase == .idle, "C2: and leaves a live recorder in another folder alone")
    check(r.store.scan().map { $0.folder.url.lastPathComponent } == ["2026-10-28_1100"], "C2: the store's own scan is still the meetings folder alone")
}

// C2: the queue's resume takes up what was left queued in another folder, oldest first across the folders.
do {
    let base = freshRoot()
    let meetings = base.appendingPathComponent("Meetings", isDirectory: true)
    let work = base.appendingPathComponent("Work", isDirectory: true)
    try! fm.createDirectory(at: meetings, withIntermediateDirectories: true)
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    let store = MeetingStore(root: meetings, otherRoots: { [base.appendingPathComponent("Gone"), work] })
    let older = make(work, "2026-10-27_0900", files: ["audio.m4a": "a"])
    try! store.update(older) { $0.state = .queued }
    let newer = make(meetings, "2026-10-28_0900", files: ["audio.m4a": "a"])
    try! store.update(newer) { $0.state = .queued }
    let runner = FakeRunner()
    let q = ProcessingQueue(store: store, runner: runner, tickQueue: nil)
    q.resume()
    check(runner.folders == ["2026-10-27_0900"], "C2: resume takes up a meeting left queued in another folder, oldest first (\(runner.folders))")
    runner.finish(0, 0)
    check(runner.folders == ["2026-10-27_0900", "2026-10-28_0900"], "C2: then the meetings folder's (\(runner.folders))")
}

// C1, C5, C6 and C2 in the window: Play opens the recording in QuickTime Player and nothing else; Show in
// Finder opens the meeting's own folder; nothing plays during a recording; a meeting outside the folder can be shown.
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let queue = ProcessingQueue(store: r.store, runner: FakeRunner(), tickQueue: nil)
    var opened: [(file: URL, app: String)] = []
    var shownFolders: [URL] = []
    var found = true
    let opener = LibraryModel.Opener(open: { file, app in opened.append((file, app)); return found }, showFolder: { shownFolders.append($0) })
    let model = LibraryModel(store: r.store, session: session, queue: queue, opener: opener)
    let a = make(r.store.root, "2026-10-28_1508", files: ["audio.m4a": "a", "notes.md": "the minutes"])
    try! r.store.update(a) { $0.state = .done }
    model.reload()
    model.select(LibraryPresentation.key(a))
    check(settle { model.shownContent?.files.audio != nil }, "C1: the audio is found")
    model.perform(.playAudio)
    check(opened.count == 1 && isAt(opened.first?.file, a.appendingPathComponent("audio.m4a")) && opened.first?.app == "com.apple.QuickTimePlayerX"
          && shownFolders.isEmpty && model.problem == nil,
          "C1: Play audio opens the recording in QuickTime Player, by its bundle id, and nothing else is opened (\(opened.map(\.app)))")
    found = false
    model.perform(.playAudio)
    check(opened.count == 2 && model.problem == "QuickTime Player is needed to play recordings" && shownFolders.isEmpty,
          "C1: without QuickTime Player it says so, and opens nothing else")
    model.perform(.showInFinder)
    check(shownFolders.count == 1 && isAt(shownFolders.first, a) && opened.count == 2 && model.problem == nil,
          "C6: Show in Finder hands the meeting's own folder to the Finder, opening no file; the message goes")
    found = true
    model.update(StatusInput(phase: .recording(libURL("2026-10-29_0900"))))
    model.perform(.playAudio)
    model.update(StatusInput(phase: .paused(libURL("2026-10-29_0900"))))
    model.perform(.playAudio)
    check(opened.count == 2, "C5: nothing is played while a recording runs or is paused")
    model.update(StatusInput())

    // C2: a meeting recorded in a folder of its own: shown when asked for, never listed
    let outsideRoot = freshRoot()
    let outside = make(outsideRoot, "2026-10-27_1400", files: ["audio.m4a": "o", "notes.md": "elsewhere"])
    try! r.store.update(outside) { $0.state = .done }
    model.show(outside)
    check(model.selection == LibraryPresentation.key(outside), "C2: show selects a meeting outside the meetings folder")
    check(settle { isAt(model.selectedMeeting?.folder.url, outside) && model.shownContent?.key == LibraryPresentation.key(outside) }
          && model.shownContent?.minutes.map { String($0.characters) } == "elsewhere",
          "C2: and reads it, so its Minutes ready opens on its minutes")
    check(model.meetings.map(\.folder.url.lastPathComponent) == ["2026-10-28_1508"] && !model.rows.contains { $0.id == LibraryPresentation.key(outside) },
          "C2: the list is still the meetings folder alone")
    model.perform(.playAudio)
    check(opened.count == 3 && isAt(opened.last?.file, outside.appendingPathComponent("audio.m4a")), "C2: its actions work on it")
    model.reload()
    check(settle { model.hasScanned && model.meetings.count == 1 } && isAt(model.selectedMeeting?.folder.url, outside), "C2: it stays shown across a rescan")
    model.select(LibraryPresentation.key(a))
    check(isAt(model.selectedMeeting?.folder.url, a), "C2: choosing a listed meeting moves away from it")
}

// C2 after a relaunch: a meeting left queued, and one left finalising, in a folder a start used are taken
// up; a remembered folder that is not there is skipped and kept; Minutes ready opens such a meeting.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
    let work = root.appendingPathComponent("Work Calls", isDirectory: true)
    let unplugged = root.appendingPathComponent("Unplugged", isDirectory: true)
    try! fm.createDirectory(at: meetings, withIntermediateDirectories: true)
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = meetings
    prefs.sounds = false
    prefs.openMinutes = false
    let rec = FakeRecorder()
    let runner = FakeRunner()
    var recorded: URL? = nil
    do {
        let first = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: runner, freeBytes: { _ in 50 * GB })
        first.launch()
        let reply = first.handler.reply(for: .start(mic: nil, dir: work.path))
        recorded = first.session.phase.folder
        check(reply.hasPrefix("ok recording \(work.path)/") && prefs.otherRoots == [work.path], "C2 app: a start with its own folder is remembered (\(reply))")
        _ = first.handler.reply(for: .stop)
        rec.exit(rec.nextPid, 0, verifies: true)
        check(settle { runner.calls.count == 1 }, "C2 app: it is finished and processed where it is")
        runner.finish(0, 0)
        check(settle { first.status.notice?.kind == .minutesReady }, "C2 app: its minutes are ready")
        first.shutDown()
    }
    prefs.addOtherRoot(unplugged)
    let queuedThere = make(work, "2026-10-27_0900", files: ["audio.m4a": "a"])
    let orphanThere = make(work, "2026-10-26_0900")
    let store = MeetingStore(root: meetings)
    try! store.update(queuedThere) { $0.state = .queued }
    try! store.update(orphanThere) { $0.state = .finalising }
    let rec2 = FakeRecorder()
    let runner2 = FakeRunner()
    let next = AppModel(stateDir: state, preferences: prefs, recorder: rec2, runner: runner2, freeBytes: { _ in 50 * GB })
    next.launch()
    check(settle { runner2.folders == ["2026-10-27_0900"] }, "C2 app: after a relaunch, resume takes up the meeting left queued there (\(runner2.folders))")
    check(settle { rec2.recovered.map(\.lastPathComponent) == ["2026-10-26_0900"] && store.scan().isEmpty
                   && (MeetingStore.record(in: orphanThere)?.state == .queued) },
          "C2 app: and the sweep recovers the one left finalising there, and queues it (\(rec2.recovered.map(\.lastPathComponent)))")
    check(prefs.otherRoots == [work.path, unplugged.path], "C2 app: a remembered folder that is not there is skipped, and kept")
    next.library.reload()
    check(settle { next.library.hasScanned } && next.library.meetings.isEmpty, "C2 app: the window still lists the meetings folder alone")
    if let recorded = recorded { next.perform(.openMinutes(recorded)) }
    check(settle { isAt(next.library.selectedMeeting?.folder.url, recorded ?? meetings) && next.library.shownContent != nil },
          "C2 app: Minutes ready on such a meeting opens it in the window")
    next.shutDown()
    try? fm.removeItem(at: state)
}

// MARK: - Transcriber, tidying and the user's voice (Stage 3, Task 6)

/// Records each engine command; the test answers one by calling `answer`, on the main queue as the real
/// one does. Never a process.
final class FakeEngine: EngineCommands {
    struct Call {
        let arguments: [String]
        let stdin: Data?
        let timeout: TimeInterval
        let done: (Int32, String) -> Void
    }
    var calls: [Call] = []
    func run(_ arguments: [String], stdin: Data?, timeout: TimeInterval, done: @escaping (Int32, String) -> Void) {
        calls.append(Call(arguments: arguments, stdin: stdin, timeout: timeout, done: done))
    }
    func answer(_ i: Int, _ status: Int32, _ output: String) { calls[i].done(status, output) }
    func answerLast(_ status: Int32, _ output: String) { answer(calls.count - 1, status, output) }
    func count(_ arguments: [String]) -> Int { calls.filter { $0.arguments == arguments }.count }
}

/// Records each sample; the test says when it is capturing, or why it cannot. It writes the
/// sample.caf the real recorder would, so the folder has something in it. A stop is done at once
/// (`stopsAtOnce`), or held until the test finishes it, as the real one finishes on its own queue.
final class FakeSampler: SampleRecorder {
    var starts: [(folder: URL, microphone: String?, started: (String?) -> Void)] = []
    var stops = 0
    var stopsAtOnce = true
    /// The stops not finished yet, oldest first.
    var pendingStops: [() -> Void] = []
    /// Told at each stop, as it is asked for.
    var onStop: (() -> Void)?
    func start(folder: URL, microphone: String?, started: @escaping (String?) -> Void) {
        starts.append((folder, microphone, started))
        try? Data("caf".utf8).write(to: folder.appendingPathComponent("sample.caf"))
    }
    func stop(_ done: @escaping () -> Void) {
        stops += 1
        onStop?()
        if stopsAtOnce { done() } else { pendingStops.append(done) }
    }
    /// Finishes the stop at `i` among those pending (the oldest by default).
    func finishStop(_ i: Int = 0) { pendingStops.remove(at: i)() }
}

func lexists(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == 0 }

// Preferences: the transcriber and tidying, their defaults, persistence and the run settings.
do {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let d = testDefaults()
    let p = Preferences(defaults: d, home: home)
    check(p.transcriber == .parakeet && p.tidyLines, "T6 Preferences: the transcriber is Parakeet and tidying is on, by default")
    check(Transcriber.allCases == [.parakeet, .apple] && Transcriber.parakeet.rawValue == "parakeet" && Transcriber.apple.rawValue == "apple",
          "T6 Transcriber: parakeet and apple, the words the engine reads")
    check(p.runSettings == .defaults && RunSettings.defaults == RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .apple, agreed: []),
          "T6 Preferences: runSettings on an empty suite is RunSettings.defaults: Parakeet, tidy, Apple writes, nothing agreed")
    p.transcriber = .apple
    p.tidyLines = false
    let q = Preferences(defaults: d, home: home)
    check(q.transcriber == .apple && !q.tidyLines && d.string(forKey: "transcriber") == "apple" && (d.object(forKey: "tidyLines") as? Bool) == false,
          "T6 Preferences: both persist, under the keys transcriber and tidyLines that the engine reads")
    check(q.runSettings == RunSettings(transcriber: .apple, tidy: false, preferredWriter: .apple, agreed: []),
          "T6 Preferences: runSettings follows them, with Apple writing and nothing agreed")
    d.set("whisper", forKey: "transcriber")
    let unknownText = q.transcriber
    d.set(42, forKey: "transcriber")
    check(unknownText == .parakeet && q.transcriber == .parakeet, "T6 Preferences: a transcriber it does not know reads as Parakeet")
}

// The arguments the app gives the engine, and the writer rule.
do {
    let dir = URL(fileURLWithPath: "/Users/someone/Meetings/2026-11-13_0900", isDirectory: true)
    let audio = dir.appendingPathComponent("audio.m4a").path
    func args(_ t: Transcriber, tidy: Bool, writer: OutsideWriter? = nil, room: Int? = nil, call: Int? = nil) -> [String] {
        ScriptRunner.arguments(kind: .process, folder: dir, transcriber: t, room: room, call: call, tidy: tidy, writer: writer)
    }
    check(args(.parakeet, tidy: true) == ["process", audio, "--parakeet", "--tidy", "--writer", "apple"],
          "T6 arguments: a process job is process <dir>/audio.m4a --parakeet --tidy --writer apple")
    check(args(.apple, tidy: true) == ["process", audio, "--native", "--tidy", "--writer", "apple"], "T6 arguments: Apple's transcriber is --native")
    check(args(.parakeet, tidy: false) == ["process", audio, "--parakeet", "--no-tidy", "--writer", "apple"], "T6 arguments: tidying off is --no-tidy")
    check(args(.parakeet, tidy: true, room: 3, call: 2) == args(.parakeet, tidy: true), "T6 arguments: a process job takes no people counts")
    let claude = OutsideWriter(kind: .claude, address: "https://api.anthropic.com", model: "claude-model")
    check(args(.parakeet, tidy: true, writer: claude) == ["process", audio, "--parakeet", "--tidy", "--writer", "outside", "--kind", "claude",
                                                          "--address", "https://api.anthropic.com", "--writer-model", "claude-model"],
          "T6 arguments: an outside writer is --writer outside --kind --address --writer-model")
    func same(_ a: (use: OutsideWriter?, setAside: OutsideWriter?), _ use: OutsideWriter?, _ setAside: OutsideWriter?) -> Bool {
        a.use == use && a.setAside == setAside
    }
    let preferClaude = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .outside(claude),
                                   agreed: [Source(kind: .claude, address: claude.address, agreed: true)])
    var notAgreed = preferClaude
    notAgreed.agreed = []
    var otherKind = preferClaude
    otherKind.agreed = [Source(kind: .standard, address: claude.address, agreed: true)]
    var listedUnagreed = preferClaude
    listedUnagreed.agreed = [Source(kind: .claude, address: claude.address, agreed: false)]
    check(same(ScriptRunner.writer(meeting: nil, settings: .defaults), nil, nil), "T6 writer: no meeting writer and an Apple preference: Apple")
    check(same(ScriptRunner.writer(meeting: nil, settings: preferClaude), claude, nil),
          "T6 writer: the outside writer when agreed holds its kind and address")
    check(same(ScriptRunner.writer(meeting: nil, settings: notAgreed), nil, claude), "T6 writer: set aside when agreed lacks it")
    check(same(ScriptRunner.writer(meeting: nil, settings: otherKind), nil, claude), "T6 writer: set aside when agreed holds its address with another kind")
    check(same(ScriptRunner.writer(meeting: nil, settings: listedUnagreed), nil, claude), "T6 writer: set aside when its source is listed but not agreed")
    check(same(ScriptRunner.writer(meeting: .apple, settings: preferClaude), nil, nil), "T6 writer: a meeting's Apple wins over an outside preference")
    let local = OutsideWriter(kind: .standard, address: "http://127.0.0.1:11434/v1", model: "llama")
    let agreedLocal = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .apple,
                                  agreed: [Source(kind: .standard, address: local.address, agreed: true)])
    check(same(ScriptRunner.writer(meeting: .outside(local), settings: agreedLocal), local, nil)
          && same(ScriptRunner.writer(meeting: .outside(local), settings: .defaults), nil, local),
          "T6 writer: a meeting's own outside writer is used only when agreed, over an Apple preference")
}

// The queue builds each job's arguments at launch, from the settings of that moment, read once.
do {
    let r = QRig()
    var current = RunSettings.defaults
    var reads = 0
    let q = ProcessingQueue(store: r.store, runner: r.runner, tickQueue: nil, settings: { reads += 1; return current })
    let a = r.meeting("2026-11-13_0900", queued)
    let b = r.meeting("2026-11-13_1000", queued)
    let c = r.meeting("2026-11-13_1100", queued)
    q.enqueue(a)
    check(r.runner.calls.count == 1 && r.runner.calls[0].job.kind == .process && r.runner.calls[0].job.folder.path == a.path
          && r.runner.calls[0].arguments == ["process", a.appendingPathComponent("audio.m4a").path, "--parakeet", "--tidy", "--writer", "apple"]
          && reads == 1, "T6 queue: a process job launches with process <dir>/audio.m4a --parakeet --tidy --writer apple, the settings read once")
    q.enqueue(b)
    current = RunSettings(transcriber: .apple, tidy: false, preferredWriter: .apple, agreed: [])
    check(reads == 1, "T6 queue: a job waiting in the queue has not read the settings yet")
    r.runner.finish(0, 0)
    check(r.runner.calls.count == 2 && r.runner.calls[1].arguments == ["process", b.appendingPathComponent("audio.m4a").path, "--native", "--no-tidy", "--writer", "apple"]
          && reads == 2, "T6 queue: the next job launches with the settings changed while it waited: --native --no-tidy")
    let llama = OutsideWriter(kind: .standard, address: "http://localhost:11434/v1", model: "llama3")
    current = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .outside(llama), agreed: [])
    q.enqueue(c)
    r.runner.finish(1, 0)
    let log = (try? String(contentsOf: c.appendingPathComponent(".process-log"), encoding: .utf8)) ?? ""
    check(r.runner.calls.count == 3 && Array(r.runner.calls[2].arguments.suffix(2)) == ["--writer", "apple"]
          && log == "The minutes writer llama3 at localhost was set aside because its source was removed, changed or not agreed. Apple's model writes the minutes.\n"
          && mode(c.appendingPathComponent(".process-log")) == 0o600,
          "T6 queue: a writer set aside at launch: Apple writes, and .process-log (0600) says why first (\(log))")
    check(r.runner.calls[2].logAtRun == log, "T6 queue: the set-aside line is in .process-log before the engine is launched")
    r.runner.finish(2, 0)
}

// The engine's commands outside the app: the environment, stdin, the limit and the output cap. These
// call the static execute on scripts in the scratch folder; no test makes a ScriptEngineCommands.
do {
    let dir = freshRoot()
    let base = ["PATH": "/usr/bin:/bin", "MB_DIR": "/elsewhere", "MB_ENGINE": "native", "HOME": "/Users/someone"]
    let env = ScriptEngineCommands.environment(base, home: URL(fileURLWithPath: "/Users/someone"))
    check(!env.keys.contains { $0.hasPrefix("MB_") } && env["PATH"] == "/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
          && env["HOME"] == "/Users/someone", "T6 engine commands: their environment has no MB_* setting, and PATH is led as the runner's is")
    let script = dir.appendingPathComponent("engine")
    try! """
    #!/bin/bash
    for a in "$@"; do echo "arg $a"; done
    echo "stdin $(cat)"
    env | grep '^MB_' | sed 's/^/env /'
    exit 3
    """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o700)
    let (status, out) = ScriptEngineCommands.execute(script: script, arguments: ["key", "set", "--address", "http://x"], environment: env,
                                                     stdin: Data("the-key\n".utf8), timeout: 10)
    check(status == 3 && out.hasPrefix("arg key\narg set\narg --address\narg http://x\nstdin the-key\n") && !out.contains("env MB_"),
          "T6 engine commands: the script gets its arguments, stdin from a pipe, no MB_* setting, and its status comes back (\(status), \(out))")
    let quiet = dir.appendingPathComponent("quiet")
    try! "#!/bin/bash\nread -r line || echo eof\n".write(to: quiet, atomically: true, encoding: .utf8)
    chmod(quiet.path, 0o700)
    let (quietStatus, quietOut) = ScriptEngineCommands.execute(script: quiet, arguments: [], environment: env, stdin: nil, timeout: 10)
    check(quietStatus == 0 && quietOut == "eof\n", "T6 engine commands: with no stdin the script reads the end at once")
    let loud = dir.appendingPathComponent("loud")
    try! "#!/bin/bash\nhead -c 200000 /dev/zero | tr '\\0' a\n".write(to: loud, atomically: true, encoding: .utf8)
    chmod(loud.path, 0o700)
    let (loudStatus, loudOut) = ScriptEngineCommands.execute(script: loud, arguments: [], environment: env, stdin: nil, timeout: 10)
    check(loudStatus == 0 && loudOut.utf8.count == 65_536 && loudOut.allSatisfy { $0 == "a" }, "T6 engine commands: at most 64 KB of stdout (\(loudOut.utf8.count))")
    let slow = dir.appendingPathComponent("slow")
    let childFile = dir.appendingPathComponent("child")
    try! "#!/bin/bash\nsleep 30 &\necho $! > \"$1\"\nwait\n".write(to: slow, atomically: true, encoding: .utf8)
    chmod(slow.path, 0o700)
    let began = Date()
    let (slowStatus, _) = ScriptEngineCommands.execute(script: slow, arguments: [childFile.path], environment: env, stdin: nil, timeout: 0.5)
    let child = Int32((try? String(contentsOf: childFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    var childGone = false
    for _ in 0..<100 where !childGone { if child > 0 && kill(child, 0) != 0 { childGone = true } else { usleep(20_000) } }
    check(slowStatus == 124 && Date().timeIntervalSince(began) < 8 && childGone,
          "T6 engine commands: killed at the limit with status 124, the processes it started with it")
    let none = NoEngineCommands()
    var answer: (Int32, String)?
    none.run(["engines"], stdin: nil, timeout: 10) { answer = ($0, $1) }
    check(settle { answer != nil } && answer?.0 == 1 && answer?.1 == "meetingbox is not installed; run meetingbox setup",
          "T6 engine commands: NoEngineCommands answers status 1 and says meetingbox is not installed, and runs nothing")
}

// What Preferences shows: the engine's lines, the voice status, the Parakeet line and the sample's words.
do {
    let ready = PreferencesPresentation.parseEngines("parakeet ready\napple ready\nvoice none\n")
    check(ready == EngineStatus(parakeet: .ready, apple: .ready, voice: .none, outsideRuntime: .unknown),
          "T6 parseEngines: parakeet ready, apple ready, voice none")
    let missing = PreferencesPresentation.parseEngines(
        "parakeet unavailable the speech helper is not installed\napple unavailable speech-analyzer is not installed\nvoice 391 1 learnt\noutside-runtime ready\n")
    check(missing == EngineStatus(parakeet: .unavailable("the speech helper is not installed"), apple: .unavailable("speech-analyzer is not installed"),
                                  voice: .print(seconds: 391, meetings: 1, sample: false), outsideRuntime: .ready),
          "T6 parseEngines: unavailable with reasons, voice 391 1 learnt, and the outside-runtime line")
    check(PreferencesPresentation.parseEngines("voice 75 1 sample").voice == .print(seconds: 75, meetings: 1, sample: true)
          && PreferencesPresentation.parseEngines("voice 200 3 sample").voice == .print(seconds: 200, meetings: 3, sample: true),
          "T6 parseEngines: voice 75 1 sample and voice 200 3 sample")
    check(PreferencesPresentation.parseEngines("meetingbox is not installed; run meetingbox setup") == EngineStatus()
          && PreferencesPresentation.parseEngines("voice lots 1 learnt\nparakeet maybe").voice == .unknown
          && PreferencesPresentation.parseEngines("parakeet maybe").parakeet == .unknown,
          "T6 parseEngines: lines it cannot read leave what they would say unknown")
    let notLearnt = "Not learnt yet: meetingbox learns it from your video calls, or record a sample"
    check(PreferencesPresentation.voiceLine(.none) == notLearnt && PreferencesPresentation.voiceLine(.unknown) == "",
          "T6 voice status: none is not learnt yet, and nothing is said before the engine answers")
    check(PreferencesPresentation.voiceStatus(seconds: 391, meetings: 1, sample: false) == "Your voice: learnt from 1 call (7 minutes of speech)",
          "T6 voice status: 391 s from 1 call")
    check(PreferencesPresentation.voiceStatus(seconds: 754, meetings: 3, sample: false) == "Your voice: learnt from 3 calls (13 minutes of speech)",
          "T6 voice status: 754 s from 3 calls")
    check(PreferencesPresentation.voiceStatus(seconds: 95, meetings: 1, sample: true) == "Your voice: from a recorded sample (2 minutes of speech)"
          && PreferencesPresentation.voiceStatus(seconds: 90, meetings: 2, sample: false) == "Your voice: learnt from 2 calls (2 minutes of speech)"
          && PreferencesPresentation.voiceStatus(seconds: 89, meetings: 2, sample: false) == "Your voice: learnt from 2 calls (1 minute of speech)",
          "T6 voice status: minutes to the nearest, a half up, as doctor says them (95 s and 90 s are 2 minutes, 89 s is 1)")
    check(PreferencesPresentation.voiceStatus(seconds: 75, meetings: 1, sample: true) == "Your voice: from a recorded sample (1 minute of speech)",
          "T6 voice status: 75 s from a sample")
    check(PreferencesPresentation.voiceStatus(seconds: 200, meetings: 3, sample: true) == "Your voice: from a recorded sample and 2 calls (3 minutes of speech)",
          "T6 voice status: 200 s from a sample and 2 calls")
    check(PreferencesPresentation.voiceStatus(seconds: 130, meetings: 2, sample: true) == "Your voice: from a recorded sample and 1 call (2 minutes of speech)"
          && PreferencesPresentation.voiceLine(.print(seconds: 391, meetings: 1, sample: false)) == "Your voice: learnt from 1 call (7 minutes of speech)",
          "T6 voice status: a sample and 1 call, and voiceLine gives the same words")
    let notSetUp = "Parakeet is not set up, so Apple's transcriber is used. Run meetingbox setup."
    let unavailable = EngineStatus(parakeet: .unavailable("x"), apple: .ready, voice: .none, outsideRuntime: .unknown)
    check(PreferencesPresentation.parakeetNotSetUp(transcriber: .parakeet, engines: unavailable) == notSetUp
          && PreferencesPresentation.parakeetNotSetUp(transcriber: .apple, engines: unavailable) == nil
          && PreferencesPresentation.parakeetNotSetUp(transcriber: .parakeet, engines: ready) == nil
          && PreferencesPresentation.parakeetNotSetUp(transcriber: .parakeet, engines: EngineStatus()) == nil,
          "T6 Parakeet line: only when Parakeet is chosen and engines says it is unavailable")
    check(PreferencesPresentation.transcriberTitle(.parakeet) == "Parakeet (more accurate)" && PreferencesPresentation.transcriberTitle(.apple) == "Apple"
          && PreferencesPresentation.transcriberNote == "Applies to the next meeting processed."
          && PreferencesPresentation.tidyTitle == "Tidy transcript lines (drop 'um' and 'uh', keep short replies inline)"
          && PreferencesPresentation.recordSampleTitle == "Record a voice sample…" && PreferencesPresentation.forgetVoiceTitle == "Forget my voice"
          && PreferencesPresentation.sampleStopTitle == "Stop" && PreferencesPresentation.sampleDoneTitle == "Done",
          "T6 Preferences words: the transcriber, the note, tidying and the voice buttons, word for word")
    check(PreferencesPresentation.sampleCountdown(secondsLeft: 42) == "Read aloud for 90 seconds. 0:42 left"
          && PreferencesPresentation.sampleCountdown(secondsLeft: 90) == "Read aloud for 90 seconds. 1:30 left"
          && PreferencesPresentation.sampleCountdown(secondsLeft: 5) == "Read aloud for 90 seconds. 0:05 left",
          "T6 sample sheet: the countdown")
    check(PreferencesPresentation.sampleOutcome(status: 0, output: "sample 75\n") == .done("Your voice is learnt from this sample (1 minute of speech).")
          && PreferencesPresentation.sampleOutcome(status: 0, output: "sample 130\n") == .done("Your voice is learnt from this sample (2 minutes of speech)."),
          "T6 sample outcome: sample <seconds> in words")
    let twoVoices = "More than one voice was heard. Record again with only you speaking."
    let noParakeet = "Parakeet is not set up, so a voice sample cannot be used. Run meetingbox setup."
    check(PreferencesPresentation.sampleOutcome(status: 1, output: twoVoices + "\n") == .failed(twoVoices)
          && PreferencesPresentation.sampleOutcome(status: 1, output: noParakeet + "\n") == .failed(noParakeet)
          && PreferencesPresentation.sampleOutcome(status: 1, output: "meetingbox is not installed; run meetingbox setup") == .failed("meetingbox is not installed; run meetingbox setup"),
          "T6 sample outcome: a refusal is the engine's own line")
    check(PreferencesPresentation.sampleOutcome(status: 124, output: "") == .failed(PreferencesPresentation.sampleTookTooLong)
          && PreferencesPresentation.sampleOutcome(status: 2, output: "\n") == .failed("The voice sample could not be used (exit 2).")
          && PreferencesPresentation.sampleOutcome(status: 0, output: "") == .failed("The voice sample could not be used (exit 0)."),
          "T6 sample outcome: the limit, and an answer with no line, are failures that say so")
    check(PreferencesPresentation.sampleMicrophoneRefused
          == "meetingbox is not allowed to use the microphone. Allow it in System Settings, under Privacy & Security, Microphone."
          && PreferencesPresentation.sampleStoppedForMeeting == "Stopped because a meeting started recording."
          && PreferencesPresentation.sampleNeedsParakeet == noParakeet, "T6 sample words: the microphone, a meeting starting, and Parakeet")
    check(PreferencesPresentation.sampleMicrophoneFailed == "The microphone stopped working, so the voice sample was not used. Record again.",
          "R2 sample words: the microphone failing while the sample records")
}

// AppModel: the settings, the engine's status, forgetting, and the voice sample.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    prefs.microphone = "USB Mic"
    // What a crash may have left in the state folder, and what is not a sample folder.
    let leftover = state.appendingPathComponent("sample.abc123", isDirectory: true)
    try! fm.createDirectory(at: leftover, withIntermediateDirectories: true)
    try! Data("caf".utf8).write(to: leftover.appendingPathComponent("sample.caf"))
    let target = freshRoot()
    try! Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
    let link = state.appendingPathComponent("sample.lnk456")
    try! fm.createSymbolicLink(at: link, withDestinationURL: target)
    let samples = state.appendingPathComponent("samples", isDirectory: true)
    try! fm.createDirectory(at: samples, withIntermediateDirectories: true)
    let plainFile = state.appendingPathComponent("sample.fil789")
    try! Data("x".utf8).write(to: plainFile)
    let seven = state.appendingPathComponent("sample.abcdefg", isDirectory: true)
    let five = state.appendingPathComponent("sample.abc12", isDirectory: true)
    try! fm.createDirectory(at: seven, withIntermediateDirectories: true)
    try! fm.createDirectory(at: five, withIntermediateDirectories: true)
    let rec = FakeRecorder()
    let runner = FakeRunner()
    let engine = FakeEngine()
    let sampler = FakeSampler()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: runner, freeBytes: { _ in 50 * GB },
                         engine: engine, sampler: sampler)
    let waiting = make(root, "2026-11-13_0900", files: ["audio.m4a": "a"])
    try! model.store.update(waiting) { $0.state = .queued }

    var changes = 0
    let watch = model.objectWillChange.sink { _ in changes += 1 }
    model.setTranscriber(.apple)
    check(changes == 1 && prefs.transcriber == .apple, "T6 app: setTranscriber writes the setting and tells the views")
    model.setTidyLines(false)
    check(changes == 2 && !prefs.tidyLines, "T6 app: setTidyLines writes the setting and tells the views")

    model.launch()
    check(!lexists(leftover) && lexists(link) && lexists(target.appendingPathComponent("keep.txt")) && lexists(samples) && lexists(plainFile),
          "T6 launch: a leftover sample.abc123 folder is removed; a sample.* link, its target, a folder named samples and a file are not")
    check(lexists(seven) && lexists(five), "T6 launch: folders named sample. and seven or five characters are not sample folders, and stay")
    check(settle { runner.calls.count == 1 } && runner.calls[0].arguments
          == ["process", waiting.appendingPathComponent("audio.m4a").path, "--native", "--no-tidy", "--writer", "apple"],
          "T6 app: the queue launches with the transcriber and tidying chosen in Preferences (\(runner.calls.first?.arguments ?? []))")
    check(engine.calls.isEmpty, "T6 app: no engine command runs before Preferences opens")

    model.preferencesOpened()
    check(engine.calls.count == 1 && engine.calls[0].arguments == ["engines"] && engine.calls[0].timeout == 10 && engine.calls[0].stdin == nil,
          "T6 app: opening Preferences runs engines through the engine, with a 10 s limit")
    engine.answer(0, 0, "parakeet unavailable the speech helper is not installed\napple ready\nvoice 391 1 learnt\n")
    check(model.engineStatus.parakeet == .unavailable("the speech helper is not installed")
          && model.voiceStatus == "Your voice: learnt from 1 call (7 minutes of speech)" && model.parakeetNotSetUp == nil,
          "T6 app: the engine's answer is the status; with Apple chosen there is no Parakeet line")
    model.setTranscriber(.parakeet)
    check(model.parakeetNotSetUp == "Parakeet is not set up, so Apple's transcriber is used. Run meetingbox setup.",
          "T6 app: with Parakeet chosen and unavailable, the Parakeet line shows")
    model.recordSample()
    check(model.sample == .failed("Parakeet is not set up, so a voice sample cannot be used. Run meetingbox setup.") && sampler.starts.isEmpty,
          "T6 sample: with Parakeet unavailable a sample is refused at once, before 90 seconds of reading")
    model.closeSample()
    model.refreshEngines()
    model.refreshEngines()
    engine.answer(2, 0, "parakeet ready\napple ready\nvoice none\n")
    engine.answer(1, 0, "parakeet unavailable late\napple ready\nvoice 391 1 learnt\n")
    check(model.engineStatus.parakeet == .ready && model.voiceStatus == "Not learnt yet: meetingbox learns it from your video calls, or record a sample"
          && model.parakeetNotSetUp == nil, "T6 app: an engines answer overtaken by a newer one is dropped")

    // Forget my voice
    model.forgetVoice()
    check(engine.calls.last?.arguments == ["voice", "forget"], "T6 forget: forgetVoice runs voice forget through the engine")
    let enginesBeforeForget = engine.count(["engines"])
    engine.answerLast(0, "")
    check(engine.count(["engines"]) == enginesBeforeForget + 1 && model.voiceProblem == nil, "T6 forget: and then reads the engine status again")
    engine.answerLast(0, "parakeet ready\napple ready\nvoice none\n")
    model.forgetVoice()
    engine.answerLast(1, "Your voice print is being saved right now, so it was not forgotten. Try again.\n")
    check(model.voiceProblem == "Your voice print is being saved right now, so it was not forgotten. Try again.",
          "T6 forget: a refusal is shown in the engine's words")
    engine.answerLast(0, "parakeet ready\napple ready\nvoice none\n")

    // The sample: recorded for 90 s, then built by the engine.
    check(model.canRecordSample, "T6 sample: offered while nothing is recording")
    model.recordSample()
    let folder = sampler.starts.first?.folder ?? state
    check(model.sample == .recording(secondsLeft: 90) && sampler.starts.count == 1 && folder.deletingLastPathComponent().path == state.path
          && folder.lastPathComponent.hasPrefix("sample.") && folder.lastPathComponent.count == 13 && mode(folder) == 0o700
          && sampler.starts.first?.microphone == "USB Mic" && !model.canRecordSample,
          "T6 sample: recordSample makes <stateDir>/sample.XXXXXX (0700) and starts the sampler with the Preferences microphone")
    model.recordSample()
    check(sampler.starts.count == 1, "T6 sample: a second recordSample while one records starts nothing")
    sampler.starts[0].started(nil)
    for _ in 0..<89 { model.tickSample() }
    check(model.sample == .recording(secondsLeft: 1) && sampler.stops == 0 && engine.count(["voice", "add", folder.appendingPathComponent("sample.caf").path]) == 0,
          "T6 sample: 89 ticks leave one second, still recording")
    model.tickSample()
    check(model.sample == .building && sampler.stops == 1 && engine.calls.last?.arguments == ["voice", "add", folder.appendingPathComponent("sample.caf").path]
          && engine.calls.last?.timeout == 300 && lexists(folder),
          "T6 sample: the 90th tick ends the countdown: the sampler stops, building, voice add <stateDir>/sample.XXXXXX/sample.caf with a 300 s limit")
    model.tickSample()
    check(model.sample == .building, "T6 sample: ticks change nothing while building")
    let enginesBeforeSample = engine.count(["engines"])
    engine.answer(engine.calls.count - 1, 0, "sample 75\n")
    check(model.sample == .done("Your voice is learnt from this sample (1 minute of speech).") && !lexists(folder)
          && engine.count(["engines"]) == enginesBeforeSample + 1,
          "T6 sample: once the engine answers, the folder is removed, the outcome is in words and the engine status is read again")
    engine.answerLast(0, "parakeet ready\napple ready\nvoice 75 1 sample\n")
    check(model.voiceStatus == "Your voice: from a recorded sample (1 minute of speech)", "T6 sample: and Preferences shows the voice from the sample")
    model.closeSample()
    check(model.sample == .idle, "T6 sample: Done closes it")

    // Stop early, and a refusal.
    model.recordSample()
    let folder2 = sampler.starts[1].folder
    sampler.starts[1].started(nil)
    model.tickSample()
    model.stopSample()
    check(model.sample == .building && sampler.stops == 2 && engine.calls.last?.arguments == ["voice", "add", folder2.appendingPathComponent("sample.caf").path],
          "T6 sample: Stop ends it early: the sampler stops and the engine builds what was recorded")
    let tooShort = "Not enough speech: 12 seconds of the 60 needed. Record again and read for the whole 90 seconds."
    engine.answerLast(1, tooShort + "\n")
    check(model.sample == .failed(tooShort) && !lexists(folder2), "T6 sample: a refusal fails with the engine's line, and the folder is removed")
    engine.answerLast(0, "parakeet ready\napple ready\nvoice none\n")
    model.closeSample()

    // The sampler cannot start.
    let refused = "meetingbox is not allowed to use the microphone. Allow it in System Settings, under Privacy & Security, Microphone."
    let voiceAdds = engine.calls.filter { $0.arguments.starts(with: ["voice", "add"]) }.count
    model.recordSample()
    let folder3 = sampler.starts[2].folder
    sampler.starts[2].started(refused)
    check(model.sample == .failed(refused) && !lexists(folder3) && engine.calls.filter { $0.arguments.starts(with: ["voice", "add"]) }.count == voiceAdds,
          "T6 sample: started with a reason fails with that reason, removes the folder and builds nothing")
    model.closeSample()

    // A meeting wins: a socket start while sampling.
    model.recordSample()
    let folder4 = sampler.starts[3].folder
    sampler.starts[3].started(nil)
    model.tickSample()
    let stopsBefore = sampler.stops
    var launchesAtStop: [Int] = []
    sampler.onStop = { launchesAtStop.append(rec.launches.count) }
    let reply = model.handler.reply(for: .start(mic: nil, dir: nil))
    sampler.onStop = nil
    check(sampler.stops == stopsBefore + 1 && !lexists(folder4) && model.sample == .failed("Stopped because a meeting started recording.")
          && reply.hasPrefix("ok recording") && rec.launches.count == 1
          && engine.calls.filter { $0.arguments.starts(with: ["voice", "add"]) }.count == voiceAdds,
          "T6 willStart: a socket start while sampling stops the sampler, removes its folder, fails the sample, and the recording starts (\(reply))")
    check(launchesAtStop == [0], "T6 willStart: the sampler is stopped before the recorder is launched (\(launchesAtStop))")
    sampler.starts[3].started(nil)
    check(model.sample == .failed("Stopped because a meeting started recording.") && sampler.stops == stopsBefore + 2,
          "T6 willStart: a late word from the cancelled sampler that it is capturing only stops it again")
    model.closeSample()

    // Not while recording, paused or finalising.
    model.recordSample()
    check(model.sample == .idle && sampler.starts.count == 4 && !model.canRecordSample, "T6 sample: refused while recording")
    model.perform(.pause)
    check(settle { if case .paused = model.session.phase { return true }; return false }, "T6 sample: (the recording is paused)")
    model.recordSample()
    check(model.sample == .idle && sampler.starts.count == 4, "T6 sample: refused while paused")
    let pid = rec.nextPid
    model.perform(.stop)
    check(settle { if case .finalising = model.session.phase { return true }; return false }, "T6 sample: (the recording is finalising)")
    model.recordSample()
    check(model.sample == .idle && sampler.starts.count == 4, "T6 sample: refused while finalising")
    rec.exit(pid, 0, verifies: true)
    check(settle { model.session.phase == .idle }, "T6 sample: (the recording is finished)")

    // A toggle that becomes a start.
    model.recordSample()
    let folder5 = sampler.starts[4].folder
    sampler.starts[4].started(nil)
    let stopsBeforeToggle = sampler.stops
    launchesAtStop = []
    sampler.onStop = { launchesAtStop.append(rec.launches.count) }
    let reply2 = model.handler.reply(for: .toggle(mic: nil, dir: nil))
    sampler.onStop = nil
    check(sampler.stops == stopsBeforeToggle + 1 && !lexists(folder5) && model.sample == .failed("Stopped because a meeting started recording.")
          && reply2.hasPrefix("ok recording") && rec.launches.count == 2 && launchesAtStop == [1],
          "T6 willStart: a toggle that becomes a start does the same, the sampler stopped before the recorder is launched (\(reply2), \(launchesAtStop))")
    model.closeSample()
    let pid2 = rec.nextPid
    model.perform(.stop)
    _ = settle { if case .finalising = model.session.phase { return true }; return false }
    rec.exit(pid2, 0, verifies: true)
    check(settle { model.session.phase == .idle }, "T6 sample: (the second recording is finished)")

    // A start while the sample is being built leaves it to finish: nothing is recording any more.
    model.recordSample()
    let folder6 = sampler.starts[5].folder
    sampler.starts[5].started(nil)
    model.stopSample()
    let stopsBuilding = sampler.stops
    _ = model.handler.reply(for: .start(mic: nil, dir: nil))
    check(model.sample == .building && sampler.stops == stopsBuilding && lexists(folder6) && rec.launches.count == 3,
          "T6 willStart: a start while the sample is being built records, and the build goes on")
    engine.answerLast(0, "sample 61\n")
    check(model.sample == .done("Your voice is learnt from this sample (1 minute of speech).") && !lexists(folder6),
          "T6 sample: and finishes as before")
    engine.answerLast(0, "parakeet ready\napple ready\nvoice 61 1 sample\n")
    model.closeSample()
    let pid3 = rec.nextPid
    model.perform(.stop)
    _ = settle { if case .finalising = model.session.phase { return true }; return false }
    rec.exit(pid3, 0, verifies: true)
    _ = settle { model.session.phase == .idle }

    // Quitting during a sample stops it and removes its folder.
    model.recordSample()
    let folder7 = sampler.starts[6].folder
    sampler.starts[6].started(nil)
    let stopsBeforeQuit = sampler.stops
    model.shutDown()
    check(sampler.stops == stopsBeforeQuit + 1 && !lexists(folder7) && model.sample == .idle,
          "T6 sample: quitting while a sample records stops it and removes its folder")
    watch.cancel()

    // Round 1: the sampler stops on its own queue and says, on the main queue, when the sample is final.
    // This one holds every stop until the test finishes it.
    let state3 = shortTemp()
    let prefs3 = Preferences(defaults: testDefaults(), home: root)
    prefs3.meetingsFolder = freshRoot()
    prefs3.sounds = false
    let rec3 = FakeRecorder()
    let engine3 = FakeEngine()
    let slow = FakeSampler()
    slow.stopsAtOnce = false
    let m3 = AppModel(stateDir: state3, preferences: prefs3, recorder: rec3, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                      engine: engine3, sampler: slow)
    m3.launch()
    func voiceAdds3() -> Int { engine3.calls.filter { $0.arguments.starts(with: ["voice", "add"]) }.count }
    let stoppedForMeeting = SampleState.failed("Stopped because a meeting started recording.")

    // Building starts only once the sample is final.
    m3.recordSample()
    let s1 = slow.starts[0].folder
    slow.starts[0].started(nil)
    m3.tickSample()
    m3.stopSample()
    check(slow.stops == 1 && slow.pendingStops.count == 1 && m3.sample == .recording(secondsLeft: 89) && voiceAdds3() == 0 && !m3.canRecordSample,
          "R1 sample: Stop asks the sampler to stop and returns; nothing is built until the sample is final")
    m3.stopSample()
    m3.tickSample()
    check(slow.stops == 1 && m3.sample == .recording(secondsLeft: 89), "R1 sample: while it stops, Stop and the clock change nothing")
    slow.finishStop()
    check(m3.sample == .building && voiceAdds3() == 1 && engine3.calls.last?.arguments == ["voice", "add", s1.appendingPathComponent("sample.caf").path],
          "R1 sample: once the sampler says the sample is final: building, and voice add")
    engine3.answerLast(0, "sample 70\n")
    check(m3.sample == .done("Your voice is learnt from this sample (1 minute of speech).") && !lexists(s1), "R1 sample: and it ends as before")
    engine3.answerLast(0, "parakeet ready\napple ready\nvoice 70 1 sample\n")
    m3.closeSample()
    // The same at the end of the countdown.
    m3.recordSample()
    let s1b = slow.starts[1].folder
    slow.starts[1].started(nil)
    for _ in 0..<90 { m3.tickSample() }
    check(m3.sample == .recording(secondsLeft: 0) && slow.pendingStops.count == 1 && voiceAdds3() == 1,
          "R1 sample: the countdown ends at 0:00 and waits for the sampler, building nothing yet")
    slow.finishStop()
    check(m3.sample == .building && voiceAdds3() == 2 && engine3.calls.last?.arguments == ["voice", "add", s1b.appendingPathComponent("sample.caf").path],
          "R1 sample: then builds")
    engine3.answerLast(1, "More than one voice was heard. Record again with only you speaking.\n")
    engine3.answerLast(0, "parakeet ready\napple ready\nvoice 70 1 sample\n")
    m3.closeSample()

    // A meeting starting during a sample starts at once; the sample's folder goes once the sampler is done.
    m3.recordSample()
    let s2 = slow.starts[2].folder
    slow.starts[2].started(nil)
    let reply3 = m3.handler.reply(for: .start(mic: nil, dir: nil))
    check(reply3.hasPrefix("ok recording") && rec3.launches.count == 1 && m3.sample == stoppedForMeeting && slow.pendingStops.count == 1 && lexists(s2),
          "R1 willStart: the recording starts without waiting for the sampler to stop, and the sample has failed (\(reply3))")
    slow.finishStop()
    check(!lexists(s2) && voiceAdds3() == 2 && m3.sample == stoppedForMeeting, "R1 willStart: the folder goes once the sampler is done, and nothing is built")
    m3.closeSample()
    let pid4 = rec3.nextPid
    m3.perform(.stop)
    _ = settle { if case .finalising = m3.session.phase { return true }; return false }
    rec3.exit(pid4, 0, verifies: true)
    check(settle { m3.session.phase == .idle }, "R1: (the recording is finished)")

    // Stop before the sampler is capturing (a first-time permission prompt still up): back to idle.
    m3.recordSample()
    let s3 = slow.starts[3].folder
    m3.tickSample()
    check(m3.sample == .recording(secondsLeft: 90), "R1 sample: the countdown does not run before the sampler is capturing")
    m3.stopSample()
    check(m3.sample == .idle && slow.stops == 4 && voiceAdds3() == 2 && lexists(s3),
          "R1 stop before capturing: back to idle at once; nothing is built, so no line or path is shown")
    slow.finishStop()
    check(!lexists(s3), "R1 stop before capturing: the folder goes once the sampler is done")
    slow.starts[3].started(nil)
    check(slow.stops == 5 && m3.sample == .idle && voiceAdds3() == 2, "R1 stop before capturing: a word after the stop that it is capturing stops the sampler again")
    slow.finishStop()
    // The word comes while the first stop is still under way: the folder goes once its own stop is done.
    m3.recordSample()
    let s4 = slow.starts[4].folder
    m3.stopSample()
    slow.starts[4].started(nil)
    check(slow.stops == 7 && slow.pendingStops.count == 2 && m3.sample == .idle && lexists(s4),
          "R1 stop before capturing: a late word that it is capturing asks for a second stop")
    slow.finishStop(1)
    check(!lexists(s4) && voiceAdds3() == 2, "R1 stop before capturing: and that stop alone removes the folder")
    slow.finishStop()
    // A late word from an old sample never stops a newer one.
    m3.recordSample()
    let s5 = slow.starts[5].folder
    slow.starts[5].started(nil)
    slow.starts[4].started(nil)
    check(slow.stops == 7 && m3.sample == .recording(secondsLeft: 90) && lexists(s5), "R1: a late word from an old sample leaves a newer one recording")

    // Quitting still ends a sample, at once, though the sampler has not finished stopping.
    m3.shutDown()
    check(slow.stops == 8 && m3.sample == .idle && !lexists(s5), "R1 shutDown: a sample being recorded is stopped and its folder removed at once")
    slow.finishStop()
    check(m3.sample == .idle && voiceAdds3() == 2, "R1 shutDown: and the stop finishing later builds nothing")
    try? fm.removeItem(at: state3)

    // Round 2: the stopping step (Stop pressed, the sampler not done yet), and a capture that fails.
    let state4 = shortTemp()
    let prefs4 = Preferences(defaults: testDefaults(), home: root)
    prefs4.meetingsFolder = freshRoot()
    prefs4.sounds = false
    let rec4 = FakeRecorder()
    let engine4 = FakeEngine()
    let held = FakeSampler()
    held.stopsAtOnce = false
    let m4 = AppModel(stateDir: state4, preferences: prefs4, recorder: rec4, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                      engine: engine4, sampler: held)
    m4.launch()
    func voiceAdds4() -> Int { engine4.calls.filter { $0.arguments.starts(with: ["voice", "add"]) }.count }
    /// A sample recorded for a second, then stopped: the sampler has been asked to stop and has not said it is done.
    @MainActor func stopping(_ i: Int) -> URL {
        m4.recordSample()
        let folder = held.starts[i].folder
        held.starts[i].started(nil)
        m4.tickSample()
        m4.stopSample()
        return folder
    }
    let failedMic = PreferencesPresentation.sampleMicrophoneFailed

    // closeSample while stopping changes nothing: the sample the user stopped still builds.
    let c1 = stopping(0)
    m4.closeSample()
    check(m4.sample == .recording(secondsLeft: 89) && held.pendingStops.count == 1 && lexists(c1) && voiceAdds4() == 0,
          "R2 stopping: closeSample changes nothing while the sampler stops")
    held.finishStop()
    check(m4.sample == .building && voiceAdds4() == 1 && engine4.calls.last?.arguments == ["voice", "add", c1.appendingPathComponent("sample.caf").path],
          "R2 stopping: the sample still builds once the sampler is done")
    engine4.answerLast(0, "sample 66\n")
    engine4.answerLast(0, "parakeet ready\napple ready\nvoice 66 1 sample\n")
    m4.closeSample()

    // A meeting starting while the sampler stops: it starts at once, and the sample is cancelled.
    let c2 = stopping(1)
    let stopsBeforeMeeting = held.stops
    let reply4 = m4.handler.reply(for: .start(mic: nil, dir: nil))
    check(reply4.hasPrefix("ok recording") && rec4.launches.count == 1 && m4.sample == .failed("Stopped because a meeting started recording.")
          && held.stops == stopsBeforeMeeting && held.pendingStops.count == 1 && lexists(c2),
          "R2 stopping: a meeting start records at once and cancels the sample with the meeting line, with no second stop (\(reply4))")
    held.finishStop()
    check(!lexists(c2) && voiceAdds4() == 1 && m4.sample == .failed("Stopped because a meeting started recording."),
          "R2 stopping: the folder goes once the sampler is done, and nothing is built")
    m4.closeSample()
    let pid5 = rec4.nextPid
    m4.perform(.stop)
    _ = settle { if case .finalising = m4.session.phase { return true }; return false }
    rec4.exit(pid5, 0, verifies: true)
    check(settle { m4.session.phase == .idle }, "R2: (the recording is finished)")

    // The microphone fails while the sample records (the capture session's error).
    m4.recordSample()
    let c3 = held.starts[2].folder
    held.starts[2].started(nil)
    m4.tickSample()
    held.starts[2].started(failedMic)
    check(m4.sample == .failed(failedMic) && held.pendingStops.count == 1 && lexists(c3) && voiceAdds4() == 1,
          "R2 capture fails: the sample fails with the reason, the sampler is asked to stop, and nothing is built")
    held.finishStop()
    check(!lexists(c3) && voiceAdds4() == 1 && m4.sample == .failed(failedMic), "R2 capture fails: the folder goes once the sampler is done")
    m4.closeSample()
    // A failure the sampler reports after Stop leaves the sample it stopped to be built.
    let c3b = stopping(3)
    held.starts[3].started(failedMic)
    check(m4.sample == .recording(secondsLeft: 89) && held.pendingStops.count == 1, "R2 capture fails after Stop: the sample stopping is left alone")
    held.finishStop()
    check(m4.sample == .building && voiceAdds4() == 2 && engine4.calls.last?.arguments == ["voice", "add", c3b.appendingPathComponent("sample.caf").path],
          "R2 capture fails after Stop: and it builds from what was recorded")
    engine4.answerLast(1, "Not enough speech: 1 second of the 60 needed. Record again and read for the whole 90 seconds.\n")
    engine4.answerLast(0, "parakeet ready\napple ready\nvoice 66 1 sample\n")
    m4.closeSample()

    // Quitting while the sampler stops: the folder goes at once, since the app may be gone before done.
    let c4 = stopping(4)
    m4.shutDown()
    check(m4.sample == .idle && !lexists(c4) && voiceAdds4() == 2, "R2 stopping: quitting removes the folder at once and builds nothing")
    held.finishStop()
    check(m4.sample == .idle && voiceAdds4() == 2 && !lexists(c4), "R2 stopping: and the stop finishing later builds nothing")
    try? fm.removeItem(at: state4)

    // Without a sampler there is no sample, and without an engine nothing runs.
    let state2 = shortTemp()
    let prefs2 = Preferences(defaults: testDefaults(), home: root)
    prefs2.meetingsFolder = freshRoot()
    prefs2.sounds = false
    let plain = AppModel(stateDir: state2, preferences: prefs2, recorder: FakeRecorder(), runner: FakeRunner(), freeBytes: { _ in 50 * GB })
    plain.launch()
    plain.recordSample()
    check(plain.sample == .idle && !plain.canRecordSample && names(state2).allSatisfy { !$0.hasPrefix("sample.") },
          "T6 sample: refused when no sampler was given, making no folder")
    check(plain.engine is NoEngineCommands, "T6 app: an AppModel built without an engine has NoEngineCommands, which starts no process")
    plain.forgetVoice()
    check(settle { plain.voiceProblem == "meetingbox is not installed; run meetingbox setup" } && plain.engineStatus == EngineStatus(),
          "T6 app: and every engine command is answered that meetingbox is not installed")
    plain.shutDown()
    try? fm.removeItem(at: state)
    try? fm.removeItem(at: state2)
}

// MARK: - Redo minutes, Transcribe again and transcript versions (Stage 3, Task 8)

/// meeting.json written by hand, as another version of meetingbox or a person might leave it.
func writeRecord(_ dir: URL, _ object: [String: Any]) {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: dir.appendingPathComponent("meeting.json"))
}
func recordJSON(_ dir: URL) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meeting.json")))) as? [String: Any]) ?? [:]
}
let t8Local = OutsideWriter(kind: .standard, address: "http://127.0.0.1:11434/v1", model: "llama")
let t8Claude = OutsideWriter(kind: .claude, address: "https://api.anthropic.com", model: "claude-model")
/// A meeting a job has finished: its audio, a transcript and, unless `notes` is false (then it failed), the
/// minutes, all an hour old, with these meeting.json fields.
func t8Done(_ r: QRig, _ name: String, notes: Bool = true, _ change: ((inout MeetingRecord) -> Void)? = nil) -> URL {
    var files = ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello\n"]
    if notes { files["notes.md"] = "the old minutes\n" }
    let dir = r.meeting(name, files: files) {
        $0.state = notes ? .done : .failed
        change?(&$0)
    }
    age(dir)
    return dir
}
/// The engine's arguments are `head`, then the folder or file `at` (however a scan spells its path), then `tail`.
func argsAre(_ got: [String]?, _ head: String, _ at: URL, _ tail: [String]) -> Bool {
    guard let got = got, got.count == tail.count + 2 else { return false }
    return got[0] == head && LibraryPresentation.key(URL(fileURLWithPath: got[1])) == LibraryPresentation.key(at) && Array(got[2...]) == tail
}
/// Every file under a folder, with its bytes.
func snapshot(_ dir: URL) -> [String: Data] {
    var all: [String: Data] = [:]
    let items = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
    for u in items where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        all[String(u.path.dropFirst(dir.path.count))] = try? Data(contentsOf: u)
    }
    return all
}

// The record: the job options and the kept settings, in meeting.json's words, and read back. Values out of
// range or unknown are not taken; keys it does not know survive an update.
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    let dir = make(root, "2026-11-13_0900")
    try! store.update(dir) {
        $0.state = .queued
        $0.job = .transcribe
        $0.jobTranscriber = .apple
        $0.jobTidy = false
        $0.people = MeetingRecord.People(room: 2, call: nil)
        $0.writer = .outside(t8Local)
    }
    let j = recordJSON(dir)
    let people = j["people"] as? [String: Any]
    let writer = j["writer"] as? [String: Any]
    check(j["job"] as? String == "transcribe" && j["jobTranscriber"] as? String == "apple" && (j["jobTidy"] as? Bool) == false
          && (people?["room"] as? NSNumber)?.intValue == 2 && people?["call"] == nil && people?.count == 1
          && writer?["kind"] as? String == "standard" && writer?["address"] as? String == t8Local.address
          && writer?["model"] as? String == "llama" && writer?.count == 3,
          "T8 record: job, jobTranscriber, jobTidy, people (no key for Work it out) and writer, in meeting.json's words (\(j))")
    let back = MeetingStore.record(in: dir)
    check(back?.job == .transcribe && back?.jobTranscriber == .apple && back?.jobTidy == false
          && back?.people == MeetingRecord.People(room: 2, call: nil) && back?.writer == .outside(t8Local), "T8 record: and read back as they were")
    try! store.update(dir) {
        $0.writer = .apple
        $0.job = nil
        $0.jobTranscriber = nil
        $0.jobTidy = nil
        $0.people = MeetingRecord.People()
    }
    let k = recordJSON(dir)
    check(k["writer"] as? String == "apple" && k["job"] == nil && k["jobTranscriber"] == nil && k["jobTidy"] == nil && k["people"] == nil,
          "T8 record: Apple is \"apple\"; cleared options and counts leave no key (\(k))")
    writeRecord(dir, ["id": "x", "started": "2026-11-13T09:00:00Z", "state": "done", "job": "everything", "jobTranscriber": "whisper",
                      "jobTidy": "yes", "people": ["room": 9, "call": 0], "writer": ["kind": "gemini", "address": "a", "model": "m"]])
    let odd = MeetingStore.record(in: dir)
    check(odd != nil && odd?.job == nil && odd?.jobTranscriber == nil && odd?.jobTidy == nil && odd?.people == MeetingRecord.People()
          && odd?.writer == nil, "T8 record: an unknown job, transcriber or writer, a tidying that is not true or false, and counts outside 1 to 6 are not taken")
    writeRecord(dir, ["id": "x", "started": "2026-11-13T09:00:00Z", "state": "done", "people": ["room": 1, "call": 6, "names": ["A"]], "future": 1])
    check(MeetingStore.record(in: dir)?.people == MeetingRecord.People(room: 1, call: 6), "T8 record: counts of 1 and 6 are taken")
    try! store.update(dir) { $0.title = "Renamed" }
    let kept = recordJSON(dir)
    let keptPeople = kept["people"] as? [String: Any]
    check(keptPeople?["names"] != nil && (keptPeople?["room"] as? NSNumber)?.intValue == 1 && (keptPeople?["call"] as? NSNumber)?.intValue == 6
          && kept["future"] != nil, "T8 record: an update elsewhere keeps the counts, and keys it does not know (\(kept))")
}

// The arguments for the two redo kinds (contracts, "App to engine arguments").
do {
    let dir = URL(fileURLWithPath: "/Users/someone/Meetings/2026-11-13 0900 Weekly sync", isDirectory: true)
    func args(_ kind: JobKind, _ t: Transcriber = .parakeet, room: Int? = nil, call: Int? = nil, tidy: Bool = true,
              writer: OutsideWriter? = nil) -> [String] {
        ScriptRunner.arguments(kind: kind, folder: dir, transcriber: t, room: room, call: call, tidy: tidy, writer: writer)
    }
    check(JobKind.process.rawValue == "process" && JobKind.minutes.rawValue == "minutes" && JobKind.transcribe.rawValue == "transcribe",
          "T8 kinds: process, minutes and transcribe, the words meeting.json and .swap use")
    check(args(.minutes) == ["notes", dir.path, "--writer", "apple"], "T8 arguments: a minutes job is notes <dir> --writer apple")
    check(args(.minutes, .apple, room: 2, call: 3, tidy: false) == args(.minutes), "T8 arguments: a minutes job takes no transcriber, counts or tidying")
    check(args(.minutes, writer: t8Claude) == ["notes", dir.path, "--writer", "outside", "--kind", "claude", "--address", "https://api.anthropic.com",
                                               "--writer-model", "claude-model"], "T8 arguments: a minutes job with an outside writer")
    check(args(.transcribe, .apple, room: 2, tidy: false) == ["redo", dir.path, "--native", "--room", "2", "--no-tidy", "--writer", "apple"],
          "T8 arguments: a transcribe job is redo <dir> --native --room 2 --no-tidy --writer apple")
    check(args(.transcribe, call: 4) == ["redo", dir.path, "--parakeet", "--call", "4", "--tidy", "--writer", "apple"],
          "T8 arguments: --parakeet, --call alone, --tidy")
    check(args(.transcribe, room: 1, call: 6, writer: t8Local) == ["redo", dir.path, "--parakeet", "--room", "1", "--call", "6", "--tidy",
                                                                   "--writer", "outside", "--kind", "standard", "--address", t8Local.address,
                                                                   "--writer-model", "llama"], "T8 arguments: both counts and an outside writer")
}

// ProcessingQueue.redo: what it takes, what it writes before anything runs, and what it refuses.
do {
    let r = QRig()
    let q = r.make()
    let busy = r.meeting("2026-11-13_0800", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .outside(t8Local); $0.error = "an old redo did not finish" }
    let accepted = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, room: 2, call: nil, tidy: false, writer: .apple))
    let j = r.json(a)
    check(accepted && j["state"] as? String == "queued" && j["job"] as? String == "transcribe" && j["jobTranscriber"] as? String == "apple"
          && (j["jobTidy"] as? Bool) == false && (j["people"] as? [String: Any]).map { ($0["room"] as? NSNumber)?.intValue == 2 && $0["call"] == nil } == true
          && j["writer"] as? String == "apple" && j["error"] == nil && j["attempts"] == nil,
          "T8 redo: writes queued, the kind and the options, with no error or attempts, before anything runs (\(j))")
    check(r.runner.calls.count == 1 && q.current?.lastPathComponent == busy.lastPathComponent, "T8 redo: it queues behind another meeting's job")
    check(!q.redo(a, kind: .minutes, options: JobOptions(writer: .apple)) && r.json(a)["job"] as? String == "transcribe",
          "T8 redo: a meeting already queued is not taken again")

    func refused(_ dir: URL, _ kind: JobKind, _ label: String) {
        let before = try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))
        let taken = q.redo(dir, kind: kind, options: JobOptions(transcriber: .apple, room: 2, tidy: false, writer: .apple))
        check(!taken && (try? Data(contentsOf: dir.appendingPathComponent("meeting.json"))) == before, "T8 redo: refused, its record untouched: \(label)")
    }
    let files = ["audio.m4a": "a", "transcript.txt": "t", "notes.md": "n"]
    for (i, s) in [MeetingState.queued, .processing, .recording, .finalising].enumerated() {
        refused(r.meeting("2026-11-12_0\(i)00", files: files) { $0.state = s }, .minutes, "a \(s) meeting")
    }
    refused(busy, .transcribe, "the queue's own job")
    refused(r.meeting("2026-11-11_0900", files: ["audio.m4a": "a", "transcript.txt": "t"]) { $0.state = .unprocessed }, .minutes, "an unprocessed meeting")
    refused(t8Done(r, "2026-11-11_1000", notes: false), .transcribe, "Transcribe again on a failed meeting")
    refused(r.meeting("2026-11-11_1100", files: ["2026-11-11_1100_meeting.m4a": "a", "transcript.txt": "t", "notes.md": "n"]) { $0.state = .done },
            .transcribe, "Transcribe again without the audio a job runs (a v1.2 recording)")
    refused(r.meeting("2026-11-11_1200", files: ["audio.m4a": "a", "notes.md": "n"]) { $0.state = .done }, .minutes, "Redo minutes without a transcript")
    refused(r.meeting("2026-11-11_1300", files: ["audio.m4a": "a"]) { $0.state = .failed }, .minutes, "Redo minutes on a failed meeting without a transcript")
    let unfinished = r.meeting("2026-11-11_1400", files: ["audio.m4a": "a", "transcript.txt": "t", "notes.md": "n", "mic.caf": "c"]) { $0.state = .done }
    refused(unfinished, .minutes, "an unfinished recording, minutes")
    refused(unfinished, .transcribe, "an unfinished recording, transcribe")
    refused(t8Done(r, "2026-11-11_1500"), .process, "a process kind")
    let bare = r.meeting("2026-11-11_1600", files: ["audio.m4a": "a", "transcript.txt": "t"])
    check(!q.redo(bare, kind: .minutes, options: JobOptions(writer: .apple)) && !fm.fileExists(atPath: bare.appendingPathComponent("meeting.json").path),
          "T8 redo: a folder a scan calls unprocessed is refused, and no record is made for it")
    // taken: a v1.2 meeting with minutes and no record (a scan calls it done), and a failed one with a transcript
    let v12 = r.meeting("2026-11-10_0900", files: ["2026-11-10_0900_meeting.m4a": "a", "transcript.txt": "t", "notes.md": "n"])
    check(q.redo(v12, kind: .minutes, options: JobOptions(writer: .apple)) && r.state(v12) == "queued" && r.json(v12)["job"] as? String == "minutes"
          && r.json(v12)["writer"] as? String == "apple", "T8 redo: Redo minutes on a v1.2 meeting with no record: a record is made, queued")
    let failedText = t8Done(r, "2026-11-10_1000", notes: false)
    check(q.redo(failedText, kind: .minutes, options: JobOptions(writer: .apple)) && r.state(failedText) == "queued",
          "T8 redo: Redo minutes on a failed meeting with a transcript is queued")
    check(r.runner.calls.count == 1, "T8 redo: all of them wait behind the running job")
    r.runner.finish(0, 0)
    let run = r.runner.calls.last
    check(r.runner.calls.count == 2 && run?.job.kind == .transcribe && run?.stateAtRun == "processing" && run?.attemptsAtRun == 1
          && run?.arguments == ["redo", a.path, "--native", "--room", "2", "--no-tidy", "--writer", "apple"],
          "T8 redo: then it runs as its kind with the options written: redo <dir> --native --room 2 --no-tidy --writer apple (\(run?.arguments ?? []))")
}

// A redo survives a relaunch: the same kind, with the transcriber, counts, tidying and writer chosen in the
// sheet, whatever Preferences say by then (Review Focus 6).
do {
    let r = QRig()
    let agreedLocal = [Source(kind: .standard, address: t8Local.address, agreed: true)]
    var prefs = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .apple, agreed: agreedLocal)
    var q1: ProcessingQueue? = r.make(settings: { prefs })
    let busy = r.meeting("2026-11-13_0800", files: ["audio.m4a": "a"], queued)
    q1!.enqueue(busy)
    let a = t8Done(r, "2026-11-13_0900")
    check(q1!.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, room: 2, call: 3, tidy: false, writer: .outside(t8Local))),
          "T8 relaunch: a Transcribe again is queued behind another job")
    q1 = nil
    r.queue = nil // the app quits before it runs
    prefs = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .outside(t8Claude), agreed: agreedLocal)
    let runs = r.runner.calls.count
    var q2: ProcessingQueue? = r.make(settings: { prefs })
    q2!.resume()
    r.runner.finish(runs, 0) // the other job, taken up again first, ends
    let expected = ["--native", "--room", "2", "--call", "3", "--no-tidy", "--writer", "outside", "--kind", "standard",
                    "--address", t8Local.address, "--writer-model", "llama"]
    let run = r.runner.calls.last
    check(r.runner.calls.count == runs + 2 && run?.job.kind == .transcribe && argsAre(run?.arguments, "redo", a, expected),
          "T8 relaunch: after a relaunch it runs as the same kind with the sheet's choices, though Preferences changed (\(run?.arguments ?? []))")
    q2 = nil
    r.queue = nil // and the app quits again while it runs
    let q3 = r.make(settings: { prefs })
    q3.resume()
    let again = r.runner.calls.last
    check(r.runner.calls.count == runs + 3 && again?.job.kind == .transcribe && argsAre(again?.arguments, "redo", a, expected)
          && again?.attemptsAtRun == 2, "T8 relaunch: a redo cut off by a crash is settled and run again as the same kind, attempts 2")
    r.runner.finish(runs + 2, 0)
    check(r.state(a) == "done" && r.error(a) == nil, "T8 relaunch: and ends done")
}

// Success by kind: Redo minutes needs only a fresh notes.md; Transcribe again a fresh transcript.txt and
// notes.md. Every final outcome clears the job options and keeps the counts and the writer.
do {
    let r = QRig()
    let q = r.make()
    func jobCleared(_ dir: URL) -> Bool { r.json(dir)["job"] == nil && r.json(dir)["jobTranscriber"] == nil && r.json(dir)["jobTidy"] == nil }
    func settingsKept(_ dir: URL) -> Bool {
        ((r.json(dir)["people"] as? [String: Any])?["room"] as? NSNumber)?.intValue == 3 && r.json(dir)["writer"] as? String == "apple"
    }
    let a = t8Done(r, "2026-11-13_0900") { $0.people = MeetingRecord.People(room: 3, call: nil) }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    check(r.runner.calls.last?.arguments == ["notes", a.path, "--writer", "apple"] && r.runner.calls.last?.job.kind == .minutes,
          "T8 minutes: a minutes job launches notes <dir> --writer apple")
    r.runner.finishNotes(0, 0)
    check(r.state(a) == "done" && r.error(a) == nil && r.finished.last.map { $0 == (a.lastPathComponent, true) } == true && r.kinds.last == .minutes,
          "T8 minutes: a fresh notes.md alone is success (the transcript is an hour old)")
    check(jobCleared(a) && settingsKept(a), "T8 clearing: success clears job, jobTranscriber and jobTidy and keeps people and writer")
    let b = t8Done(r, "2026-11-13_1000") { $0.people = MeetingRecord.People(room: 3, call: nil) }
    _ = q.redo(b, kind: .transcribe, options: JobOptions(transcriber: .parakeet, room: 3, tidy: true, writer: .apple))
    r.runner.finishNotes(1, 0)
    check(r.state(b) == "done" && r.error(b) == "The redo did not finish: meetingbox finished but wrote nothing new. Nothing was changed."
          && r.finished.last.map { $0 == (b.lastPathComponent, false) } == true,
          "T8 transcribe: exit 0 with only notes.md fresh is not success for Transcribe again (\(r.error(b) ?? "-"))")
    check(jobCleared(b) && settingsKept(b), "T8 clearing: so does a failure")
    _ = q.redo(b, kind: .transcribe, options: JobOptions(transcriber: .parakeet, room: 3, tidy: true, writer: .apple))
    r.runner.finish(2, 0)
    check(r.state(b) == "done" && r.error(b) == nil && jobCleared(b) && settingsKept(b),
          "T8 transcribe: a fresh transcript.txt and notes.md is success, and the error line its last redo left goes")
}

// Failure: nothing changed, back to Done with minutes or Failed without, in the fixed words.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.people = MeetingRecord.People(room: 2, call: nil); $0.writer = .apple }
    _ = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, room: 2, tidy: false, writer: .apple))
    r.runner.finish(0, 1, "the call side has no words now.")
    check(r.state(a) == "done" && r.error(a) == "The redo did not finish: the call side has no words now. Nothing was changed.",
          "T8 failure: exit 1 on a meeting with minutes: Done, nothing changed, the engine's reason in the fixed words (\(r.error(a) ?? "-"))")
    check(r.finished.last.map { $0 == (a.lastPathComponent, false) } == true && r.kinds.last == .transcribe,
          "T8 failure: onFinished says it did not work, and the kind")
    check(r.json(a)["job"] == nil && (r.json(a)["people"] as? [String: Any]) != nil && r.json(a)["writer"] as? String == "apple",
          "T8 clearing: the job is cleared, the counts and writer kept")
    let f = t8Done(r, "2026-11-13_1000", notes: false)
    _ = q.redo(f, kind: .minutes, options: JobOptions(writer: .apple))
    r.runner.finish(1, 1, "")
    check(r.state(f) == "failed" && r.error(f) == "The redo did not finish: meetingbox failed (exit 1). Nothing was changed.",
          "T8 failure: without minutes it is Failed; with nothing on stderr the exit status is the reason (\(r.error(f) ?? "-"))")
    check(ProcessingQueue.redoNothingChanged("x.") == "The redo did not finish: x. Nothing was changed."
          && ProcessingQueue.redoPartWay("y") == "The redo stopped part way: y. Choose it again to finish it.", "T8 failure: the two fixed sentences")
}

// A killed engine: a signal, or a swap left to finish (exit 3), runs the same kind again, up to three runs.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.people = MeetingRecord.People(room: 2, call: nil); $0.writer = .apple }
    _ = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, room: 2, tidy: false, writer: .apple))
    let args = r.runner.calls.first?.arguments
    r.runner.finish(0, 137, "meetingbox transcribing")
    check(r.runner.calls.count == 2 && r.runner.calls[1].arguments == args && r.runner.calls[1].job.kind == .transcribe
          && r.runner.calls[1].attemptsAtRun == 2 && r.runner.calls[1].attempt != r.runner.calls[0].attempt && r.finished.isEmpty,
          "T8 killed: a redo stopped by a signal (137) runs again as the same kind, attempts 2")
    r.runner.finish(1, 3, "not every new file could be moved into place")
    check(r.runner.calls.count == 3 && r.runner.calls[2].arguments == args && r.runner.calls[2].attemptsAtRun == 3 && r.finished.isEmpty,
          "T8 killed: one that left a swap to finish (exit 3) runs again too, attempts 3")
    r.runner.finish(2, 137, "meetingbox transcribing")
    check(r.runner.calls.count == 3 && r.state(a) == "done"
          && r.error(a) == "The redo stopped part way: meetingbox was stopped before it finished. Choose it again to finish it.",
          "T8 killed: after three runs it stops: Done, stopped part way (\(r.error(a) ?? "-"))")
    check(r.json(a)["job"] == nil && r.json(a)["writer"] as? String == "apple" && r.finished.last.map { $0.1 } == false,
          "T8 clearing: stopped part way clears the job and keeps the writer")
    let b = t8Done(r, "2026-11-13_1000", notes: false)
    _ = q.redo(b, kind: .minutes, options: JobOptions(writer: .apple))
    r.runner.finish(3, 3, "not every new file could be moved into place")
    r.runner.finish(4, 143, "")
    r.runner.finish(5, 3, "not every new file could be moved into place")
    check(r.runner.calls.count == 6 && r.state(b) == "failed"
          && r.error(b) == "The redo stopped part way: not every new file could be moved into place. Choose it again to finish it.",
          "T8 killed: a third run that leaves a swap gives the engine's reason; without minutes it is Failed (\(r.error(b) ?? "-"))")
    // a process that leaves a swap runs again as a process; one stopped by a signal fails, as before
    let p = r.meeting("2026-11-13_1100", files: ["audio.m4a": "a"], queued)
    q.enqueue(p)
    r.runner.finish(6, 3, "not every new file could be moved into place")
    check(r.runner.calls.count == 8 && r.runner.calls[7].job.kind == .process && r.runner.calls[7].attemptsAtRun == 2,
          "T8 process: a process that left a swap (exit 3) runs again as a process")
    r.runner.finish(7, 137, "meetingbox transcribing")
    check(r.runner.calls.count == 8 && r.state(p) == "failed" && r.error(p) == "meetingbox transcribing",
          "T8 process: a process stopped by a signal fails with its last line, as before")
}

// The same rules when a job is settled after a relaunch, from its lock and .process-result.
func resumedRedo(_ kind: JobKind, attempts: Int, notes: Bool = true, _ setUp: (QRig, URL) -> Void) -> QRig {
    let r = QRig()
    let dir = t8Done(r, "2026-11-13_0900", notes: notes) {
        $0.state = .processing
        $0.attempts = attempts
        $0.attempt = "attempt-x"
        $0.job = kind
        $0.jobTranscriber = .apple
        $0.jobTidy = false
        $0.people = MeetingRecord.People(room: 2, call: nil)
        $0.writer = .apple
    }
    setUp(r, dir)
    r.make().resume()
    return r
}
do {
    let started = Date().addingTimeInterval(-30)
    var dir = URL(fileURLWithPath: "/")
    let three = resumedRedo(.transcribe, attempts: 1) { r, d in dir = d; r.result(d, attempt: "attempt-x", status: 3, started: started) }
    check(three.runner.calls.count == 1 && three.runner.calls[0].job.kind == .transcribe && three.runner.calls[0].attemptsAtRun == 2
          && argsAre(three.runner.calls[0].arguments, "redo", dir, ["--native", "--room", "2", "--no-tidy", "--writer", "apple"]),
          "T8 settle: our result with exit 3 runs the same kind again, with the options written, attempts 2")
    let killed = resumedRedo(.minutes, attempts: 2) { r, d in r.result(d, attempt: "attempt-x", status: 137, started: started) }
    check(killed.runner.calls.count == 1 && killed.runner.calls[0].job.kind == .minutes && killed.runner.calls[0].attemptsAtRun == 3,
          "T8 settle: our result ended by a signal runs the same kind again")
    let spent = resumedRedo(.transcribe, attempts: 3) { r, d in dir = d; r.result(d, attempt: "attempt-x", status: 3, started: started) }
    check(spent.runner.calls.isEmpty && spent.state(dir) == "done"
          && spent.error(dir) == "The redo stopped part way: meetingbox was stopped before it finished. Choose it again to finish it."
          && spent.json(dir)["job"] == nil && spent.json(dir)["writer"] as? String == "apple",
          "T8 settle: at attempts 3 it stops: Done, stopped part way, the job cleared (\(spent.error(dir) ?? "-"))")
    let failed = resumedRedo(.minutes, attempts: 1, notes: false) { r, d in dir = d; r.result(d, attempt: "attempt-x", status: 1, started: started) }
    check(failed.runner.calls.isEmpty && failed.state(dir) == "failed"
          && failed.error(dir) == "The redo did not finish: meetingbox failed (exit 1). Nothing was changed.",
          "T8 settle: our result with exit 1 is nothing changed; without minutes, Failed (\(failed.error(dir) ?? "-"))")
    let swapped = resumedRedo(.transcribe, attempts: 2) { r, d in
        dir = d
        stageFiles(d, ".stage.abc123", ["transcript.txt": "new transcript\n", "notes.md": "new minutes\n"])
        moveInStaged(d, stage: ".stage.abc123", touch: true)
        r.result(d, attempt: "attempt-x", status: 0, started: started)
    }
    check(swapped.runner.calls.isEmpty && swapped.state(dir) == "done" && swapped.error(dir) == nil && swapped.json(dir)["job"] == nil,
          "T8 settle: a run that only moved in its staged files, touched to now, and exited 0 is Done with no error line")
}

// The second run only finishes the first one's swap: the staged files moved in and touched to now, exit 0.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900")
    _ = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .parakeet, tidy: true, writer: .apple))
    r.runner.finish(0, 137) // killed between two renames
    stageFiles(a, ".stage.abc123", ["transcript.txt": "new transcript\n", "notes.md": "new minutes\n"])
    r.runner.finishSwap(1, 0, stage: ".stage.abc123")
    check(r.state(a) == "done" && r.error(a) == nil && r.finished.last.map { $0 == (a.lastPathComponent, true) } == true
          && (try? String(contentsOf: a.appendingPathComponent("transcript.txt"), encoding: .utf8)) == "new transcript\n",
          "T8 killed: a second run that only moves in the staged files, touched to now, ends Done with no error line")
    let b = t8Done(r, "2026-11-13_1000")
    _ = q.redo(b, kind: .transcribe, options: JobOptions(transcriber: .parakeet, tidy: true, writer: .apple))
    stageFiles(b, ".stage.def456", ["transcript.txt": "new transcript\n", "notes.md": "new minutes\n"])
    r.runner.finishSwap(2, 0, stage: ".stage.def456", touch: false)
    check(r.error(b) != nil, "T8 killed: (files moved in without being touched would not count as this run's)")
}

// Process and Try again after a failed redo: a full process, with the Preferences transcriber and tidying
// and the meeting's own writer.
do {
    let r = QRig()
    let current = RunSettings(transcriber: .apple, tidy: false, preferredWriter: .outside(t8Claude),
                              agreed: [Source(kind: .standard, address: t8Local.address, agreed: true)])
    let q = r.make(settings: { current })
    let a = t8Done(r, "2026-11-13_0900", notes: false) { $0.writer = .outside(t8Local); $0.people = MeetingRecord.People(room: 2, call: nil) }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .outside(t8Local)))
    check(r.runner.calls.first?.arguments == ["notes", a.path, "--writer", "outside", "--kind", "standard", "--address", t8Local.address,
                                          "--writer-model", "llama"], "T8 writer: a redo runs with the meeting's writer when it is agreed")
    r.runner.finish(0, 1, "the minutes could not be written")
    check(r.state(a) == "failed", "T8 after a redo: a failed Redo minutes without minutes leaves the meeting Failed")
    // job options a crash left behind are ignored, and cleared
    try! r.store.update(a) { $0.job = .transcribe; $0.jobTranscriber = .parakeet; $0.jobTidy = true }
    q.retry(a)
    let expected = ["process", a.appendingPathComponent("audio.m4a").path, "--native", "--no-tidy", "--writer", "outside", "--kind", "standard",
                    "--address", t8Local.address, "--writer-model", "llama"]
    check(r.runner.calls.count == 2 && r.runner.calls[1].job.kind == .process && r.runner.calls[1].arguments == expected
          && r.json(a)["job"] == nil && r.json(a)["jobTranscriber"] == nil && r.json(a)["jobTidy"] == nil && r.json(a)["people"] != nil,
          "T8 Try again after a redo: process <dir>/audio.m4a with the Preferences transcriber and tidying and the meeting's writer, the options cleared (\(r.runner.calls.last?.arguments ?? []))")
    r.runner.finish(1, 1, "nope")
    try! r.store.update(a) { $0.job = .minutes }
    q.process(a)
    check(r.runner.calls.count == 3 && r.runner.calls[2].job.kind == .process && r.runner.calls[2].arguments == expected && r.json(a)["job"] == nil,
          "T8 Process after a redo: the same full process")
    r.runner.finish(2, 0)
    check(r.state(a) == "done", "T8 Process after a redo: and it ends done")
}

// What the window offers: Redo minutes and Transcribe again, never on a busy meeting; the error line a redo
// left on a done meeting; the sheets' words.
do {
    let name = "2026-11-13_0900"
    let here = libURL(name)
    let full = MeetingFiles(audio: here.appendingPathComponent("audio.m4a"), runnable: true, transcript: true)
    let v12 = MeetingFiles(audio: here.appendingPathComponent("2026-11-13_0900_meeting.m4a"), runnable: false, transcript: true)
    let textOnly = MeetingFiles(transcript: true)
    let noText = MeetingFiles(audio: here.appendingPathComponent("audio.m4a"), runnable: true)
    var held = full
    held.lockHeld = true
    func acts(_ m: Meeting, _ files: MeetingFiles, _ phase: Session.Phase = .idle, processing: URL? = nil) -> [LibraryAction] {
        LibraryPresentation.actions(for: m, phase: phase, files: files, processing: processing)
    }
    let redo: Set<LibraryAction> = [.redoMinutes, .transcribeAgain]
    check(acts(libMeeting(name, .done), full) == [.rename, .showInFinder, .playAudio, .redoMinutes, .transcribeAgain],
          "T8 offered: a done meeting with a transcript and the audio a job runs offers both")
    check(acts(libMeeting(name, .done), v12) == [.rename, .showInFinder, .playAudio, .redoMinutes]
          && acts(libMeeting(name, .done, record: false), v12) == [.rename, .showInFinder, .playAudio, .redoMinutes]
          && acts(libMeeting(name, .done), textOnly) == [.rename, .showInFinder, .redoMinutes],
          "T8 offered: a done meeting that cannot be run (a v1.2 *_meeting.m4a, or no audio) offers only Redo minutes")
    check(acts(libMeeting(name, .failed), full) == [.rename, .showInFinder, .playAudio, .process, .redoMinutes]
          && acts(libMeeting(name, .failed), textOnly) == [.rename, .showInFinder, .redoMinutes],
          "T8 offered: a failed meeting with a transcript offers Redo minutes, and Process when it can be run")
    check(acts(libMeeting(name, .failed), noText) == [.rename, .showInFinder, .playAudio, .process]
          && acts(libMeeting(name, .done), noText) == [.rename, .showInFinder, .playAudio, .transcribeAgain],
          "T8 offered: no transcript, no Redo minutes")
    check(acts(libMeeting(name, .unprocessed), full) == [.rename, .showInFinder, .playAudio, .process], "T8 offered: neither for a meeting never processed")
    for s in [MeetingState.recording, .finalising, .queued, .processing] {
        check(redo.isDisjoint(with: acts(libMeeting(name, s), full)), "T8 offered: neither for a \(s) meeting")
    }
    check(redo.isDisjoint(with: acts(libMeeting(name, .done), full, processing: here))
          && redo.isDisjoint(with: acts(libMeeting(name, .done), full, processing: URL(fileURLWithPath: "/Meetings/./2026-11-13_0900/"))),
          "T8 offered: neither for the queue's live job, however its folder is spelled")
    check(redo.isDisjoint(with: acts(libMeeting(name, .done), held)), "T8 offered: neither while another process holds the lock (files.lockHeld)")
    check(acts(libMeeting(name, .done), full, .recording(libURL("2026-11-13_1000"))) == [.rename, .showInFinder, .redoMinutes, .transcribeAgain]
          && acts(libMeeting(name, .done), full, processing: libURL("2026-11-13_1000")).contains(.transcribeAgain),
          "T8 offered: both while another meeting records, or is processed")
    check(acts(libMeeting(name, .recording), full, .recording(here)) == [.pause, .stop, .showInFinder], "T8 offered: the recording itself is as before")
    check(LibraryAction.redoMinutes.title == "Redo minutes…" && LibraryAction.transcribeAgain.title == "Transcribe again…", "T8 words: the two actions")

    let left = "The redo did not finish: the call side has no words now. Nothing was changed."
    let doneLeft = libMeeting(name, .done, error: left + "\nmore")
    check(LibraryPresentation.notes(for: doneLeft, row: LibraryPresentation.row(doneLeft), files: full) == [left],
          "T8 window: a done meeting shows the error line its last redo left, one line")
    check(LibraryPresentation.notes(for: libMeeting(name, .done), row: LibraryPresentation.row(libMeeting(name, .done)), files: full).isEmpty,
          "T8 window: and nothing without one")
    let processing = libMeeting(name, .processing, error: left)
    check(LibraryPresentation.notes(for: processing, row: LibraryPresentation.row(processing), files: full).isEmpty, "T8 window: nor while it is processed")
    check(LibraryPresentation.redoTitle(.minutes) == "Redo minutes" && LibraryPresentation.redoTitle(.transcribe) == "Transcribe again",
          "T8 words: the sheets' titles and buttons")
    check(LibraryPresentation.roomLabel == "People in the room, including you" && LibraryPresentation.callLabel == "People on the other end of the call",
          "T8 words: the two counts")
    check(LibraryPresentation.countChoices.map(LibraryPresentation.roomChoice) == ["Work it out", "1 (just you)", "2", "3", "4", "5", "6"]
          && LibraryPresentation.countChoices.map(LibraryPresentation.callChoice) == ["Work it out", "1", "2", "3", "4", "5", "6"],
          "T8 words: Work it out, 1 (just you), 2 to 6; Work it out, 1 to 6")
    check(LibraryPresentation.busy == "That meeting is busy" && LibraryPresentation.renameMessage(RenameError.busy) == LibraryPresentation.busy,
          "T8 words: That meeting is busy")
    check(StatusPresentation.redoNotFinished == "Redo did not finish", "T8 words: the amber line")
}

// MeetingFiles.read: the transcript, and whether another process holds the lock (through the ps given);
// `actions` itself runs no process.
do {
    let root = freshRoot()
    let dir = make(root, "2026-11-13_0900", files: ["audio.m4a": "a", "transcript.txt": "t"])
    let folder = MeetingFolder.parse(dir)!
    let tools = freshRoot()
    let psLog = tools.appendingPathComponent("ps.log")
    let ps = tools.appendingPathComponent("ps")
    try! "#!/bin/bash\necho ran >> '\(psLog.path)'\nprintf '%s\\n' 'Thu Nov 13 09:00:00 2026'\n".write(to: ps, atomically: true, encoding: .utf8)
    chmod(ps.path, 0o700)
    func runs() -> Int { ((try? String(contentsOf: psLog, encoding: .utf8)) ?? "").split(separator: "\n").count }
    let free = MeetingFiles.read(folder, ps: ps)
    check(free.transcript && free.runnable && !free.lockHeld && runs() == 0, "T8 files: a transcript, no lock, and ps is not asked")
    let l = dir.appendingPathComponent(".processing")
    try! fm.createDirectory(at: l, withIntermediateDirectories: true)
    try! "\(me) Thu Nov 13 09:00:00 2026\n".write(to: l.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
    let held = MeetingFiles.read(folder, ps: ps)
    check(held.lockHeld && runs() == 1, "T8 files: a lock whose owner the given ps finds alive is held")
    let meeting = Meeting(folder: folder, record: nil, state: .done)
    for _ in 0..<5 { _ = LibraryPresentation.actions(for: meeting, phase: .idle, files: held, processing: nil) }
    check(runs() == 1, "T8 files: actions reads only its arguments and runs no process")
    try! "\(me) Mon Jan  5 09:00:00 2026\n".write(to: l.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
    check(!MeetingFiles.read(folder, ps: ps).lockHeld, "T8 files: an owner whose start time differs is gone: not held")
    check(MeetingFiles.read(folder, ps: tools.appendingPathComponent("no-such-ps")).lockHeld,
          "T8 files: a lock ps cannot tell about counts as held")
    try! fm.removeItem(at: dir.appendingPathComponent("transcript.txt"))
    check(!MeetingFiles.read(folder, ps: ps).transcript, "T8 files: no transcript.txt, no transcript")
}

// Transcript versions, in the order and words the picker shows.
do {
    let dir = URL(fileURLWithPath: "/Meetings/2026-11-13_0900", isDirectory: true)
    let versions = LibraryPresentation.transcriptVersions(
        in: dir,
        files: ["transcript.txt", "notes.md", "transcript-speakers-2.txt", "transcript-original.txt", "transcript-parakeet.txt", "transcript-a.txt",
                "old-transcript.txt", "transcript.txt.bak", "transcripts.md"],
        earlier: ["2026-11-12 1405", "2026-11-13 0910", "2026-11-12 1405-2", "2026-11-12 0900", "my copy", "2026-11-12 1405-10"])
    check(versions.map(\.title) == ["Current", "Parakeet (MLX)", "Original", "transcript-a.txt", "transcript-speakers-2.txt",
                                    "Earlier, 13 Nov 2026 09:10", "Earlier, 12 Nov 2026 14:05 (10)", "Earlier, 12 Nov 2026 14:05 (2)",
                                    "Earlier, 12 Nov 2026 14:05", "Earlier, 12 Nov 2026 09:00", "Earlier, my copy"],
          "T8 versions: Current, Parakeet (MLX), Original, the others by name, then each earlier one newest first, a -N folder told apart (\(versions.map(\.title)))")
    check(versions.first?.url == dir.appendingPathComponent("transcript.txt") && versions[1].url == dir.appendingPathComponent("transcript-parakeet.txt")
          && versions[5].url == dir.appendingPathComponent("earlier/2026-11-13 0910/transcript.txt"),
          "T8 versions: each names its file")
    check(LibraryPresentation.transcriptVersions(in: dir, files: [], earlier: []).map(\.title) == ["Current"], "T8 versions: Current is always there")
}

// LibraryModel: the picker, read only; search unchanged; when it goes back to Current; onSelectionChange.
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let queue = ProcessingQueue(store: r.store, runner: FakeRunner(), tickQueue: nil)
    let model = LibraryModel(store: r.store, session: session, queue: queue)
    var changed = 0
    model.onSelectionChange = { changed += 1 }
    let lists = MainSeen()
    model.listVersions = { dir in
        lists.note(Thread.isMainThread)
        return LibraryModel.versions(in: dir)
    }
    let root = r.store.root
    let a = make(root, "2026-11-13_0900", files: ["transcript.txt": "[00:00:01] Me: the current words", "notes.md": "minutes",
                                                  "transcript-parakeet.txt": "[00:00:01] Me: the mlx words", "transcript-original.txt": "original words"])
    for (stamp, words) in [("2026-11-12 1405", "the zebra words"), ("2026-11-12 1405-2", "the zebra words")] {
        let earlier = a.appendingPathComponent("earlier/\(stamp)", isDirectory: true)
        try! fm.createDirectory(at: earlier, withIntermediateDirectories: true)
        try! "[00:00:01] Me: \(words)".write(to: earlier.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    }
    let minutesOnly = a.appendingPathComponent("earlier/2026-11-11 0800", isDirectory: true)
    try! fm.createDirectory(at: minutesOnly, withIntermediateDirectories: true)
    try! "kept minutes".write(to: minutesOnly.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    try! r.store.update(a) { $0.state = .done }
    let b = make(root, "2026-11-12_0900", files: ["transcript.txt": "b words"])
    let keyA = LibraryPresentation.key(a), keyB = LibraryPresentation.key(b)
    model.reload()
    check(settle { model.meetings.count == 2 }, "T8 versions: the meetings are read")
    model.select(keyA)
    check(changed == 1, "T8 selection: select calls onSelectionChange when the selection changes")
    check(model.shownContent == nil, "R1 versions: nothing of the meeting is read before select returns")
    check(settle { model.shownContent?.versions.count == 5 }, "T8 versions: the versions arrive with the meeting's text")
    check(!lists.seen.isEmpty && !lists.seen.contains(true), "R2 versions (RR-2): the folder is listed off the main thread (\(lists.seen))")
    let versions = model.shownContent?.versions ?? []
    check(versions.map(\.title) == ["Current", "Parakeet (MLX)", "Original", "Earlier, 12 Nov 2026 14:05 (2)", "Earlier, 12 Nov 2026 14:05"]
          && model.version == nil && model.shownContent?.transcript == "[00:00:01] Me: the current words",
          "T8 versions: the folder's transcripts and each earlier/*/transcript.txt; Current is shown (\(versions.map(\.title)))")
    check(model.versionChoices == versions, "T8 versions: the picker offers them")
    guard versions.count == 5 else { return }
    let before = snapshot(a)
    let mlx = versions[1].url
    model.chooseVersion(mlx)
    check(model.version == mlx && settle { model.shownContent?.transcript == "[00:00:01] Me: the mlx words" }, "T8 versions: choosing one shows that file's text")
    check(model.versionChoices == model.shownContent?.versions, "R2 versions (RR-3): a chosen version still listed appears once in the picker")
    check(snapshot(a) == before, "T8 versions: and changes no file")
    model.chooseVersion(versions[0].url)
    check(model.version == nil && settle { model.shownContent?.transcript == "[00:00:01] Me: the current words" }, "T8 versions: choosing Current shows transcript.txt")
    let zebra = versions[3].url
    model.chooseVersion(zebra)
    check(settle { model.shownContent?.transcript == "[00:00:01] Me: the zebra words" }, "T8 versions: an earlier one")
    model.search("zebra")
    check(settle { model.visible.isEmpty } && model.meetings.count == 2, "T8 versions: search still matches only transcript.txt: not an earlier version")
    model.search("")
    check(model.visible.count == 2, "T8 versions: a blank search lists both again")
    model.search("mlx")
    check(settle { model.visible.isEmpty }, "T8 versions: nor another transcript in the folder")
    model.search("")
    model.search("current")
    check(settle { model.visible.map { LibraryPresentation.key($0.folder.url) } == [keyA] }, "T8 versions: transcript.txt is searched")
    model.search("")
    _ = make(root, "2026-11-11_0900")
    model.reload()
    check(settle { model.meetings.count == 3 } && model.version == zebra && settle { model.shownContent?.transcript == "[00:00:01] Me: the zebra words" },
          "T8 versions: a rescan keeps the chosen version")
    try! fm.removeItem(at: zebra)
    model.reload()
    // A read already under way may list the folder after the file went: wait for the read that follows.
    check(settle { model.shownContent?.versions.count == 4 && model.shownContent?.transcript == nil } && model.version == zebra,
          "T8 versions: a version deleted in Finder shows No transcript yet (nil), without a crash (\(model.shownContent?.versions.map(\.title) ?? []), \(model.shownContent?.transcript ?? "nil"), \(model.version?.path ?? "nil"))")
    check(model.versionChoices.count == 5 && model.versionChoices.last?.url == zebra
          && model.versionChoices.last?.title == "Earlier, 12 Nov 2026 14:05 (2)" && Array(model.versionChoices.prefix(4)) == model.shownContent?.versions,
          "R1 versions: the picker keeps the deleted choice, titled as it was, so it never shows a blank choice and Current can be chosen again (\(model.versionChoices.map(\.title)))")
    model.select(keyB)
    check(changed == 2 && model.version == nil, "T8 versions: selecting another meeting goes back to Current")
    check(settle { model.shownContent?.key == keyB } && model.versionChoices.isEmpty, "T8 versions: a meeting with only Current offers no picker")
    model.select(keyB)
    check(changed == 2, "T8 selection: the same selection again calls nothing")
    model.select(keyA)
    check(changed == 3 && settle { model.shownContent?.key == keyA && model.shownContent?.transcript == "[00:00:01] Me: the current words" },
          "T8 versions: back on the meeting, Current")
    model.chooseVersion(mlx)
    check(settle { model.shownContent?.transcript == "[00:00:01] Me: the mlx words" }, "T8 versions: chosen again")
    model.show(a)
    check(changed == 3 && model.version == nil && settle { model.shownContent?.transcript == "[00:00:01] Me: the current words" },
          "T8 versions: show (a job finished) goes back to Current; the selection is the same, so onSelectionChange is not called")
    model.show(b)
    check(changed == 4, "T8 selection: show calls it when the selection changes")
    model.show(b)
    check(changed == 4, "T8 selection: and not when it does not")
}

// LibraryModel: the two sheets, what they start at, Cancel, an outside writer not agreed, and the check off
// the main queue that refuses a busy meeting; a redo is accepted while another meeting records.
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let runner = FakeRunner()
    let queue = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil)
    var settings = RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .apple, agreed: [])
    let model = LibraryModel(store: r.store, session: session, queue: queue, settings: { settings })
    let root = r.store.root
    func done(_ name: String, _ change: @escaping (inout MeetingRecord) -> Void = { _ in }) -> URL {
        let dir = make(root, name, files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello", "notes.md": "minutes"])
        try! r.store.update(dir) { $0.state = .done; change(&$0) }
        return dir
    }
    let m1 = done("2026-11-13_0900") {
        $0.jobTranscriber = .apple
        $0.jobTidy = false
        $0.people = MeetingRecord.People(room: 3, call: 2)
        $0.writer = .outside(t8Local)
    }
    let m2 = done("2026-11-13_1000")
    let m3 = done("2026-11-13_1100")
    let m4 = done("2026-11-13_1200")
    model.reload()
    check(settle { model.meetings.count == 4 }, "T8 sheet: the meetings are read")
    @MainActor func open(_ dir: URL) -> Bool {
        model.select(LibraryPresentation.key(dir))
        return settle { model.shownContent?.key == LibraryPresentation.key(dir) && model.shownContent?.files.transcript == true }
    }
    check(open(m1) && model.actions(for: model.selectedMeeting!) == [.rename, .showInFinder, .playAudio, .redoMinutes, .transcribeAgain],
          "T8 sheet: a done meeting with a transcript and its audio offers both")
    model.perform(.transcribeAgain)
    let draft = model.redoing
    check(isAt(draft?.folder, m1) && draft?.kind == .transcribe && draft?.transcriber == .parakeet && draft?.tidy == true
          && draft?.room == 3 && draft?.call == 2 && draft?.writer == .outside(t8Local),
          "T8 sheet: Transcribe again starts at the Preferences transcriber and tidying, not the last redo's, at the meeting's counts and its writer (\(String(describing: draft)))")
    model.cancelRedo()
    _ = settle({ false }, timeout: 0.2)
    check(model.redoing == nil && runner.calls.isEmpty && r.stateOf(m1) == "done", "T8 sheet: Cancel queues nothing")

    settings.preferredWriter = .outside(t8Claude)
    check(open(m2), "T8 sheet: another meeting")
    model.perform(.redoMinutes)
    check(model.redoing?.kind == .minutes && model.redoing?.writer == .outside(t8Claude) && model.redoing?.room == nil && model.redoing?.call == nil,
          "T8 sheet: without a writer of its own the meeting starts at the Preferences writer; without counts, Work it out")
    let bytes = r.raw(m2)
    model.commitRedo()
    _ = settle({ false }, timeout: 0.3)
    check(runner.calls.isEmpty && r.raw(m2) == bytes && model.redoing != nil,
          "T8 sheet: an outside writer that Preferences have not agreed queues nothing and leaves meeting.json byte-identical")
    model.updateRedo { $0.writer = .apple }
    model.commitRedo()
    check(runner.calls.isEmpty && model.redoing != nil && r.stateOf(m2) == "done", "T8 sheet: the meeting is checked off the main queue: nothing is queued as commitRedo returns")
    check(settle { runner.calls.count == 1 } && model.redoing == nil && runner.calls.first?.job.kind == .minutes
          && argsAre(runner.calls.first?.arguments, "notes", m2, ["--writer", "apple"])
          && r.json(m2)["writer"] as? String == "apple" && model.problem == nil,
          "T8 sheet: once found free it is queued and runs, notes <dir> --writer apple, and the writer chosen is kept (\(runner.calls.first?.arguments ?? []))")

    // refused at the click: a record that became busy since the list was read; the live lock; the queue's job
    settings.preferredWriter = .apple
    check(open(m3), "T8 refusal: a third meeting")
    model.perform(.transcribeAgain)
    try! r.store.update(m3) { $0.state = .queued }
    model.commitRedo()
    check(settle { model.redoing == nil } && model.problem == "That meeting is busy" && runner.calls.count == 1,
          "T8 refusal: a meeting whose record says queued since the list was read is refused: That meeting is busy (\(model.problem ?? "-"), \(runner.calls.count), \(model.redoing == nil))")
    try! r.store.update(m3) { $0.state = .done }
    check(open(m4), "T8 refusal: a fourth meeting")
    let lock = m4.appendingPathComponent(".processing")
    try! fm.createDirectory(at: lock, withIntermediateDirectories: true)
    try! "\(me) \(lstartOf(me))\n".write(to: lock.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
    model.perform(.redoMinutes)
    check(model.redoing != nil, "T8 refusal: the window read the folder before the lock was taken, so it still offers Redo minutes")
    model.commitRedo()
    check(settle { model.redoing == nil } && model.problem == "That meeting is busy" && runner.calls.count == 1 && r.stateOf(m4) == "done",
          "T8 refusal: a meeting a meetingbox run in Terminal holds (the live lock) is refused at the click (\(model.problem ?? "-"), \(runner.calls.count), \(r.stateOf(m4) ?? "-"))")
    model.reload()
    check(settle { model.shownContent?.files.lockHeld == true } && !model.actions(for: model.selectedMeeting!).contains(.redoMinutes),
          "T8 refusal: once read, the held lock offers neither")
    try! fm.removeItem(at: lock)
    model.select(LibraryPresentation.key(m2))
    model.beginRedo(model.selectedMeeting!, kind: .minutes)
    model.commitRedo()
    check(settle { model.redoing == nil } && model.problem == "That meeting is busy" && runner.calls.count == 1,
          "T8 refusal: the queue's own job is refused at the click")

    // accepted while another meeting records, behind the running job
    let live = try! session.start(root: root, mic: nil)
    check(session.phase == .recording(live), "T8 queueing: another meeting is recording")
    check(open(m3) && model.actions(for: model.selectedMeeting!).contains(.transcribeAgain), "T8 queueing: Transcribe again is offered meanwhile")
    model.perform(.transcribeAgain)
    model.commitRedo()
    check(settle { r.stateOf(m3) == "queued" } && runner.calls.count == 1 && model.problem == nil && model.redoing == nil,
          "T8 queueing: a redo is accepted while another meeting records, and waits behind the running job (\(model.problem ?? "-"), \(runner.calls.count), \(r.stateOf(m3) ?? "-"), \(model.redoing == nil))")
    runner.finishNotes(0, 0)
    check(runner.calls.count == 2 && runner.calls[1].job.kind == .transcribe && runner.calls[1].arguments.first == "redo",
          "T8 queueing: and runs once that job ends")
}

// AppModel: the window gets the Preferences settings and the selection hook; a redo that did not finish is
// the amber line "Redo did not finish" and an error line on the done meeting, which the next success clears.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    prefs.transcriber = .apple
    prefs.tidyLines = false
    let runner = FakeRunner()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: FakeRecorder(), runner: runner, freeBytes: { _ in 50 * GB })
    model.launch()
    check(model.library.onSelectionChange != nil, "T8 app: AppModel sets the window's onSelectionChange")
    let dir = make(root, "2026-11-13_0900", files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello", "notes.md": "minutes"])
    try! model.store.update(dir) { $0.state = .done }
    age(dir)
    let key = LibraryPresentation.key(dir)
    model.library.reload()
    model.library.select(key)
    check(settle { model.library.shownContent?.key == key && model.library.shownContent?.files.transcript == true }, "T8 app: the meeting is shown")
    model.library.perform(.transcribeAgain)
    check(model.library.redoing?.transcriber == .apple && model.library.redoing?.tidy == false,
          "T8 app: the sheet starts at the Preferences transcriber and tidying, through the settings AppModel passes")
    model.library.commitRedo()
    check(settle { runner.calls.count == 1 } && runner.calls[0].arguments.first == "redo" && runner.calls[0].arguments.contains("--native")
          && runner.calls[0].arguments.contains("--no-tidy"), "T8 app: it runs as a transcribe job (\(runner.calls.first?.arguments ?? []))")
    runner.finish(0, 1, "the call side has no words now")
    let left = "The redo did not finish: the call side has no words now. Nothing was changed."
    check(settle { model.status.notice?.line == "Redo did not finish" } && model.status.notice?.kind == .unfinished
          && model.presentation.button.tint == .amber && isAt(model.status.notice?.folder, dir),
          "T8 app: a redo that did not finish is the amber line Redo did not finish, about that meeting (\(model.status.notice?.line ?? "-"))")
    check(settle { model.library.selectedMeeting.map { model.library.notes(for: $0) } == [left] }
          && model.library.selectedMeeting?.state == .done, "T8 app: the done meeting shows the error line in the window")
    check(settle { model.library.shownContent?.key == key && model.library.actions(for: model.library.selectedMeeting!).contains(.redoMinutes) },
          "T8 app: Redo minutes is offered again")
    model.library.perform(.redoMinutes)
    model.library.commitRedo()
    check(settle { runner.calls.count == 2 } && runner.calls[1].job.kind == .minutes, "T8 app: Redo minutes runs")
    runner.finishNotes(1, 0)
    check(settle { model.status.notice?.kind == .minutesReady } && settle { model.library.selectedMeeting.map { model.library.notes(for: $0) } == [] }
          && MeetingStore.record(in: dir)?.error == nil, "T8 app: the next success clears the error line, and Minutes ready replaces the amber line")
    model.shutDown()
    try? fm.removeItem(at: state)
}

// MARK: - Redo in the window, round 1

/// A JSON value as bytes, keys sorted, to compare values byte for byte.
func jsonBytes(_ value: Any?) -> Data? {
    value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
}
let unknownJobReason = "The redo did not finish: this version of meetingbox does not know that kind of job. Nothing was changed."

// A value of a key meetingbox knows but cannot read is kept, byte for byte, until that field is set (ADV-4, F3, T8Q-6).
do {
    let root = freshRoot()
    let store = MeetingStore(root: root)
    let dir = make(root, "2026-11-13_0900")
    let base: [String: Any] = ["id": "x", "started": "2026-11-13T09:00:00Z", "state": "done"]
    var odd = base
    odd["writer"] = ["kind": "gemini", "address": "https://g.example", "model": "g1"]
    odd["people"] = ["room": 9, "call": 2]
    odd["job"] = "speakers"
    odd["jobTranscriber"] = "whisper"
    odd["jobTidy"] = "yes"
    writeRecord(dir, odd)
    try! store.update(dir) { $0.title = "Renamed" }
    let after = recordJSON(dir)
    let kept = ["writer", "people", "job", "jobTranscriber", "jobTidy"].filter { after[$0] != nil && jsonBytes(after[$0]) == jsonBytes(odd[$0]) }
    check(kept.count == 5 && after["title"] as? String == "Renamed",
          "R1 record: a rename keeps a writer of kind gemini, people {room: 9, call: 2}, an unknown job, transcriber and tidying, byte for byte (kept \(kept))")
    var extra = base
    let writer: [String: Any] = ["kind": "standard", "address": t8Local.address, "model": "llama", "agreedAt": "2026-11-01"]
    extra["writer"] = writer
    extra["people"] = [2, 3]
    writeRecord(dir, extra)
    check(MeetingStore.record(in: dir)?.writer == .outside(t8Local), "R1 record: a writer with a key it does not know is still read")
    try! store.update(dir) { $0.state = .queued; $0.stage = "transcribing" }
    let queued = recordJSON(dir)
    check(jsonBytes(queued["writer"]) == jsonBytes(writer) && jsonBytes(queued["people"]) == jsonBytes([2, 3]),
          "R1 record: the queue's own writes keep that key, and people that is not an object (\(queued))")
    try! store.update(dir) {
        $0.writer = .apple
        $0.people.room = 3
    }
    let set = recordJSON(dir)
    check(set["writer"] as? String == "apple" && jsonBytes(set["people"]) == jsonBytes(["room": 3]),
          "R1 record: a field that is set is written: the writer, and the counts (replacing people that was not an object) (\(set))")
    writeRecord(dir, odd)
    try! store.update(dir) {
        $0.job = nil
        $0.jobTranscriber = nil
        $0.jobTidy = nil
        $0.people.call = nil
    }
    let cleared = recordJSON(dir)
    check(cleared["job"] == nil && cleared["jobTranscriber"] == nil && cleared["jobTidy"] == nil
          && jsonBytes(cleared["people"]) == jsonBytes(["room": 9]) && jsonBytes(cleared["writer"]) == jsonBytes(odd["writer"]),
          "R1 record: clearing a field removes what it held, even unreadable; a count set keeps the other, unreadable one (\(cleared))")
    writeRecord(dir, base)
    try! store.update(dir) { $0.title = "Plain" }
    let plain = recordJSON(dir)
    check(plain["writer"] == nil && plain["people"] == nil && plain["job"] == nil, "R1 record: and a record without them gains no key")
}

// A job word this version does not know never runs, as a process or as anything else: it ends as a redo that
// could not run, Done with its minutes, else Failed, and the job is cleared (ADV-1).
for (label, word) in [("Minutes", "Minutes" as Any), ("minutes with a trailing space", "minutes "), ("1", 1), ("[minutes]", ["minutes"]),
                      ("speakers", "speakers")] {
    let r = QRig()
    let dir = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    var queued = recordJSON(dir)
    queued["state"] = "queued"
    queued["job"] = word
    writeRecord(dir, queued)
    let q = r.make()
    q.resume()
    check(r.runner.calls.isEmpty && r.state(dir) == "done" && r.error(dir) == unknownJobReason && r.json(dir)["job"] == nil
          && r.json(dir)["writer"] as? String == "apple" && r.finished.last.map { $0 == (dir.lastPathComponent, false) } == true
          && r.kinds.count == 1 && r.kinds.last! == nil && q.current == nil,
          "R1 job: queued with job \(label): nothing runs; Done with the reason, the job cleared, the writer kept (\(r.runner.calls.map(\.arguments)), \(r.error(dir) ?? "-"))")
    let s = QRig()
    let held = t8Done(s, "2026-11-13_0900") { $0.writer = .apple }
    var processing = recordJSON(held)
    processing["state"] = "processing"
    processing["attempts"] = 1
    processing["attempt"] = "att-1"
    processing["job"] = word
    writeRecord(held, processing)
    // as if a run had worked: both files fresh, so a process's rule would call it done
    try! "new transcript\n".write(to: held.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    try! "new minutes\n".write(to: held.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    s.result(held, attempt: "att-1", status: 0, started: Date().addingTimeInterval(-30))
    s.lock(held, owner: "\(deadPid) Thu Jan  1 00:00:00 2026")
    s.make().resume()
    check(s.runner.calls.isEmpty && s.state(held) == "done" && s.error(held) == unknownJobReason && s.json(held)["job"] == nil,
          "R1 job: settled with job \(label): nothing runs again; Done with the reason, the job cleared (\(s.runner.calls.map(\.arguments)))")
}
do {
    let r = QRig()
    let dir = t8Done(r, "2026-11-13_0900", notes: false)
    var queued = recordJSON(dir)
    queued["state"] = "queued"
    queued["job"] = "speakers"
    writeRecord(dir, queued)
    r.make().resume()
    check(r.runner.calls.isEmpty && r.state(dir) == "failed" && r.error(dir) == unknownJobReason, "R1 job: without minutes it is Failed")
    check(ProcessingQueue.unknownJob == "this version of meetingbox does not know that kind of job", "R1 job: the reason, in these words")
}

// One outcome rule for a run that ended and one settled after a relaunch (T8Q-5, F1, T8Q-3).
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900")
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    r.runner.finish(0, 0, writeOutputs: false)
    check(r.runner.calls.count == 1 && r.state(a) == "done" && r.error(a) == "The redo did not finish: meetingbox finished but wrote nothing new. Nothing was changed.",
          "R1 outcome: a redo that exits 0 with nothing fresh is not run again, and says so (\(r.error(a) ?? "-"))")
    var dir = URL(fileURLWithPath: "/")
    let stale = resumedRedo(.minutes, attempts: 1) { r, d in
        dir = d
        r.result(d, attempt: "attempt-x", status: 0, started: Date().addingTimeInterval(-30))
    }
    check(stale.runner.calls.isEmpty && stale.state(dir) == "done"
          && stale.error(dir) == "The redo did not finish: meetingbox finished but wrote nothing new. Nothing was changed." && stale.json(dir)["job"] == nil,
          "R1 outcome: the same when it is settled after a relaunch: not run again, the same words (\(stale.error(dir) ?? "-"))")
    let minutes = resumedRedo(.minutes, attempts: 1) { r, d in
        dir = d
        try! "new minutes\n".write(to: d.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        r.result(d, attempt: "attempt-x", status: 0, started: Date().addingTimeInterval(-30))
    }
    check(minutes.runner.calls.isEmpty && minutes.state(dir) == "done" && minutes.error(dir) == nil && minutes.json(dir)["job"] == nil
          && minutes.finished.last.map { $0.1 } == true, "R1 outcome (F1): a Redo minutes settled with only notes.md fresh is Done, not run again, the job cleared")
    let p = r.meeting("2026-11-13_1000", files: ["audio.m4a": "a", "notes.md": "older minutes"], queued)
    age(p)
    q.enqueue(p)
    r.runner.finish(1, 1, "the transcript could not be made", writeOutputs: false)
    check(r.state(p) == "failed" && r.error(p) == "the transcript could not be made",
          "R1 outcome (T8Q-3): a process that fails stays Failed though an older notes.md is there")
}

// A meeting moved in Finder while its redo runs, waits or is queued is found by its id and finished there,
// without a relaunch, as its kind, running nothing twice (ADV-3, Review Focus 8).
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let movedA = r.store.root.appendingPathComponent("2026-11-13 0900 Weekly", isDirectory: true)
    _ = Darwin.rename(a.path, movedA.path)
    try! "new minutes\n".write(to: movedA.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    r.runner.calls.first?.done(0, "")
    check(r.runner.calls.count == 1 && r.state(movedA) == "done" && r.error(movedA) == nil && r.json(movedA)["job"] == nil
          && r.finished.last.map { $0 == (movedA.lastPathComponent, true) } == true && r.kinds.last! == .minutes && q.current == nil,
          "R1 moved: a redo that worked while its folder was moved ends Done at its new path, nothing run again (\(r.finished))")
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    _ = q.redo(b, kind: .transcribe, options: JobOptions(transcriber: .apple, tidy: false, writer: .apple))
    let movedB = r.store.root.appendingPathComponent("2026-11-13 1000 Standup", isDirectory: true)
    _ = Darwin.rename(b.path, movedB.path)
    if r.runner.calls.count == 2 { r.runner.calls[1].done(1, "the meeting folder was moved, nothing was changed") }
    check(r.runner.calls.count == 2 && r.state(movedB) == "done" && r.json(movedB)["job"] == nil
          && r.error(movedB) == "The redo did not finish: the meeting folder was moved, nothing was changed."
          && r.finished.last.map { $0 == (movedB.lastPathComponent, false) } == true && r.kinds.last! == .transcribe && q.current == nil,
          "R1 moved: one the engine refused because its folder moved ends Done with the reason at its new path (\(r.error(movedB) ?? "-"))")
    // queued behind another job, then moved
    let busy = r.meeting("2026-11-13_0800", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let c = t8Done(r, "2026-11-13_1100") { $0.writer = .apple }
    _ = q.redo(c, kind: .minutes, options: JobOptions(writer: .apple))
    let movedC = r.store.root.appendingPathComponent("2026-11-13 1100 Review", isDirectory: true)
    _ = Darwin.rename(c.path, movedC.path)
    r.runner.finish(2, 0)
    let run = r.runner.calls.last
    check(r.runner.calls.count == 4 && run?.job.kind == .minutes && argsAre(run?.arguments, "notes", movedC, ["--writer", "apple"]),
          "R1 moved: a redo queued when its folder was moved still runs, as its kind, at its new path (\(run?.arguments ?? []))")
    r.runner.finishNotes(3, 0)
    check(r.state(movedC) == "done" && r.error(movedC) == nil && q.current == nil, "R1 moved: and ends Done there")
    // waiting on another meetingbox, then moved with its lock
    let d = t8Done(r, "2026-11-13_1200") { $0.writer = .apple }
    _ = q.redo(d, kind: .minutes, options: JobOptions(writer: .apple))
    r.lock(d, owner: "\(me) \(lstartOf(me))")
    r.runner.finish(4, 75, "this meeting is already being processed")
    let movedD = r.store.root.appendingPathComponent("2026-11-13 1200 Later", isDirectory: true)
    _ = Darwin.rename(d.path, movedD.path)
    q.tick()
    check(r.runner.calls.count == 5 && q.current.map { LibraryPresentation.key($0) } == LibraryPresentation.key(movedD),
          "R1 moved: a redo waiting on another meetingbox follows its folder, and goes on waiting while the lock there is held")
    r.unlock(movedD)
    q.tick()
    let again = r.runner.calls.last
    check(r.runner.calls.count == 6 && again?.job.kind == .minutes && argsAre(again?.arguments, "notes", movedD, ["--writer", "apple"]),
          "R1 moved: once that lock goes it runs there as its kind (\(again?.arguments ?? []))")
    r.runner.finishNotes(5, 0)
    check(r.state(movedD) == "done" && q.current == nil, "R1 moved: and ends Done")
}

// Earlier versions: the engine's -N (2 or more, no leading zero) is told apart; any other name is shown as it
// is, control characters as spaces (ADV-5).
do {
    let dir = URL(fileURLWithPath: "/Meetings/2026-11-13_0900", isDirectory: true)
    let titles = LibraryPresentation.transcriptVersions(in: dir, files: ["transcript-a\nb.txt"],
                                                        earlier: ["2026-11-12 1405", "2026-11-12 1405-1", "2026-11-12 1405-0",
                                                                  "2026-11-12 1405-01", "2026-11-12 1405-2", "x\ny", "2026-11-12 1405\n"]).map(\.title)
    check(titles == ["Current", "transcript-a b.txt", "Earlier, 12 Nov 2026 14:05 (2)", "Earlier, 12 Nov 2026 14:05", "Earlier, 2026-11-12 1405 ",
                     "Earlier, 2026-11-12 1405-0",
                     "Earlier, 2026-11-12 1405-01", "Earlier, 2026-11-12 1405-1", "Earlier, x y"],
          "R1 versions: only the engine's -N is told apart; other names are shown as they are, control characters as spaces (\(titles))")
}

// The versions listing follows no link: a linked earlier/, earlier/<x> or transcript.txt is neither listed nor read
// (ADV-2, T8Q-7).
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let model = LibraryModel(store: r.store, session: session, queue: ProcessingQueue(store: r.store, runner: FakeRunner(), tickQueue: nil))
    let outside = freshRoot()
    func put(_ path: String, _ text: String) {
        let u = outside.appendingPathComponent(path)
        try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: u, atomically: true, encoding: .utf8)
    }
    put("secret.txt", "OUTSIDE SECRET")
    put("earlier-elsewhere/2026-01-01 0900/transcript.txt", "OUTSIDE EARLIER")
    put("one/transcript.txt", "OUTSIDE ONE")
    let root = r.store.root
    let a = make(root, "2026-11-13_0900", files: ["transcript.txt": "a words", "notes.md": "m"])
    try! fm.createSymbolicLink(at: a.appendingPathComponent("earlier"), withDestinationURL: outside.appendingPathComponent("earlier-elsewhere"))
    let b = make(root, "2026-11-13_1000", files: ["transcript.txt": "b words", "notes.md": "m"])
    try! fm.createDirectory(at: b.appendingPathComponent("earlier"), withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: b.appendingPathComponent("earlier/2026-11-12 1406"), withDestinationURL: outside.appendingPathComponent("one"))
    let c = make(root, "2026-11-13_1100", files: ["transcript.txt": "c words", "notes.md": "m"])
    let linkedIn = c.appendingPathComponent("earlier/2026-11-12 1405", isDirectory: true)
    try! fm.createDirectory(at: linkedIn, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: linkedIn.appendingPathComponent("transcript.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    let real = c.appendingPathComponent("earlier/2026-11-12 1300", isDirectory: true)
    try! fm.createDirectory(at: real, withIntermediateDirectories: true)
    try! "c kept words".write(to: real.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    model.reload()
    check(settle { model.meetings.count == 3 }, "R1 links: the meetings are read")
    let cases: [(URL, String, [String], URL)] = [
        (a, "a linked earlier/", ["Current"], a.appendingPathComponent("earlier/2026-01-01 0900/transcript.txt")),
        (b, "a linked earlier/<x>", ["Current"], b.appendingPathComponent("earlier/2026-11-12 1406/transcript.txt")),
        (c, "a linked transcript.txt", ["Current", "Earlier, 12 Nov 2026 13:00"], linkedIn.appendingPathComponent("transcript.txt")),
    ]
    for (dir, label, titles, planted) in cases {
        let key = LibraryPresentation.key(dir)
        model.select(key)
        check(settle { model.shownContent?.key == key } && model.shownContent?.versions.map(\.title) == titles,
              "R1 links: \(label) is not listed (\(model.shownContent?.versions.map(\.title) ?? []))")
        // the entry for it as the listing spells it, if it were listed
        model.chooseVersion(model.shownContent?.versions.first { LibraryPresentation.key($0.url) == LibraryPresentation.key(planted) }?.url ?? planted)
        _ = settle({ false }, timeout: 0.2)
        check(model.version == nil && !(model.shownContent?.transcript ?? "").contains("OUTSIDE"), "R1 links: \(label) cannot be chosen or read")
    }
    model.chooseVersion(model.shownContent?.versions.last?.url)
    check(settle { model.shownContent?.transcript == "c kept words" }, "R1 links: a real earlier version beside them still shows")
    try! fm.removeItem(at: real.appendingPathComponent("transcript.txt"))
    try! fm.createSymbolicLink(at: real.appendingPathComponent("transcript.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    model.reload()
    check(settle { model.shownContent?.versions.count == 1 } && model.version != nil && !(model.shownContent?.transcript ?? "").contains("OUTSIDE"),
          "R1 links: a chosen version replaced by a link afterwards is not read through it (\(model.shownContent?.transcript ?? "nil"))")
}

// commitRedo: Cancel while the check is under way queues nothing (T8Q-1); a lock ps cannot tell about is busy
// (T8Q-2, F2).
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let runner = FakeRunner()
    let queue = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil)
    let model = LibraryModel(store: r.store, session: session, queue: queue)
    let root = r.store.root
    let a = make(root, "2026-11-13_0900", files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello", "notes.md": "minutes"])
    try! r.store.update(a) { $0.state = .done }
    model.reload()
    check(settle { model.meetings.count == 1 }, "R1 commit: the meeting is read")
    model.select(LibraryPresentation.key(a))
    check(settle { model.shownContent?.files.transcript == true }, "R1 commit: and its folder")
    model.perform(.redoMinutes)
    let bytes = r.raw(a)
    model.commitRedo()
    model.cancelRedo()
    _ = settle({ false }, timeout: 0.5)
    check(runner.calls.isEmpty && r.raw(a) == bytes && model.redoing == nil && model.problem == nil,
          "R1 commit: Cancel before the check comes back queues nothing and leaves meeting.json byte-identical")
    // A lock whose owner a ps that cannot run says nothing about: unknown. The folder itself stays usable,
    // so only the lock rule can refuse it.
    let lock = a.appendingPathComponent(".processing")
    try! fm.createDirectory(at: lock, withIntermediateDirectories: true)
    try! "\(me) \(lstartOf(me))\n".write(to: lock.appendingPathComponent("owner"), atomically: true, encoding: .utf8)
    model.ps = freshRoot().appendingPathComponent("no-such-ps")
    model.perform(.redoMinutes)
    check(model.redoing != nil, "R2 commit: the folder was read before the lock, so Redo minutes is offered")
    model.commitRedo()
    check(settle { model.redoing == nil }, "R1 commit: the check comes back")
    check(model.problem == "That meeting is busy" && runner.calls.isEmpty && r.stateOf(a) == "done",
          "R1 commit (RR-1): a lock ps cannot tell about is busy: That meeting is busy, nothing queued")
    try! fm.removeItem(at: lock)
    model.ps = URL(fileURLWithPath: "/bin/ps")
    model.reload()
    check(settle { model.shownContent?.files.lockHeld == false }, "R2 commit: the folder is read again, the lock gone")
    model.perform(.redoMinutes)
    model.commitRedo()
    check(settle { runner.calls.count == 1 }, "R2 commit: with the lock gone the same meeting is queued (the folder was usable all along)")
}

// MARK: - Redo in the window, round 2

// A moved meeting is followed by its folder (its device and inode) and its id together, never by its id alone
// (ADV-R1-1, ADV-R1-2, ADV-R1-3).

// A titled Finder duplicate made during the run, then the original renamed: the duplicate gets nothing, and
// the original ends as its run did.
for (status, line) in [(Int32(0), ""), (1, "it broke"), (3, "not every new file could be moved into place")] {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13 0900 Weekly") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let copy = r.store.root.appendingPathComponent("2026-11-13 0900 Weekly copy", isDirectory: true)
    try! fm.copyItem(at: a, to: copy)
    let board = r.store.root.appendingPathComponent("2026-11-13 0900 Board", isDirectory: true)
    _ = Darwin.rename(a.path, board.path)
    if status == 0 { try! "new minutes\n".write(to: board.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8) }
    let copied = snapshot(copy)
    r.runner.calls.first?.done(status, line)
    check(snapshot(copy) == copied, "R2 identity: a Finder duplicate made during the run gets nothing (exit \(status))")
    switch status {
    case 0:
        check(r.runner.calls.count == 1 && r.state(board) == "done" && r.error(board) == nil
              && r.finished.last.map { $0 == (board.lastPathComponent, true) } == true && q.current == nil,
              "R2 identity: the original, renamed, ends Done (\(r.finished))")
    case 1:
        check(r.runner.calls.count == 1 && r.state(board) == "done" && r.error(board) == "The redo did not finish: it broke. Nothing was changed.",
              "R2 identity: the original, renamed, ends with its own reason (\(r.error(board) ?? "-"))")
    default:
        let again = r.runner.calls.last
        check(r.runner.calls.count == 2 && again?.attemptsAtRun == 2 && argsAre(again?.arguments, "notes", board, ["--writer", "apple"]),
              "R2 identity: a run left part done runs again in the original, never the duplicate (\(again?.arguments ?? []))")
    }
}
do {
    // queued behind another job, then duplicated and renamed: it runs in the original
    let r = QRig()
    let q = r.make()
    let busy = r.meeting("2026-11-13_0800", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let a = t8Done(r, "2026-11-13 0900 Weekly") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let copy = r.store.root.appendingPathComponent("2026-11-13 0900 Weekly copy", isDirectory: true)
    try! fm.copyItem(at: a, to: copy)
    let board = r.store.root.appendingPathComponent("2026-11-13 0900 Board", isDirectory: true)
    _ = Darwin.rename(a.path, board.path)
    let copied = snapshot(copy)
    r.runner.finish(0, 0)
    check(r.runner.calls.count == 2 && r.runner.calls[1].job.kind == .minutes && argsAre(r.runner.calls[1].arguments, "notes", board, ["--writer", "apple"])
          && snapshot(copy) == copied, "R2 identity: a queued redo duplicated, then renamed, runs in the original and leaves the duplicate alone")
}
do {
    // a meeting.json copied into another meeting's folder
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let other = t8Done(r, "2026-11-14_1000") { $0.writer = .apple }
    try! fm.removeItem(at: other.appendingPathComponent("meeting.json"))
    try! fm.copyItem(at: a.appendingPathComponent("meeting.json"), to: other.appendingPathComponent("meeting.json"))
    let moved = r.store.root.appendingPathComponent("2026-11-13 0900 Weekly", isDirectory: true)
    _ = Darwin.rename(a.path, moved.path)
    try! "new minutes\n".write(to: moved.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    let before = snapshot(other)
    r.runner.calls.first?.done(0, "")
    check(snapshot(other) == before && r.state(moved) == "done" && r.error(moved) == nil && r.runner.calls.count == 1,
          "R2 identity: a meeting.json copied into another folder gets nothing; the moved original ends Done")
}

// A meeting moved out of every root while another is renamed onto its old path: nothing is written anywhere,
// that other meeting is byte-identical, and the job ends as not done.
for (status, line) in [(Int32(0), ""), (1, "the meeting folder was moved, nothing was changed"), (3, ""), (137, "")] {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let away = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, away.path)
    _ = Darwin.rename(b.path, a.path)
    let there = snapshot(a)
    let left = snapshot(away)
    r.runner.calls.first?.done(status, line)
    check(snapshot(a) == there && snapshot(away) == left && r.runner.calls.count == 1 && q.current == nil && !q.hasWork
          && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true && r.kinds.last! == .minutes,
          "R2 out of reach: exit \(status) writes nothing, launches nothing, and the job ends as not done (\(r.runner.calls.map(\.arguments)))")
}
do {
    // ... and that other meeting's own queued redo still runs, as its kind, where it now is
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    _ = q.redo(b, kind: .transcribe, options: JobOptions(transcriber: .apple, room: 2, call: 3, tidy: false, writer: .apple))
    let away = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, away.path)
    _ = Darwin.rename(b.path, a.path)
    r.runner.calls.first?.done(1, "the meeting folder was moved, nothing was changed")
    let run = r.runner.calls.last
    check(r.runner.calls.count == 2 && run?.job.kind == .transcribe
          && argsAre(run?.arguments, "redo", a, ["--native", "--room", "2", "--call", "3", "--no-tidy", "--writer", "apple"])
          && r.error(a) == nil && r.json(away)["state"] as? String == "processing",
          "R2 out of reach: the meeting renamed onto its old path runs its own queued redo, as its kind; the one moved away is left as it was (\(run?.arguments ?? []))")
    r.runner.finish(1, 0)
    check(r.state(a) == "done" && r.error(a) == nil && !q.hasWork, "R2 out of reach: and ends Done")
}
do {
    // a queued redo moved out of every root before its turn: nothing is launched or written, and it ends as not done
    let r = QRig()
    let q = r.make()
    let busy = r.meeting("2026-11-13_0800", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let away = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, away.path)
    let left = snapshot(away)
    r.runner.finish(0, 0)
    check(r.runner.calls.count == 1 && snapshot(away) == left && !fm.fileExists(atPath: a.path) && !q.hasWork
          && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true,
          "R2 out of reach: a queued redo moved away before its turn launches nothing and ends as not done (\(r.finished))")
}

do {
    // the queue knows a meeting by its folder: another meeting renamed onto a held one's old path is not it
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let weekly = r.store.root.appendingPathComponent("2026-11-13 0900 Weekly", isDirectory: true)
    _ = Darwin.rename(a.path, weekly.path)
    _ = Darwin.rename(b.path, a.path)
    check(q.redo(a, kind: .minutes, options: JobOptions(writer: .apple)) && r.state(a) == "queued",
          "R2 known: Redo on the meeting now at a running meeting's old path is taken: it is another folder")
    check(!q.redo(weekly, kind: .minutes, options: JobOptions(writer: .apple)), "R2 known: the running meeting, renamed, is still known")
    r.runner.calls.first?.done(1, "the meeting folder was moved, nothing was changed")
    check(r.state(weekly) == "done" && r.runner.calls.count == 2 && argsAre(r.runner.calls[1].arguments, "notes", a, ["--writer", "apple"]),
          "R2 known: each then ends or runs in its own folder")
}

// Two queued redos whose folders swap names both run once, each as its own kind, in its own folder.
do {
    let r = QRig()
    let q = r.make()
    let busy = r.meeting("2026-11-13_0800", files: ["audio.m4a": "a"], queued)
    q.enqueue(busy)
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    _ = q.redo(b, kind: .transcribe, options: JobOptions(transcriber: .apple, tidy: false, writer: .apple))
    let swap = r.store.root.appendingPathComponent("swap", isDirectory: true)
    _ = Darwin.rename(a.path, swap.path)
    _ = Darwin.rename(b.path, a.path)
    _ = Darwin.rename(swap.path, b.path)
    r.runner.finish(0, 0)
    let first = r.runner.calls.last
    check(r.runner.calls.count == 2 && first?.job.kind == .minutes && argsAre(first?.arguments, "notes", b, ["--writer", "apple"]),
          "R2 swap: the minutes redo runs in its own folder, now named as the other was (\(first?.arguments ?? []))")
    r.runner.finishNotes(1, 0)
    let second = r.runner.calls.last
    check(r.runner.calls.count == 3 && second?.job.kind == .transcribe
          && argsAre(second?.arguments, "redo", a, ["--native", "--no-tidy", "--writer", "apple"]),
          "R2 swap: then the transcribe redo runs in its own folder (\(second?.arguments ?? []))")
    r.runner.finish(2, 0)
    check(r.state(a) == "done" && r.state(b) == "done" && r.runner.calls.count == 3 && !q.hasWork, "R2 swap: both end Done, each run once")
}

// A transcribe job whose transcriber or tidying cannot be read ends as an unknown job word does (ADV-R1-4).
for (label, key, value) in [("jobTranscriber whisper", "jobTranscriber", "whisper" as Any), ("jobTidy yes", "jobTidy", "yes"),
                            ("jobTidy 1", "jobTidy", 1)] {
    let r = QRig()
    let dir = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    var queued = recordJSON(dir)
    queued["state"] = "queued"
    queued["job"] = "transcribe"
    queued[key] = value
    writeRecord(dir, queued)
    r.make().resume()
    check(r.runner.calls.isEmpty && r.state(dir) == "done" && r.error(dir) == unknownJobReason && r.json(dir)["job"] == nil
          && r.json(dir)[key] == nil, "R2 options: a transcribe job with \(label) runs nothing and ends with the unknown-job reason, cleared")
}
do {
    let r = QRig()
    let dir = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    var processing = recordJSON(dir)
    processing["state"] = "processing"
    processing["attempts"] = 1
    processing["attempt"] = "att-1"
    processing["job"] = "transcribe"
    processing["jobTranscriber"] = "whisper"
    writeRecord(dir, processing)
    r.make().resume()
    check(r.runner.calls.isEmpty && r.state(dir) == "done" && r.error(dir) == unknownJobReason, "R2 options: the same when it is settled after a relaunch")
    let m = QRig()
    let minutes = t8Done(m, "2026-11-13_0900") { $0.writer = .apple }
    var queued = recordJSON(minutes)
    queued["state"] = "queued"
    queued["job"] = "minutes"
    queued["jobTranscriber"] = "whisper"
    writeRecord(minutes, queued)
    m.make().resume()
    check(m.runner.calls.count == 1 && m.runner.calls[0].job.kind == .minutes, "R2 options: a minutes job, which takes no transcriber, still runs")
}

// The reason says "nothing was changed" once (item 3).
check(ProcessingQueue.redoNothingChanged("the meeting folder was moved, nothing was changed")
      == "The redo did not finish: the meeting folder was moved, nothing was changed."
      && ProcessingQueue.redoNothingChanged("the meeting folder was moved, Nothing was changed.")
      == "The redo did not finish: the meeting folder was moved, Nothing was changed."
      && ProcessingQueue.redoNothingChanged("it broke") == "The redo did not finish: it broke. Nothing was changed.",
      "R2 copy: a reason that already says nothing was changed is not followed by Nothing was changed. again")

// The folder's own transcript-*.txt: a link, a folder and a FIFO by that name are not listed, and nothing waits
// on the FIFO (RR-4).
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let model = LibraryModel(store: r.store, session: session, queue: ProcessingQueue(store: r.store, runner: FakeRunner(), tickQueue: nil))
    let outside = freshRoot()
    try! "OUTSIDE SECRET".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    let a = make(r.store.root, "2026-11-13_0900", files: ["transcript.txt": "a words", "notes.md": "m", "transcript-real.txt": "real words"])
    try! fm.createSymbolicLink(at: a.appendingPathComponent("transcript-link.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    try! fm.createDirectory(at: a.appendingPathComponent("transcript-folder.txt"), withIntermediateDirectories: true)
    check(mkfifo(a.appendingPathComponent("transcript-fifo.txt").path, 0o600) == 0, "R2 top level: a FIFO is made")
    model.reload()
    check(settle { model.meetings.count == 1 }, "R2 top level: the meeting is read")
    model.select(LibraryPresentation.key(a))
    check(settle { model.shownContent != nil } && model.shownContent?.versions.map(\.title) == ["Current", "transcript-real.txt"],
          "R2 top level (RR-4): a linked, a folder and a FIFO transcript-*.txt are not listed, and nothing waits on the FIFO (\(model.shownContent?.versions.map(\.title) ?? []))")
}

// AppModel: a job this version cannot read ends with the amber line "Redo did not finish" (RR-5).
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    let runner = FakeRunner()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: FakeRecorder(), runner: runner, freeBytes: { _ in 50 * GB })
    model.launch()
    let dir = make(root, "2026-11-13_0900", files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello", "notes.md": "minutes"])
    try! model.store.update(dir) { $0.state = .done }
    var queued = recordJSON(dir)
    queued["state"] = "queued"
    queued["job"] = "speakers"
    writeRecord(dir, queued)
    model.queue.enqueue(dir)
    check(settle { model.status.notice?.line == "Redo did not finish" } && runner.calls.isEmpty && isAt(model.status.notice?.folder, dir)
          && model.presentation.button.tint == .amber,
          "R2 app (RR-5): a job this version cannot read ends with the amber line Redo did not finish (\(model.status.notice?.line ?? "-"))")
    model.shutDown()
    try? fm.removeItem(at: state)
}

// MARK: - Redo in the window, round 3

// While a run goes on, nothing is read or written for it in a folder that is not its meeting: the tick follows a
// moved folder, and a meeting renamed onto the old path stays byte-identical (RR2-5, ADV-R2-1).
for movedOut in [true, false] {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    _ = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, tidy: false, writer: .apple))
    let progress = r.runner.calls[0].progress
    try! "transcribing\n".write(to: progress, atomically: false, encoding: .utf8)
    q.tick()
    check(r.json(a)["stage"] as? String == "transcribing", "R3 progress: the stage is followed while the folder is in place")
    let moved = movedOut ? freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
        : r.store.root.appendingPathComponent("2026-11-13 0900 Weekly", isDirectory: true)
    _ = Darwin.rename(a.path, moved.path)
    _ = Darwin.rename(b.path, a.path)
    // the engine appends to the path it was given, which is now inside the other meeting
    try! "transcribing\nminutes\n".write(to: progress, atomically: false, encoding: .utf8)
    let there = snapshot(a)
    let away = snapshot(moved)
    q.tick()
    q.tick()
    check(snapshot(a) == there, "R3 progress: the meeting renamed onto the old path stays byte-identical across ticks (moved \(movedOut ? "out of every root" : "within the root"))")
    if movedOut {
        check(snapshot(moved) == away && q.current == nil && q.hasWork,
              "R3 progress: a running meeting in no root is not pointed at, nor written, while its run goes on")
    } else {
        check(q.current.map { LibraryPresentation.key($0) } == LibraryPresentation.key(moved) && q.hasWork,
              "R3 progress: a running meeting renamed within the root is followed")
    }
    r.runner.calls.first?.done(1, "the meeting folder was moved, nothing was changed")
    check(snapshot(a) == there && !q.hasWork, "R3 progress: and its end leaves that meeting byte-identical too")
}

// A job whose meeting left every root takes its reason from its own outcome, never from a record at the old
// path (ADV-R2-3).
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    let runner = FakeRunner()
    let model = AppModel(stateDir: state, preferences: prefs, recorder: FakeRecorder(), runner: runner, freeBytes: { _ in 50 * GB })
    model.launch()
    let a = make(root, "2026-11-13_0900", files: ["audio.m4a": "a"])
    try! model.store.update(a) { $0.state = .queued }
    let b = make(root, "2026-11-13_1000", files: ["audio.m4a": "a"])
    try! model.store.update(b) { $0.state = .failed; $0.error = "the microphone was off for the whole meeting" }
    model.queue.enqueue(a)
    check(settle { runner.calls.count == 1 }, "R3 reason: the process runs")
    _ = Darwin.rename(a.path, freshRoot().appendingPathComponent("2026-11-13_0900").path)
    _ = Darwin.rename(b.path, a.path)
    let bytes = try? Data(contentsOf: a.appendingPathComponent("meeting.json"))
    runner.calls[0].done(1, "the meeting folder was moved, nothing was changed")
    check(settle { model.status.notice?.kind == .unfinished }
          && model.status.notice?.line == "Minutes could not be written: the meeting folder was moved, nothing was changed"
          && (try? Data(contentsOf: a.appendingPathComponent("meeting.json"))) == bytes,
          "R3 reason: the line gives the job's own reason, not the record now at the old path, which is untouched (\(model.status.notice?.line ?? "-"))")
    model.shutDown()
    try? fm.removeItem(at: state)
}

// The sheet carries the meeting's id: two folders swapped while it is open are refused, both untouched (ADV-R2-4).
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let runner = FakeRunner()
    let model = LibraryModel(store: r.store, session: session, queue: ProcessingQueue(store: r.store, runner: runner, tickQueue: nil))
    let root = r.store.root
    let a = make(root, "2026-11-13_0900", files: ["audio.m4a": "a", "transcript.txt": "a words", "notes.md": "m"])
    try! r.store.update(a) { $0.state = .done; $0.writer = .apple; $0.people = MeetingRecord.People(room: 2, call: 3) }
    let b = make(root, "2026-11-13_1000", files: ["audio.m4a": "a", "transcript.txt": "b words", "notes.md": "m"])
    try! r.store.update(b) { $0.state = .done; $0.writer = .apple; $0.people = MeetingRecord.People(room: 5, call: 1) }
    model.reload()
    check(settle { model.meetings.count == 2 }, "R3 sheet: the meetings are read")
    model.select(LibraryPresentation.key(a))
    check(settle { model.shownContent?.files.runnable == true }, "R3 sheet: and the first one's folder")
    model.perform(.transcribeAgain)
    check(model.redoing?.room == 2 && model.redoing?.id == MeetingStore.record(in: a)?.id, "R3 sheet: the sheet carries the meeting's id")
    let swap = root.appendingPathComponent("swap", isDirectory: true)
    _ = Darwin.rename(a.path, swap.path)
    _ = Darwin.rename(b.path, a.path)
    _ = Darwin.rename(swap.path, b.path)
    let atA = try? Data(contentsOf: a.appendingPathComponent("meeting.json"))
    let atB = try? Data(contentsOf: b.appendingPathComponent("meeting.json"))
    model.commitRedo()
    check(settle { model.redoing == nil } && model.problem == "That meeting is busy" && runner.calls.isEmpty
          && (try? Data(contentsOf: a.appendingPathComponent("meeting.json"))) == atA && (try? Data(contentsOf: b.appendingPathComponent("meeting.json"))) == atB,
          "R3 sheet: another meeting now at the path is refused with That meeting is busy; both meeting.json files are byte-identical")
}

// Pins.
// RR2-1: an id-only match would land on a duplicate whichever order the folder is listed in: one on each side of
// the original's new name.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13 0900 Weekly") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let before = r.store.root.appendingPathComponent("2026-11-13 0900 Aardvark copy", isDirectory: true)
    let after = r.store.root.appendingPathComponent("2026-11-13 0900 Zebra copy", isDirectory: true)
    try! fm.copyItem(at: a, to: before)
    try! fm.copyItem(at: a, to: after)
    let board = r.store.root.appendingPathComponent("2026-11-13 0900 Board", isDirectory: true)
    _ = Darwin.rename(a.path, board.path)
    try! "new minutes\n".write(to: board.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    let (one, two) = (snapshot(before), snapshot(after))
    r.runner.calls.first?.done(0, "")
    check(snapshot(before) == one && snapshot(after) == two && r.state(board) == "done" && r.runner.calls.count == 1,
          "R3 pin (RR2-1): duplicates sorting before and after the original's new name both get nothing; the original ends Done")
}
// RR2-2: a job waiting on another meetingbox whose meeting leaves every root, with another meeting (left
// processing) renamed onto its path: nothing is written or run.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple }
    var other = recordJSON(b)
    other["state"] = "processing"
    other["attempts"] = 1
    other["attempt"] = "att-b"
    writeRecord(b, other)
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    r.lock(a, owner: "\(me) \(lstartOf(me))")
    r.runner.calls.first?.done(75, "this meeting is already being processed")
    let moved = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, moved.path)
    _ = Darwin.rename(b.path, a.path)
    let (there, away) = (snapshot(a), snapshot(moved))
    q.tick()
    q.tick()
    check(snapshot(a) == there && snapshot(moved) == away && r.runner.calls.count == 1 && !q.hasWork
          && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true,
          "R3 pin (RR2-2): a waiting job whose meeting left every root writes and runs nothing, and ends as not done (\(r.runner.calls.count) runs)")
}
// RR2-3: following a moved meeting reads no meeting.json but the one whose folder matches: a sibling's
// meeting.json that is a FIFO is never opened.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let sibling = r.store.root.appendingPathComponent("2026-11-13_1100", isDirectory: true)
    try! fm.createDirectory(at: sibling, withIntermediateDirectories: true)
    let fifo = sibling.appendingPathComponent("meeting.json")
    check(mkfifo(fifo.path, 0o600) == 0, "R3 pin (RR2-3): a sibling's meeting.json is a FIFO")
    let opened = MainSeen()
    let path = fifo.path
    Thread {
        let fd = open(path, O_WRONLY) // waits until something opens it to read
        opened.note(true)
        if fd >= 0 { close(fd) }
    }.start()
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let board = r.store.root.appendingPathComponent("2026-11-13 0900 Board", isDirectory: true)
    _ = Darwin.rename(a.path, board.path)
    try! "new minutes\n".write(to: board.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    r.runner.calls.first?.done(0, "")
    usleep(300_000)
    check(r.state(board) == "done" && opened.seen.isEmpty,
          "R3 pin (RR2-3): the moved meeting is found and Done, and no other meeting.json was opened (\(opened.seen))")
    let release = open(path, O_RDONLY | O_NONBLOCK)
    if release >= 0 { close(release) }
}
// RR2-4: the id half of the match: the same folder whose meeting.json now holds another id is not the job's
// meeting, so nothing is written there and the job ends as not done.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    var replaced = recordJSON(a)
    replaced["id"] = "another-meetings-id"
    writeRecord(a, replaced)
    try! "new minutes\n".write(to: a.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    let before = snapshot(a)
    r.runner.calls.first?.done(0, "")
    check(snapshot(a) == before && r.runner.calls.count == 1 && !q.hasWork && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true,
          "R3 pin (RR2-4): a folder whose meeting.json now holds another id is not the job's meeting: nothing written, ended as not done")
}

// MARK: - Redo in the window, round 4

// A relaunch while the last instance's run still goes on (ADV-R3-2). Quitting never stops a run: the engine
// carries on, holding its live lock. The new queue waits for it before it starts anything else, whether the
// meeting queued behind it is older or newer, for a redo or a plain process. Once the lock goes and the run
// settles, the meeting queued behind it runs once, as its kind.
for (running, waiting, kind) in [("2026-11-13_0900", "2026-11-01_0900", JobKind.minutes),
                                 ("2026-11-01_0900", "2026-11-13_0900", JobKind.minutes),
                                 ("2026-11-13_0900", "2026-11-01_0900", JobKind.process)] {
    let r = QRig()
    var q1: ProcessingQueue? = r.make()
    let made = { (name: String) -> URL in
        kind == .process ? r.meeting(name, files: ["audio.m4a": "a"], queued) : t8Done(r, name) { $0.writer = .apple }
    }
    let ask = { (dir: URL) in
        if kind == .process { q1?.enqueue(dir) } else { _ = q1?.redo(dir, kind: kind, options: JobOptions(writer: .apple)) }
    }
    let a = made(running)
    let b = made(waiting)
    ask(a)
    r.lock(a, owner: "\(me) \(lstartOf(me))") // the engine's own lock, its owner alive
    ask(b)
    let label = "\(kind == .process ? "two processes" : "two redos"), the one queued \(waiting < running ? "older" : "newer")"
    check(r.runner.calls.count == 1 && r.state(a) == "processing" && r.state(b) == "queued",
          "R4 relaunch: before quitting, one run and the other meeting queued (\(label))")
    // Quit: the run goes on, and its end never reaches this instance.
    q1 = nil
    r.queue = nil
    let q2 = r.make()
    q2.resume()
    check(r.runner.calls.count == 1 && q2.stage == "waiting for another meetingbox"
          && q2.current.map { LibraryPresentation.key($0) } == LibraryPresentation.key(a) && r.state(b) == "queued",
          "R4 relaunch: no new run while the last run holds its live lock; the queue waits on it (\(label); runs \(r.runner.folders))")
    // That run ends on its own: what its kind writes, our attempt's result, and its lock gone.
    if kind == .process {
        r.outputs(a, at: Date())
    } else {
        try! "new minutes\n".write(to: a.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }
    r.result(a, attempt: r.attempt(a) ?? "", status: 0, started: Date().addingTimeInterval(-60))
    r.unlock(a)
    q2.tick()
    check(r.state(a) == "done" && r.runner.calls.count == 2 && r.runner.calls[1].job.kind == kind
          && r.runner.calls[1].arguments.first == (kind == .process ? "process" : "notes")
          && LibraryPresentation.key(r.runner.calls[1].job.folder) == LibraryPresentation.key(b),
          "R4 relaunch: once it goes and settles Done, the meeting queued behind it runs, as its kind (\(label))")
    if kind == .process { r.runner.finish(1, 0) } else { r.runner.finishNotes(1, 0) }
    q2.tick()
    check(r.state(b) == "done" && r.runner.calls.count == 2 && !q2.hasWork, "R4 relaunch: and runs once (\(label))")
}
// Each group keeps its order: two runs the last instance left part way (no lock, no result) run again oldest
// first, and then the meeting found queued, though it is older than both.
do {
    let r = QRig()
    let older = r.meeting("2026-11-01_0900", queued)
    let p1 = r.meeting("2026-11-02_0900") { $0.state = .processing; $0.attempts = 1; $0.attempt = "attempt-one" }
    let p2 = r.meeting("2026-11-03_0900") { $0.state = .processing; $0.attempts = 1; $0.attempt = "attempt-two" }
    let q = r.make()
    q.resume()
    for i in 0..<3 { r.runner.finish(i, 0) }
    check(r.runner.folders == [p1, p2, older].map { $0.lastPathComponent } && [older, p1, p2].allSatisfy { r.state($0) == "done" } && !q.hasWork,
          "R4 relaunch: the meetings found processing run first, oldest first, then those found queued (\(r.runner.folders))")
}

// A running meeting that left every root and comes back is followed again (R3-1, ADV-R3-1): to the path it was
// last found at (Finder's Undo, a volume back), or under another name in the root. It is current again, onChange
// tells the menu bar, and its progress is read; its run then ends there.
for samePath in [true, false] {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, tidy: false, writer: .apple))
    try! "transcribing\n".write(to: r.runner.calls[0].progress, atomically: false, encoding: .utf8)
    q.tick()
    let away = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, away.path)
    q.tick()
    let label = samePath ? "to the same path" : "under another name in the root"
    check(q.current == nil && q.hasWork && q.stage == "transcribing", "R4 back: while it is in no root, it is not current (\(label))")
    let back = samePath ? a : r.store.root.appendingPathComponent("2026-11-13 0900 Weekly", isDirectory: true)
    _ = Darwin.rename(away.path, back.path)
    try! "transcribing\nminutes\n".write(to: back.appendingPathComponent(".process-progress"), atomically: false, encoding: .utf8)
    let told = r.changes
    q.tick()
    check(q.current.map { LibraryPresentation.key($0) } == LibraryPresentation.key(back) && r.changes > told,
          "R4 back: once it comes back it is current again, and onChange is called (\(label))")
    check(q.stage == "minutes" && r.json(back)["stage"] as? String == "minutes", "R4 back: and its progress is read again (\(label))")
    try! "[00:00:01] Me: again\n".write(to: back.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    try! "new minutes\n".write(to: back.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    r.runner.calls[0].done(0, "")
    check(r.state(back) == "done" && r.runner.calls.count == 1 && !q.hasWork
          && r.finished.last.map { $0 == (back.lastPathComponent, true) } == true,
          "R4 back: and its run ends Done there, once (\(label))")
}

// A job that ends where its meeting cannot be found gives exactly this reason when its own run says nothing better
// (R3-2, R3-3): the window and the docs quote it.
let lostReason = "the meeting folder was moved where meetingbox cannot find it"
// Exit 0 after the meeting left every root.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    _ = Darwin.rename(a.path, freshRoot().appendingPathComponent("2026-11-13_0900").path)
    r.runner.calls[0].done(0, "")
    check(!q.hasWork && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true && r.reasons.last == lostReason,
          "R4 reason: exit 0 with the meeting in no root ends as not done, with the lost-folder reason (\(r.reasons.last.flatMap { $0 } ?? "nil"))")
}
// Exit 75 after the meeting left every root, with another meeting renamed onto its old path: nothing is written in
// either folder (no attempts given back, no waiting stage), nothing more runs, and the job ends as not done.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    let b = t8Done(r, "2026-11-13_1000") { $0.writer = .apple; $0.attempts = 2 }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    let moved = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, moved.path)
    _ = Darwin.rename(b.path, a.path)
    let (there, away) = (snapshot(a), snapshot(moved))
    r.runner.calls[0].done(75, "this meeting is already being processed")
    q.tick()
    q.tick()
    check(snapshot(a) == there && snapshot(moved) == away && r.runner.calls.count == 1 && !q.hasWork
          && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true,
          "R4 exit 75 in no root: both folders byte-identical, one run, ended as not done (\(r.runner.calls.count) runs)")
    check(r.reasons.last == lostReason,
          "R4 reason: exit 75 with the meeting in no root gives the lost-folder reason (\(r.reasons.last.flatMap { $0 } ?? "nil"))")
}
// A queued turn whose meeting left every root.
do {
    let r = QRig()
    let q = r.make()
    let first = t8Done(r, "2026-11-13_0800") { $0.writer = .apple }
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(first, kind: .minutes, options: JobOptions(writer: .apple))
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    _ = Darwin.rename(a.path, freshRoot().appendingPathComponent("2026-11-13_0900").path)
    r.runner.finishNotes(0, 0)
    check(r.runner.calls.count == 1 && !q.hasWork && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true
          && r.reasons.last == lostReason,
          "R4 reason: a queued turn whose meeting is in no root runs nothing, with the lost-folder reason (\(r.reasons.last.flatMap { $0 } ?? "nil"))")
}
// A job waiting on another meetingbox whose meeting left every root.
do {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .minutes, options: JobOptions(writer: .apple))
    r.lock(a, owner: "\(me) \(lstartOf(me))")
    r.runner.calls[0].done(75, "this meeting is already being processed")
    _ = Darwin.rename(a.path, freshRoot().appendingPathComponent("2026-11-13_0900").path)
    q.tick()
    check(r.runner.calls.count == 1 && !q.hasWork && r.finished.last.map { $0 == (a.lastPathComponent, false) } == true
          && r.reasons.last == lostReason,
          "R4 reason: a waiting job whose meeting is in no root ends with the lost-folder reason (\(r.reasons.last.flatMap { $0 } ?? "nil"))")
}

// MARK: - Redo in the window, round 5

// At a relaunch the run the last instance left going is waited for before anything else starts, whatever the
// dates (R4RR-1). A meeting left processing whose lock is live, or whose owner ps cannot tell, comes before one
// left processing whose lock is gone (a crash leftover, here older), and both before the meeting queued. Once the
// live run settles, the leftover runs again once, as its kind, and then the queued one, one at a time. The same
// holds with the dates swapped.
for (kind, unknown, swapped) in [(JobKind.process, false, false), (JobKind.process, true, false), (JobKind.minutes, false, false),
                                 (JobKind.transcribe, false, false), (JobKind.process, false, true)] {
    let r = QRig()
    func left(_ name: String, _ change: @escaping (inout MeetingRecord) -> Void) -> URL {
        if kind == .process { return r.meeting(name, files: ["audio.m4a": "a"], change) }
        return t8Done(r, name) {
            $0.writer = .apple
            $0.job = kind
            if kind == .transcribe { $0.jobTranscriber = .apple; $0.jobTidy = false }
            change(&$0)
        }
    }
    let (liveName, deadName) = swapped ? ("2026-11-01_0900", "2026-11-13_0900") : ("2026-11-13_0900", "2026-11-01_0900")
    let dead = left(deadName) { $0.state = .processing; $0.attempts = 1; $0.attempt = "att-old" } // no lock, no result
    let waiting = left("2026-11-05_0900") { $0.state = .queued }
    let live = left(liveName) { $0.state = .processing; $0.attempts = 1; $0.attempt = "att-new" }
    r.lock(live, owner: "\(me) \(lstartOf(me))") // the last instance's engine, still at work
    let q = r.make(ps: URL(fileURLWithPath: unknown ? "/no-such-ps" : "/bin/ps"))
    q.resume()
    let label = "\(kind), the live lock \(unknown ? "unknown to ps" : "alive"), the leftover \(swapped ? "newer" : "older")"
    check(r.runner.calls.isEmpty && q.stage == "waiting for another meetingbox"
          && q.current.map { LibraryPresentation.key($0) } == LibraryPresentation.key(live),
          "R5 relaunch: no run while a meeting left processing holds a live lock; the queue waits on it (\(label); runs \(r.runner.folders))")
    // The live run ends on its own: what its kind writes, our attempt's result, and its lock gone.
    if kind == .minutes {
        try! "new minutes\n".write(to: live.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    } else {
        r.outputs(live, at: Date())
    }
    r.result(live, attempt: "att-new", status: 0, started: Date().addingTimeInterval(-60))
    r.unlock(live)
    q.tick()
    check(r.state(live) == "done" && r.runner.calls.count == 1 && r.runner.calls[0].job.kind == kind && r.runner.calls[0].attemptsAtRun == 2
          && LibraryPresentation.key(r.runner.calls[0].job.folder) == LibraryPresentation.key(dead),
          "R5 relaunch: once it settles Done, the leftover runs again, as its kind, at attempts 2 (\(label))")
    if kind == .minutes { r.runner.finishNotes(0, 0) } else { r.runner.finish(0, 0) }
    check(r.state(dead) == "done" && r.runner.calls.count == 2 && r.runner.calls[1].job.kind == kind
          && LibraryPresentation.key(r.runner.calls[1].job.folder) == LibraryPresentation.key(waiting),
          "R5 relaunch: then the queued one runs (\(label))")
    if kind == .minutes { r.runner.finishNotes(1, 0) } else { r.runner.finish(1, 0) }
    check(r.state(waiting) == "done" && r.runner.calls.count == 2 && !q.hasWork, "R5 relaunch: and each runs once (\(label))")
}

// The running tick (R4RR-2): while the folder it was last found in is still the job's meeting, a tick with nothing
// new searches no root and tells onChange nothing. A lost run that comes back with no new stage written is current
// again and onChange is told once, whether it is back at the same path or under another name; later ticks with
// nothing new tell it nothing.
for samePath in [true, false] {
    let r = QRig()
    let q = r.make()
    let a = t8Done(r, "2026-11-13_0900") { $0.writer = .apple }
    _ = q.redo(a, kind: .transcribe, options: JobOptions(transcriber: .apple, tidy: false, writer: .apple))
    try! "transcribing\n".write(to: r.runner.calls[0].progress, atomically: false, encoding: .utf8)
    q.tick()
    let label = samePath ? "to the same path" : "under another name in the root"
    var (told, reads) = (r.changes, r.rootReads.count)
    q.tick()
    q.tick()
    check(q.stage == "transcribing" && r.changes == told && r.rootReads.count == reads,
          "R5 tick: while its folder is in place, a tick with nothing new searches no root and tells onChange nothing (\(label); \(r.rootReads.count - reads) searches, \(r.changes - told) changes)")
    let away = freshRoot().appendingPathComponent("2026-11-13_0900", isDirectory: true)
    _ = Darwin.rename(a.path, away.path)
    reads = r.rootReads.count
    q.tick()
    check(q.current == nil && r.rootReads.count > reads, "R5 tick: once it is gone, the roots are searched (\(label))")
    let back = samePath ? a : r.store.root.appendingPathComponent("2026-11-13 0900 Weekly", isDirectory: true)
    _ = Darwin.rename(away.path, back.path) // its progress file unchanged: no new stage
    told = r.changes
    q.tick()
    check(q.current.map { LibraryPresentation.key($0) } == LibraryPresentation.key(back) && q.stage == "transcribing" && r.changes == told + 1,
          "R5 back: a lost run that comes back with no new stage is current again, and onChange is told once (\(label); \(r.changes - told) changes)")
    (told, reads) = (r.changes, r.rootReads.count)
    q.tick()
    q.tick()
    check(r.changes == told && r.rootReads.count == reads,
          "R5 back: later ticks with nothing new search no root and tell onChange nothing (\(label); \(r.rootReads.count - reads) searches, \(r.changes - told) changes)")
}

// MARK: - Recording controls and a simple player in the window's top bar (Stage 3, Task 9)

/// Stands in for AVAudioPlayer, and never makes a sound. `load` fails, as AVAudioPlayer does, for a file
/// that cannot be read; the position is the test's to move, as time would while playing. `load` runs on
/// the player's load queue, so what it records is behind a lock. With `gate` it waits, as a slow disk
/// would, for at most 3 s, so a load wrongly made on the main queue holds a test up but never hangs it.
final class FakeAudio: AudioPlaying {
    private let lock = NSLock()
    private var said: [String] = []
    private var opened: [URL] = []
    private var threads: [Bool] = []
    /// For each load, whether it ran on the main thread.
    var loadedOnMain: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return threads
    }
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return said
    }
    var loads: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }
    /// A load is running on the load queue; a call made meanwhile is noted as made during a load.
    private var inLoad = false
    private func note(_ call: String, opening url: URL? = nil) {
        lock.lock()
        if let url = url { opened.append(url) } else { said.append(inLoad ? call + " during a load" : call) }
        lock.unlock()
    }
    private func loading(_ on: Bool) {
        lock.lock()
        inLoad = on
        lock.unlock()
    }
    var isLoading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inLoad
    }
    /// The length a file that loads has.
    var length: Double = 3900
    private var held: DispatchSemaphore?
    var gate: DispatchSemaphore? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        set {
            lock.lock()
            held = newValue
            lock.unlock()
        }
    }
    /// A play that does not start (no output device, say): SystemAudio then reads its position as the end.
    var playFails = false
    private var at: Double = 0
    /// How many times the position was read: once a tick while playing.
    private(set) var positionReads = 0
    var position: Double {
        get {
            positionReads += 1
            return at
        }
        set { at = newValue }
    }
    private(set) var duration: Double = 0
    /// Told at each stop, as it is asked for.
    var onStop: (() -> Void)?
    func load(_ url: URL) throws {
        let wait = gate // read before it says it is loading, so a test may swap gates once it is
        lock.lock()
        threads.append(Thread.isMainThread)
        lock.unlock()
        note("load")
        loading(true)
        defer { loading(false) }
        _ = wait?.wait(timeout: .now() + 3)
        duration = 0
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw FakeError(text: "cannot open \(url.path)") }
        note("", opening: url)
        duration = length
        at = 0
    }
    func play() {
        note("play")
        if playFails { at = duration }
    }
    func pause() { note("pause") }
    func stop() {
        note("stop")
        onStop?()
    }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
}

/// Set from a closure the main queue runs later.
final class Flag {
    var on = false
}

let on = { (title: String) in TopBar.Control(title: title, enabled: true) }
let off = { (title: String) in TopBar.Control(title: title, enabled: false) }

// What the bar shows and enables, in the exact words (TopBarPresentation): pure, from its arguments alone.
do {
    let here = libURL("2026-11-14_0900")
    let other = libURL("2026-11-13_0900")
    let file = here.appendingPathComponent("audio.m4a")
    let otherFile = other.appendingPathComponent("audio.m4a")
    func bar(_ phase: Session.Phase = .idle, seconds: Int = 0, sampling: Bool = false, player: PlayerState = .idle,
             selected: URL? = here, audio: URL? = file, at position: Double = 0, of duration: Double = 3900) -> TopBar {
        TopBarPresentation.bar(phase: phase, seconds: seconds, sampling: sampling, player: player, selected: selected, audio: audio,
                               position: position, duration: duration)
    }

    // The recording's controls, whichever meeting is selected.
    for selected in [here, other, nil] as [URL?] {
        let name = selected?.lastPathComponent ?? "none"
        check(bar(.recording(other), seconds: 754, selected: selected).recording
              == TopBar.Recording(timer: "12:34", toggle: on("Pause"), toggleAction: .pause, stop: on("Stop"), stopAction: .stop),
              "T9 bar: while recording, the timer, Pause and Stop, whichever meeting is selected (\(name))")
        check(bar(.paused(other), seconds: 3900, selected: selected).recording
              == TopBar.Recording(timer: "1:05:00", toggle: on("Resume"), toggleAction: .resume, stop: on("Stop"), stopAction: .stop),
              "T9 bar: while paused, the timer, Resume and Stop (\(name))")
    }
    check(bar(.recording(other), seconds: 7).recording?.timer == Preferences.timerText(7), "T9 bar: the timer reads as the menu bar's does")
    check(bar(.idle).recording == nil && bar(.finalising(other)).recording == nil, "T9 bar: no recording controls while idle or while the last recording is saved")
    check(bar(.recording(other), sampling: true, player: .playing(file)).recording?.toggleAction == .pause, "T9 bar: the recording's controls do not depend on the player")

    // The player.
    check(bar().player == TopBar.Playback(file: file, playing: false, toggle: on("Play"), stop: off("Stop"), position: "0:00 / 1:05:00",
                                          problem: nil, canSeek: false, value: 0, length: 3900),
          "T9 bar: nothing recording and a meeting with audio selected: Play, Stop and 0:00 / 1:05:00 (\(String(describing: bar().player)))")
    let playing = bar(player: .playing(file), at: 754).player
    check(playing?.playing == true && playing?.toggle == on("Pause") && playing?.stop == on("Stop") && playing?.position == "12:34 / 1:05:00"
          && playing?.canSeek == true && playing?.value == 754 && playing?.length == 3900,
          "T9 bar: playing: Pause, Stop, 12:34 / 1:05:00, and the slider at the position")
    let paused = bar(player: .paused(file), at: 754).player
    check(paused?.playing == false && paused?.toggle == on("Play") && paused?.stop == on("Stop") && paused?.position == "12:34 / 1:05:00"
          && paused?.canSeek == true, "T9 bar: paused: Play again, Stop, and the slider")
    check(bar(at: 754).player?.position == "0:00 / 1:05:00" && bar(at: 754).player?.value == 0, "T9 bar: with nothing loaded the position is the start")

    // A selected meeting with no audio says why (F1), unless it is the one being recorded or saved, or its
    // recording is unfinished (the app then passes no `selected`).
    let none = bar(audio: nil).player
    check(none?.file == nil && none?.toggle == off("Play") && none?.stop == off("Stop") && none?.problem == "This recording cannot be played"
          && none?.canSeek == false,
          "T9 bar: a finished meeting with no audio shows the player with Play disabled and This recording cannot be played (\(String(describing: none)))")
    check(bar(.recording(other), audio: nil).player?.problem == "This recording cannot be played",
          "T9 bar: and says so while another meeting records")
    check(bar(.recording(here), audio: nil).player == nil && bar(.paused(here), audio: nil).player == nil
          && bar(.finalising(here), audio: nil).player == nil,
          "T9 bar: the meeting being recorded, paused or saved shows nothing about audio it does not have yet")
    check(bar(selected: nil, audio: nil).player == nil, "T9 bar: nothing selected (or a meeting unread or unfinished): no player")
    check(bar(selected: nil).player?.file == file && bar(selected: nil).player?.problem == nil,
          "T9 bar: audio there is offered, whatever else the meeting is (an unfinished one with a part-saved audio.m4a)")
    let folder = here
    check(TopBarPresentation.selected(folder, files: nil) == nil && TopBarPresentation.selected(nil, files: MeetingFiles()) == nil
          && TopBarPresentation.selected(folder, files: MeetingFiles(unfinished: true)) == nil
          && TopBarPresentation.selected(folder, files: MeetingFiles()) == folder,
          "T9 selected: a meeting counts once its folder has been read and its recording is finished")

    // Play is offered only while the session is idle and no sample records: not while recording, paused or saving.
    check(bar(.recording(other)).player?.toggle == off("Play") && bar(.recording(here)).player?.toggle == off("Play"),
          "T9 bar: Play is disabled while recording")
    check(bar(.paused(other)).player?.toggle == off("Play"), "T9 bar: and while paused")
    check(bar(sampling: true).player?.toggle == off("Play") && bar(sampling: true, player: .paused(file)).player?.toggle == off("Play"),
          "T9 bar: and while a voice sample records")
    check(bar(.finalising(other)).player?.toggle == off("Play"), "T9 bar: and while the last recording is being saved (it may still be capturing)")
    // What the player holds is what Play, Pause and Stop act on, and it can always be paused and stopped.
    let held = bar(player: .playing(otherFile)).player
    check(held?.file == otherFile && held?.toggle == on("Pause") && held?.stop == on("Stop"),
          "T9 bar: the file the player holds is the one its buttons act on")
    check(bar(.recording(other), sampling: true, player: .playing(file)).player?.toggle == on("Pause")
          && bar(.recording(other), player: .paused(file)).player?.stop == on("Stop"),
          "T9 bar: something playing can always be paused and stopped")
    check(bar(player: .paused(file), selected: nil, audio: nil).player?.file == file, "T9 bar: a file the player holds stays in the bar though nothing is selected")

    // A file that cannot be played.
    let failed = bar(player: .failed("This recording cannot be played")).player
    check(failed?.problem == "This recording cannot be played" && failed?.toggle == on("Play") && failed?.stop == off("Stop")
          && failed?.canSeek == false && failed?.file == file,
          "T9 bar: a failure says This recording cannot be played, and Play can try again")
    check(TopBarPresentation.cannotPlay == "This recording cannot be played", "T9 words: This recording cannot be played")

    // Times, and lengths.
    let times = [0, 0.9, 59.99, 60, 754, 3599, 3600, 3900, 36000, .nan, -5].map(TopBarPresentation.time)
    check(times == ["0:00", "0:00", "0:59", "1:00", "12:34", "59:59", "1:00:00", "1:05:00", "10:00:00", "0:00", "0:00"],
          "T9 bar: times as 12:34 and 1:05:00 (\(times))")
    check(Preferences.timerText(754) == "12:34" && Preferences.timerText(5) == "00:05" && Preferences.timerText(3900) == "1:05:00",
          "T9 bar: the menu bar's timer is as it was")
    check(bar(of: 0).player?.position == "0:00" && bar(of: 0).player?.length == 1, "T9 bar: with no known length, the position alone, and the slider keeps a range")
    check(bar(player: .playing(file), at: 5000).player?.position == "1:05:00 / 1:05:00" && bar(player: .playing(file), at: -3).player?.value == 0,
          "T9 bar: a position outside the file is shown within it")
    check(TopBarPresentation.length(loaded: 61.5, recorded: 3900) == 61.5 && TopBarPresentation.length(loaded: 0, recorded: 3900) == 3900
          && TopBarPresentation.length(loaded: 0, recorded: -1) == 0,
          "T9 length: the loaded file's length, else the meeting's recorded length")
}

// Only a regular file is ever loaded: never a link, a FIFO (which would block the open), a folder or a device.
do {
    let dir = make(freshRoot(), "2026-11-14_0930", files: ["audio.m4a": "a"])
    let plain = dir.appendingPathComponent("audio.m4a")
    let link = dir.appendingPathComponent("link.m4a")
    try! fm.createSymbolicLink(at: link, withDestinationURL: plain)
    let fifo = dir.appendingPathComponent("fifo.m4a")
    check(mkfifo(fifo.path, 0o600) == 0, "T9 plain file: (a FIFO is made)")
    let folder = dir.appendingPathComponent("folder.m4a", isDirectory: true)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    check(Player.isPlainFile(plain) && !Player.isPlainFile(link) && !Player.isPlainFile(fifo) && !Player.isPlainFile(folder)
          && !Player.isPlainFile(URL(fileURLWithPath: "/dev/null")) && !Player.isPlainFile(dir.appendingPathComponent("gone.m4a")),
          "T9 plain file: a regular file is one; a link, a FIFO, a folder, a device and nothing at all are not")
    let fake = FakeAudio()
    let player = Player(audio: fake, tickQueue: nil, loadQueue: nil)
    for (name, url) in [("a link", link), ("a FIFO", fifo), ("a folder", folder), ("a device", URL(fileURLWithPath: "/dev/null"))] {
        player.toggle(url)
        check(player.state == .failed("This recording cannot be played") && fake.count("load") == 0 && fake.count("play") == 0,
              "T9 plain file: Play on \(name) fails, saying This recording cannot be played, and nothing is opened (\(fake.calls))")
        player.stop()
    }
}

// The player over a fake, with no tick queue and loading in line: Play and Pause, Stop, the slider, ticks,
// the end of the file, failure.
do {
    let fake = FakeAudio()
    let player = Player(audio: fake, tickQueue: nil, loadQueue: nil)
    let dir = make(freshRoot(), "2026-11-14_0900", files: ["audio.m4a": "a", "other.m4a": "o", "locked.m4a": "l"])
    let file = dir.appendingPathComponent("audio.m4a")
    let otherFile = dir.appendingPathComponent("other.m4a")
    check(player.state == .idle && player.position == 0 && player.duration == 0 && !player.ticking && fake.calls.isEmpty,
          "T9 player: idle at first, touching nothing")
    player.toggle(file)
    check(player.state == .playing(file) && fake.calls.suffix(2) == ["load", "play"] && player.duration == 3900 && player.position == 0,
          "T9 player: Play loads the file and plays it from the start (\(fake.calls))")
    check(!player.ticking, "T9 player: with no tick queue there is no timer")
    for s in [1.0, 2.0, 3.0] {
        fake.position = s
        player.tick()
    }
    check(player.position == 3, "T9 player: each tick while playing reads the position")
    player.toggle(file)
    check(player.state == .paused(file) && fake.calls.last == "pause" && player.position == 3, "T9 player: Play then Pause toggles")
    fake.position = 9
    player.tick()
    check(player.position == 3, "T9 player: no tick moves it while paused")
    player.seek(to: 754)
    check(fake.position == 754 && player.position == 754 && player.state == .paused(file), "T9 player: the slider moves the position while paused")
    player.toggle(file)
    check(player.state == .playing(file) && fake.loads.count == 1 && fake.calls.last == "play", "T9 player: Play again carries on, without loading again")
    player.seek(to: 99999)
    let atEnd = (fake.position, player.position)
    player.seek(to: -5)
    check(atEnd == (3900, 3900) && fake.position == 0 && player.position == 0, "T9 player: the slider stays within the file")
    player.seek(to: 60)
    player.stop()
    check(player.state == .idle && player.position == 0 && fake.position == 0 && fake.calls.last == "stop" && player.duration == 0,
          "T9 player: Stop returns the position to 0")
    player.seek(to: 30)
    check(fake.position == 0 && player.position == 0, "T9 player: the slider does nothing with nothing loaded")

    // Only a change is published.
    player.toggle(file)
    var told = 0
    let watch = player.objectWillChange.sink { _ in told += 1 }
    fake.position = 0
    player.tick()
    check(told == 0, "T9 player: a tick with nothing new publishes nothing")
    fake.position = 1
    player.tick()
    check(told == 1, "T9 player: one that moves it publishes once")
    watch.cancel()

    // The end of the file.
    fake.position = 3900
    player.tick()
    check(player.state == .idle && player.position == 0 && fake.position == 0 && fake.calls.last == "stop",
          "T9 player: at the end of the file it stops, back at the start")

    // Another file, and ones that cannot be played.
    player.toggle(file)
    player.toggle(otherFile)
    check(player.state == .playing(otherFile) && fake.loads.suffix(1) == [otherFile], "T9 player: Play on another file plays that one")
    let loadsBefore = fake.loads.count
    player.toggle(dir.appendingPathComponent("gone.m4a"))
    check(player.state == .failed("This recording cannot be played") && fake.calls.last == "stop" && fake.loads.count == loadsBefore
          && player.position == 0 && player.duration == 0,
          "T9 player: a missing file fails, saying This recording cannot be played: the file held is let go and nothing else is opened (\(fake.calls.suffix(3)))")
    player.seek(to: 10)
    player.tick()
    check(player.position == 0 && player.state == .failed("This recording cannot be played"), "T9 player: nothing moves once it has failed")
    let locked = dir.appendingPathComponent("locked.m4a")
    chmod(locked.path, 0)
    player.toggle(locked)
    check(player.state == .failed("This recording cannot be played") && fake.calls.last == "load" && fake.loads.count == loadsBefore,
          "T9 player: an unreadable file is tried and fails the same way")
    chmod(locked.path, 0o644)
    player.stop()
    check(player.state == .idle, "T9 player: Stop clears a failure")
    told = 0
    let quiet = player.objectWillChange.sink { _ in told += 1 }
    player.stop()
    check(told == 0 && fake.calls.last == "load", "T9 player: Stop with nothing loaded publishes nothing and touches nothing")
    quiet.cancel()

    // A play that does not start (T9-ADV-5): it says so, rather than seeming to reach the end a tick later.
    fake.playFails = true
    player.toggle(file)
    check(player.state == .failed("This recording cannot be played") && fake.calls.suffix(2) == ["play", "stop"] && !player.ticking
          && player.duration == 0,
          "T9 player: a play that does not start fails, saying This recording cannot be played, and lets the file go (\(fake.calls.suffix(3)))")
    fake.playFails = false
    // Carrying on from the very end is a real end, not a failure.
    player.toggle(file)
    player.seek(to: 3900)
    player.toggle(file)
    check(player.state == .paused(file) && player.position == 3900, "T9 player: (paused at the end)")
    player.toggle(file)
    check(player.state == .playing(file), "T9 player: Play at the very end carries on, and is not taken for a failure")
    player.tick()
    check(player.state == .idle && player.position == 0, "T9 player: and the next tick is the end of the file")
}

// The timer: with a tick queue, one 1 s timer exists only while playing, really cancelled, and never keeping the player alive.
MainActor.assumeIsolated {
    let fake = FakeAudio()
    let player = Player(audio: fake, tickQueue: .main, loadQueue: nil)
    let dir = make(freshRoot(), "2026-11-14_1000", files: ["audio.m4a": "a", "other.m4a": "o"])
    let file = dir.appendingPathComponent("audio.m4a")
    check(!player.ticking, "T9 timer: none before Play")
    player.toggle(file)
    check(player.ticking, "T9 timer: Play starts it")
    fake.position = 5
    check(settle({ player.position == 5 }, timeout: 3), "T9 timer: it ticks while playing")
    player.toggle(file)
    check(!player.ticking && player.state == .paused(file), "T9 timer: Pause cancels it")
    fake.position = 8
    _ = settle({ false }, timeout: 1.5)
    check(player.position == 5, "T9 timer: and nothing moves while paused")
    player.toggle(file)
    check(player.ticking, "T9 timer: Play again starts it again")
    player.toggle(dir.appendingPathComponent("other.m4a"))
    check(player.ticking, "T9 timer: Play on another file keeps one running")
    player.stop()
    check(!player.ticking, "T9 timer: Stop cancels it")
    player.toggle(file)
    fake.position = fake.length
    player.tick()
    check(!player.ticking && player.state == .idle, "T9 timer: the end of the file cancels it")
    player.toggle(file)
    player.toggle(dir.appendingPathComponent("gone.m4a"))
    check(!player.ticking && player.state == .failed("This recording cannot be played"), "T9 timer: a failure cancels it")

    // Each Pause, Stop and failure cancels its timer, not only forgets it (Q1): after Play, Pause, Play, Pause,
    // Play, one timer ticks, about twice in 2.5 s, not several times as fast.
    for _ in 0..<5 { player.toggle(file) }
    check(player.state == .playing(file), "T9 timer: (playing again after Play, Pause, Play, Pause, Play)")
    var reads = fake.positionReads
    _ = settle({ false }, timeout: 2.5)
    reads = fake.positionReads - reads
    check((1...3).contains(reads), "T9 timer: only one timer ticks, once a second, so every earlier one was cancelled (\(reads) ticks in 2.5 s)")
    player.stop()

    // A player let go while playing is freed, and its timer never ticks again: the timer holds it weakly.
    weak var gone: Player?
    let lone = FakeAudio()
    do {
        let held = Player(audio: lone, tickQueue: .main, loadQueue: nil)
        held.toggle(file)
        gone = held
    }
    let readsBefore = lone.positionReads
    _ = settle({ false }, timeout: 1.5)
    check(gone == nil && lone.positionReads == readsBefore,
          "T9 timer: a Player let go while playing is freed, and no tick comes after (\(lone.positionReads - readsBefore) ticks)")
}

// The real player refuses what cannot be played, without playing anything; without one, nothing plays at all.
MainActor.assumeIsolated {
    let dir = make(freshRoot(), "2026-11-14_1100", files: ["audio.m4a": "these bytes are not audio"])
    let real = SystemAudio()
    var missing = false, notAudio = false
    do { try real.load(dir.appendingPathComponent("gone.m4a")) } catch { missing = true }
    do { try real.load(dir.appendingPathComponent("audio.m4a")) } catch { notAudio = true }
    check(missing && notAudio && real.duration == 0 && real.position == 0,
          "T9 SystemAudio: AVAudioPlayer refuses a missing file and one that is not audio, so the player says so")
    var refused = false
    do { try NoAudio().load(dir.appendingPathComponent("audio.m4a")) } catch { refused = true }
    check(refused, "T9 NoAudio: without a real player every file is refused")
    let state = shortTemp()
    let prefs = Preferences(defaults: testDefaults(), home: freshRoot())
    prefs.meetingsFolder = freshRoot()
    let plain = AppModel(stateDir: state, preferences: prefs, recorder: FakeRecorder(), runner: FakeRunner(), freeBytes: { _ in 50 * GB })
    plain.player.toggle(dir.appendingPathComponent("audio.m4a"))
    check(plain.player.audio is NoAudio && settle { plain.player.state == .failed("This recording cannot be played") } && !plain.player.ticking,
          "T9 app: an AppModel built without a player has NoAudio and plays nothing (only AppDelegate passes the real one)")
    try? fm.removeItem(at: state)
}

// The top bar in the app: the recording's controls through perform, the player, and playback never
// overlapping a recording or a voice sample, whatever starts it.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    let rec = FakeRecorder()
    let engine = FakeEngine()
    let sampler = FakeSampler()
    let audio = FakeAudio()
    let player = Player(audio: audio, tickQueue: nil, loadQueue: nil)
    let app = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                       engine: engine, sampler: sampler, player: player)
    let a = make(root, "2026-11-12_0900", files: ["audio.m4a": "a", "notes.md": "the minutes"])
    try! app.store.update(a) { $0.state = .done; $0.seconds = 3900 }
    let b = make(root, "2026-11-11_0900", files: ["audio.m4a": "b"])
    try! app.store.update(b) { $0.state = .done; $0.seconds = 754 }
    let fileA = a.appendingPathComponent("audio.m4a"), fileB = b.appendingPathComponent("audio.m4a")
    app.launch()
    app.library.reload()
    @MainActor func choose(_ dir: URL) -> Bool {
        app.library.select(LibraryPresentation.key(dir))
        return settle { isAt(app.library.shownContent?.files.audio?.deletingLastPathComponent(), dir) }
    }
    /// Selects a meeting and waits until its folder has been read, audio or none.
    @MainActor func read(_ dir: URL) -> Bool {
        app.library.select(LibraryPresentation.key(dir))
        return settle { app.library.shownContent?.key == LibraryPresentation.key(dir) }
    }
    @MainActor func plays(_ f: URL) -> Bool { if case .playing(let u) = player.state { return isAt(u, f) }; return false }
    @MainActor func holdsPaused(_ f: URL) -> Bool { if case .paused(let u) = player.state { return isAt(u, f) }; return false }
    @MainActor func phaseIs(_ wanted: String) -> Bool {
        switch (wanted, app.status.phase) {
        case ("recording", .recording), ("paused", .paused), ("finalising", .finalising), ("idle", .idle): return true
        default: return false
        }
    }
    let cannotPlay = PlayerState.failed("This recording cannot be played")

    check(choose(a), "T9 app: (meeting A is selected and its audio found)")
    var bar = app.topBar
    check(bar.recording == nil && bar.player?.toggle == on("Play") && bar.player?.stop == off("Stop") && bar.player?.position == "0:00 / 1:05:00"
          && isAt(bar.player?.file, fileA),
          "T9 app: nothing recording and a meeting with audio selected: Play, Stop and 0:00 / its recorded length (\(String(describing: bar.player)))")
    app.togglePlayer()
    check(plays(fileA) && audio.loads.count == 1 && app.topBar.player?.toggle == on("Pause"), "T9 app: Play plays the selected meeting's audio in the app")

    // Three ticks with no job queued advance the position; the rest of the window is not told.
    check(!app.queue.hasWork && app.status.processing == nil, "T9 app: (no job is queued)")
    var appTold = 0, libraryTold = 0
    let watchApp = app.objectWillChange.sink { _ in appTold += 1 }
    let watchLibrary = app.library.objectWillChange.sink { _ in libraryTold += 1 }
    var texts: [String] = []
    for s in [1.0, 2.0, 3.0] {
        audio.position = s
        player.tick()
        texts.append(app.topBar.player?.position ?? "")
    }
    check(texts == ["0:01 / 1:05:00", "0:02 / 1:05:00", "0:03 / 1:05:00"], "T9 app: with no job queued, three ticks while playing advance the position text (\(texts))")
    check(appTold == 0 && libraryTold == 0, "T9 app: and neither the app nor the window is told: only the player's own view follows it")
    watchApp.cancel()
    watchLibrary.cancel()
    app.togglePlayer()
    check(holdsPaused(fileA) && app.topBar.player?.toggle == on("Play"), "T9 app: Play then Pause toggles")
    texts = []
    for s in [4.0, 5.0, 6.0] {
        audio.position = s
        player.tick()
        texts.append(app.topBar.player?.position ?? "")
    }
    check(texts == Array(repeating: "0:03 / 1:05:00", count: 3), "T9 app: and no tick moves it while paused (\(texts))")
    app.seekPlayer(to: 754)
    check(app.topBar.player?.position == "12:34 / 1:05:00" && audio.position == 754, "T9 app: the slider moves the position")
    app.togglePlayer()
    check(plays(fileA) && audio.loads.count == 1, "T9 app: Play again carries on from there")
    app.stopPlayer()
    bar = app.topBar
    check(player.state == .idle && bar.player?.position == "0:00 / 1:05:00" && audio.position == 0 && bar.player?.stop == off("Stop")
          && bar.player?.toggle == on("Play"), "T9 app: Stop returns the position to 0")

    // Choosing another meeting stops playback (LibraryModel.onSelectionChange), playing or paused; showing the same one does not.
    app.togglePlayer()
    check(plays(fileA) && choose(b) && player.state == .idle && audio.calls.last == "stop",
          "T9 app: choosing another meeting stops playback")
    check(app.topBar.player?.position == "0:00 / 12:34" && isAt(app.topBar.player?.file, fileB), "T9 app: and the bar is that meeting's")
    app.togglePlayer()
    app.togglePlayer()
    check(holdsPaused(fileB) && choose(a) && player.state == .idle && audio.calls.last == "stop" && isAt(app.topBar.player?.file, fileA),
          "T9 app: choosing another meeting while one is paused stops it too, so Play is the new meeting's")
    check(choose(b), "T9 app: (meeting B again)")
    app.togglePlayer()
    app.library.show(b)
    check(plays(fileB), "T9 app: showing the meeting already selected leaves it playing")
    app.library.show(a)
    check(player.state == .idle, "T9 app: showing another meeting stops it")
    check(choose(a), "T9 app: (meeting A again)")

    // A voice sample: starting one stops playback first; Play is unavailable until the microphone is free.
    app.togglePlayer()
    var stopsAtStarts: [Int] = []
    audio.onStop = { stopsAtStarts.append(sampler.starts.count) }
    let startsBefore = sampler.starts.count
    app.recordSample()
    audio.onStop = nil
    check(sampler.starts.count == startsBefore + 1 && player.state == .idle && stopsAtStarts == [startsBefore],
          "T9 sample: starting a voice sample stops playback, before the sampler starts (\(stopsAtStarts))")
    let loadsBefore = audio.loads.count
    check(app.topBar.player?.toggle == off("Play"), "T9 sample: Play is disabled while the sample waits for the microphone")
    app.togglePlayer()
    check(player.state == .idle && audio.loads.count == loadsBefore, "T9 sample: and Play does nothing meanwhile")
    sampler.starts.last?.started(nil)
    app.tickSample()
    check(app.topBar.player?.toggle == off("Play"), "T9 sample: Play is disabled while the sample records")
    app.togglePlayer()
    check(player.state == .idle && audio.loads.count == loadsBefore, "T9 sample: and Play does nothing")
    sampler.stopsAtOnce = false
    app.stopSample()
    check(app.topBar.player?.toggle == off("Play"), "T9 sample: nor while the sampler is still stopping")
    app.togglePlayer()
    check(player.state == .idle && audio.loads.count == loadsBefore, "T9 sample: (still nothing)")
    sampler.finishStop()
    sampler.stopsAtOnce = true
    check(app.sample == .building && app.topBar.player?.toggle == on("Play"), "T9 sample: once it is being built the microphone is free: Play again")
    engine.answerLast(0, "sample 61\n")
    engine.answerLast(0, "parakeet ready\napple ready\nvoice 61 1 sample\n")
    check(app.topBar.player?.toggle == on("Play"), "T9 sample: and once it has its outcome")
    app.closeSample()

    // Starting a recording, by every route, stops playback, then cancels a sample, before the recorder is launched.
    var log: [String] = []
    audio.onStop = { log.append("player") }
    sampler.onStop = { log.append("sampler") }
    rec.onLaunch = { _ in log.append(player.state == .idle ? "launch, nothing held" : "launch, the player holding a file") }
    /// A sample under way and the meeting playing. The app never lets both happen at once, but the player
    /// itself knows nothing of samples, so this shows the order the start takes them in.
    @MainActor func both() {
        app.recordSample()
        sampler.starts.last?.started(nil)
        player.toggle(fileA)
        log = []
    }
    @MainActor func finish(_ stop: MenuAction = .stop) -> Bool {
        let pid = rec.nextPid
        app.perform(stop)
        guard settle({ phaseIs("finalising") }) else { return false }
        rec.exit(pid, 0, verifies: true)
        return settle { phaseIs("idle") && app.session.phase == .idle }
    }
    let routes: [(String, @MainActor () -> Void)] = [
        ("New meeting", { app.newMeeting() }),
        ("the menu bar", { app.perform(.start) }),
        ("the hotkey and the socket", { _ = app.handler.reply(for: .start(mic: nil, dir: nil)) }),
        ("a toggle that becomes a start", { _ = app.handler.reply(for: .toggle(mic: nil, dir: nil)) }),
    ]
    for (i, (route, start)) in routes.enumerated() {
        both()
        let launches = rec.launches.count
        check(plays(fileA), "T9 \(route): (playing, with a sample under way)")
        start()
        check(settle { rec.launches.count == launches + 1 } && log == ["player", "sampler", "launch, nothing held"] && player.state == .idle
              && app.sample == .failed("Stopped because a meeting started recording."),
              "T9 \(route): playback stops, then the sample is cancelled, before the recorder is launched (\(log))")
        // At once, before the views have heard of the new phase (the hotkey and socket routes check this
        // in the same turn as the start): the bar reads the session itself.
        let loadsAtStart = audio.loads.count
        check(app.topBar.player?.toggle == off("Play"), "T9 \(route): Play is disabled from the moment the recording starts")
        app.togglePlayer()
        check(player.state == .idle && audio.loads.count == loadsAtStart, "T9 \(route): and Play does nothing then")
        app.closeSample()
        guard i == 0 else {
            check(finish(), "T9 \(route): (the recording is finished)")
            continue
        }
        // While it records: the timer, Pause and Stop, whichever meeting is selected; the menu bar's own actions.
        check(settle { phaseIs("recording") }, "T9 recording: (recording)")
        check(log == ["player", "sampler", "launch, nothing held"], "T9 recording: once the views have heard, nothing more is stopped (\(log))")
        var r = app.topBar.recording
        check(r?.timer == Preferences.timerText(app.status.seconds) && r?.toggle == on("Pause") && r?.toggleAction == .pause
              && r?.stop == on("Stop") && r?.stopAction == .stop,
              "T9 recording: the bar shows the timer, Pause and Stop (\(String(describing: r)))")
        check(app.recordingEntries.contains { $0.action == .pause && $0.enabled } && app.recordingEntries.contains { $0.action == .stop && $0.enabled },
              "T9 recording: Pause and Stop are the menu bar's own actions")
        check(app.topBar.player?.toggle == off("Play"), "T9 recording: Play is disabled while recording")
        app.togglePlayer()
        check(player.state == .idle && audio.loads.count == loadsBefore + 1, "T9 recording: and Play does nothing")
        let live = rec.launches.last?.dir ?? a
        check(read(live) && app.topBar.recording == r && app.topBar.player == nil,
              "T9 recording: with the recording itself selected, the same controls and no player (it has no audio yet, and says nothing)")
        app.library.select(nil)
        check(app.topBar.recording == r && app.topBar.player == nil, "T9 recording: and with nothing selected")
        check(choose(a), "T9 recording: (meeting A selected again)")
        app.perform(r?.toggleAction ?? .info)
        check(settle { phaseIs("paused") } && app.session.phase == .paused(live), "T9 recording: the bar's Pause, through perform, pauses the recording")
        r = app.topBar.recording
        check(r?.toggle == on("Resume") && r?.toggleAction == .resume && r?.stop == on("Stop")
              && app.recordingEntries.contains { $0.action == .resume && $0.enabled },
              "T9 paused: the bar shows Resume and Stop, the menu bar's own")
        check(app.topBar.player?.toggle == off("Play"), "T9 paused: Play is still disabled")
        app.togglePlayer()
        check(player.state == .idle && audio.loads.count == loadsBefore + 1, "T9 paused: and Play does nothing")
        app.perform(r?.toggleAction ?? .info)
        check(settle { phaseIs("recording") } && app.session.phase == .recording(live), "T9 recording: the bar's Resume, through perform, resumes it")
        let pid = rec.nextPid
        app.perform(app.topBar.recording?.stopAction ?? .info)
        check(settle { phaseIs("finalising") }, "T9 recording: the bar's Stop, through perform, stops it")
        check(app.topBar.recording == nil && app.topBar.player?.toggle == off("Play"),
              "T9 finalising: no recording controls, and Play waits until the recording is saved")
        app.togglePlayer()
        check(player.state == .idle && audio.loads.count == loadsBefore + 1, "T9 finalising: and Play does nothing")
        rec.exit(pid, 0, verifies: true)
        check(settle { phaseIs("idle") && app.session.phase == .idle } && app.topBar.player?.toggle == on("Play"),
              "T9 \(route): once it is saved, Play is offered again")
    }

    // A paused player, with no sample: the start still stops it first.
    app.togglePlayer()
    app.togglePlayer()
    check(holdsPaused(fileA), "T9 socket start: (paused)")
    log = []
    _ = app.handler.reply(for: .start(mic: nil, dir: nil))
    check(log == ["player", "launch, nothing held"] && player.state == .idle && app.sample == .idle,
          "T9 socket start: a paused player is stopped before the recorder is launched (\(log))")
    check(finish(), "T9 socket start: (the recording is finished)")
    audio.onStop = nil
    sampler.onStop = nil
    rec.onLaunch = nil

    // A missing or unreadable audio file says why.
    let c = make(root, "2026-11-10_0900", files: ["audio.m4a": "c"])
    try! app.store.update(c) { $0.state = .done; $0.seconds = 60 }
    let d = make(root, "2026-11-09_0900", files: ["audio.m4a": "d"])
    try! app.store.update(d) { $0.state = .done; $0.seconds = 60 }
    let e = make(root, "2026-11-08_0900", files: ["notes.md": "minutes, and no recording"])
    try! app.store.update(e) { $0.state = .done; $0.seconds = 60 }
    let u = make(root, "2026-11-07_0900", files: ["mic.caf": "working"])
    try! app.store.update(u) { $0.state = .failed; $0.seconds = 60 }
    let f = make(root, "2026-11-06_0900")
    check(mkfifo(f.appendingPathComponent("audio.m4a").path, 0o600) == 0, "T9 app: (meeting F's audio.m4a is a FIFO)")
    try! app.store.update(f) { $0.state = .done; $0.seconds = 60 }
    app.library.reload()
    check(choose(c), "T9 app: (meeting C selected)")
    try! fm.removeItem(at: c.appendingPathComponent("audio.m4a"))
    app.togglePlayer()
    bar = app.topBar
    check(player.state == cannotPlay && bar.player?.problem == "This recording cannot be played" && bar.player?.toggle == on("Play")
          && bar.player?.stop == off("Stop") && !audio.calls.suffix(1).contains("play"),
          "T9 app: audio that has gone since the folder was read shows This recording cannot be played, and nothing plays")
    check(choose(d) && player.state == .idle && app.topBar.player?.problem == nil, "T9 app: choosing another meeting clears it")
    chmod(d.appendingPathComponent("audio.m4a").path, 0)
    app.togglePlayer()
    check(player.state == cannotPlay && app.topBar.player?.problem == "This recording cannot be played", "T9 app: so does an unreadable one")
    chmod(d.appendingPathComponent("audio.m4a").path, 0o644)
    let loadsBeforeE = audio.count("load")
    check(read(e), "T9 app: (meeting E, finished with no audio, selected)")
    bar = app.topBar
    check(bar.player?.file == nil && bar.player?.problem == "This recording cannot be played" && bar.player?.toggle == off("Play")
          && bar.player?.stop == off("Stop"),
          "T9 app: a finished meeting with no audio at all shows the player with Play disabled and This recording cannot be played (F1)")
    app.togglePlayer()
    check(player.state == .idle && audio.count("load") == loadsBeforeE, "T9 app: and Play does nothing there")
    check(read(c) && app.topBar.player?.file == nil && app.topBar.player?.problem == "This recording cannot be played",
          "T9 app: so does C once its folder is read again without its audio")
    check(read(u) && app.library.shownContent?.files.unfinished == true && app.topBar.player == nil,
          "T9 app: an unfinished recording shows nothing about audio it does not have yet")
    check(choose(f), "T9 app: (meeting F selected)")
    let started = Date()
    app.togglePlayer()
    check(Date().timeIntervalSince(started) < 0.5 && player.state == cannotPlay && audio.count("load") == loadsBeforeE,
          "T9 app: a FIFO audio.m4a fails at once, saying so, and is never opened (an open would block)")

    app.shutDown()
    try? fm.removeItem(at: state)
}

// A recorder left running by a crash or a relaunch (T9-ADV-1, T9-ADV-2): while it is unconfirmed nothing is
// offered; once it is adopted on the tick, playback stops and a sample is cancelled, in that order; and Play
// waits until the recording is saved, even while its stop has not reached the recorder.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    let rec = FakeRecorder()
    let engine = FakeEngine()
    let sampler = FakeSampler()
    let audio = FakeAudio()
    let player = Player(audio: audio, tickQueue: nil, loadQueue: nil)
    let app = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                       engine: engine, sampler: sampler, player: player)
    let b = make(root, "2026-11-11_0900", files: ["audio.m4a": "b"])
    try! app.store.update(b) { $0.state = .done; $0.seconds = 754 }
    let fileB = b.appendingPathComponent("audio.m4a")
    /// A recorder still running in a meeting folder that recording.dir names, as a relaunch finds it.
    @MainActor func leftRunning(_ name: String, paused: Bool) -> (dir: URL, pid: Int32) {
        let dir = Session.folderURL(root.appendingPathComponent(name).path)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! app.store.update(dir) { $0.state = .recording; $0.started = Date().addingTimeInterval(-600) }
        try! fm.createDirectory(at: state, withIntermediateDirectories: true)
        try! Data(dir.path.utf8).write(to: state.appendingPathComponent("recording.dir"))
        if paused { try! Data().write(to: state.appendingPathComponent("paused")) }
        rec.nextPid += 1
        rec.running[dir.path] = rec.nextPid
        rec.alive.insert(rec.nextPid)
        return (dir, rec.nextPid)
    }
    @MainActor func phaseIs(_ wanted: String) -> Bool {
        switch (wanted, app.status.phase) {
        case ("recording", .recording), ("paused", .paused), ("finalising", .finalising), ("idle", .idle): return true
        default: return false
        }
    }

    // At launch ps cannot tell whether the recorder is alive: nothing is offered.
    let first = leftRunning("2026-11-14_0800", paused: false)
    rec.findUnknown = true
    app.launch()
    app.library.reload()
    app.library.select(LibraryPresentation.key(b))
    check(settle { app.library.shownContent?.files.audio != nil }, "T9 adopt: (meeting B selected)")
    check(app.session.phase == .idle && app.session.unconfirmed, "T9 adopt: (a recorder is left unconfirmed: the session is idle)")
    check(app.topBar.player?.toggle == off("Play") && !app.canRecordSample,
          "T9 adopt: while a recorder is unconfirmed, neither Play nor a voice sample is offered")
    app.togglePlayer()
    app.recordSample()
    check(player.state == .idle && audio.count("load") == 0 && sampler.starts.isEmpty && app.sample == .idle,
          "T9 adopt: and Play and Record a voice sample do nothing")
    _ = settle({ false }, timeout: 1.5)
    check(app.session.phase == .idle && app.session.unconfirmed && app.topBar.player?.toggle == off("Play"),
          "T9 adopt: still nothing while the tick cannot tell")
    rec.findUnknown = false
    check(settle { phaseIs("recording") } && app.session.phase == .recording(first.dir) && !app.session.unconfirmed,
          "T9 adopt: once ps can tell, the tick adopts the recording")
    check(app.topBar.recording != nil && app.topBar.player?.toggle == off("Play"), "T9 adopt: and Play is disabled while it records")

    // Its Stop cannot reach the recorder yet (ps cannot confirm the pid): finalising, still capturing, Play still disabled.
    rec.findUnknown = true
    app.perform(.stop)
    check(settle { phaseIs("finalising") } && rec.sent(SIGINT) == 0 && rec.alive.contains(first.pid),
          "T9 finalising: (stopping, with the stop not yet sent to the recorder)")
    check(app.topBar.recording == nil && app.topBar.player?.toggle == off("Play"),
          "T9 finalising: Play is not offered while the stop has not reached the recorder")
    app.togglePlayer()
    check(player.state == .idle && audio.count("load") == 0, "T9 finalising: and Play does nothing")
    rec.findUnknown = false
    check(settle { rec.sent(SIGINT) == 1 }, "T9 finalising: (the stop reaches the recorder once ps can confirm it)")
    rec.exit(first.pid, 0, verifies: true)
    check(settle { phaseIs("idle") && app.session.phase == .idle } && app.topBar.player?.toggle == on("Play"),
          "T9 finalising: once it is saved, Play is offered again")

    // A recorder left unconfirmed later (the meetings folder changed while ps cannot tell, say), while the player
    // plays and a sample is under way: at once, playback stops, then the sample is cancelled (R2-1).
    app.recordSample()
    sampler.starts.last?.started(nil)
    player.toggle(fileB)
    check(player.state == .playing(fileB) && app.sampling, "T9 adopt later: (playing, with a sample under way)")
    var log: [String] = []
    audio.onStop = { log.append("player") }
    sampler.onStop = { log.append("sampler") }
    let second = leftRunning("2026-11-14_0830", paused: true)
    rec.findUnknown = true
    app.adopt()
    check(app.session.phase == .idle && app.session.unconfirmed && !app.canRecordSample, "T9 adopt later: (the recorder is unconfirmed)")
    check(player.state == .idle && app.sample == .failed("Stopped because a meeting started recording.") && log == ["player", "sampler"],
          "T9 adopt later: straight after the adopt that leaves a recorder unconfirmed, playback stops, then the sample is cancelled (\(log))")
    check(app.topBar.player?.toggle == off("Play"), "T9 adopt later: and Play is not offered")
    rec.findUnknown = false
    check(settle { phaseIs("paused") } && app.session.phase == .paused(second.dir), "T9 adopt later: (the tick adopts it, paused)")
    check(log == ["player", "sampler"] && app.topBar.player?.toggle == off("Play"),
          "T9 adopt later: once adopted nothing more is stopped, and Play is disabled while it is paused (\(log))")
    app.closeSample()
    app.perform(.stop)
    _ = settle { phaseIs("finalising") }
    rec.exit(second.pid, 0, verifies: true)
    check(settle { phaseIs("idle") && app.session.phase == .idle }, "T9 adopt later: (the recording is saved)")

    // A recorder found running at once (ps can tell): the phase changes, and the backstop stops playback, then
    // cancels the sample, as willStart does for a start.
    app.recordSample()
    sampler.starts.last?.started(nil)
    player.toggle(fileB)
    check(player.state == .playing(fileB) && app.sampling, "T9 adopt at once: (playing, with a sample under way)")
    log = []
    let third = leftRunning("2026-11-14_0900", paused: false)
    app.adopt()
    check(app.session.phase == .recording(third.dir) && !app.session.unconfirmed, "T9 adopt at once: (adopted straight away)")
    check(settle { player.state == .idle } && log == ["player", "sampler"] && app.sample == .failed("Stopped because a meeting started recording."),
          "T9 adopt at once: an adopted recording stops playback, then cancels the sample (\(log))")
    check(app.topBar.player?.toggle == off("Play"), "T9 adopt at once: and Play is disabled while it records")
    audio.onStop = nil
    sampler.onStop = nil
    app.closeSample()
    app.perform(.stop)
    _ = settle { phaseIs("finalising") }
    rec.exit(third.pid, 0, verifies: true)
    check(settle { phaseIs("idle") && app.session.phase == .idle }, "T9 adopt at once: (the recording is saved)")

    // The same with the recorder found paused (T9R2-RR-1): adopted as .paused, the backstop still makes way,
    // so nothing plays or samples into a recording the user can then resume.
    app.recordSample()
    sampler.starts.last?.started(nil)
    player.toggle(fileB)
    check(player.state == .playing(fileB) && app.sampling, "T9 adopt at once, paused: (playing, with a sample under way)")
    log = []
    audio.onStop = { log.append("player") }
    sampler.onStop = { log.append("sampler") }
    let fourth = leftRunning("2026-11-14_0930", paused: true)
    app.adopt()
    check(app.session.phase == .paused(fourth.dir) && !app.session.unconfirmed, "T9 adopt at once, paused: (adopted straight away, paused)")
    check(settle { player.state == .idle } && log == ["player", "sampler"] && app.sample == .failed("Stopped because a meeting started recording."),
          "T9 adopt at once, paused: an adopted paused recording stops playback, then cancels the sample (\(log))")
    check(app.topBar.player?.toggle == off("Play"), "T9 adopt at once, paused: and Play is disabled while it is paused")
    audio.onStop = nil
    sampler.onStop = nil
    app.closeSample()
    app.perform(.stop)
    _ = settle { phaseIs("finalising") }
    rec.exit(fourth.pid, 0, verifies: true)
    check(settle { phaseIs("idle") && app.session.phase == .idle }, "T9 adopt at once, paused: (the recording is saved)")
    app.shutDown()
    try? fm.removeItem(at: state)
}

// R2-1 by the real route: the meetings folder changes, while a meeting plays and a sample is under way, to one
// where a recorder that recording.dir names is running and ps cannot tell. Playback stops at once, then the
// sample is cancelled. A change to a folder with no recording in it leaves playback alone.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    let rec = FakeRecorder()
    let audio = FakeAudio()
    let sampler = FakeSampler()
    let player = Player(audio: audio, tickQueue: nil, loadQueue: nil)
    let app = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                       engine: FakeEngine(), sampler: sampler, player: player)
    let b = make(root, "2026-11-11_0900", files: ["audio.m4a": "b"])
    try! app.store.update(b) { $0.state = .done; $0.seconds = 754 }
    let fileB = b.appendingPathComponent("audio.m4a")
    app.launch()
    app.library.reload()
    app.library.select(LibraryPresentation.key(b))
    check(settle { app.library.shownContent?.files.audio != nil }, "T9 folder change: (meeting B selected)")
    @MainActor func playsB() -> Bool { if case .playing(let u) = player.state { return isAt(u, fileB) }; return false }
    var log: [String] = []
    audio.onStop = { log.append("player") }
    sampler.onStop = { log.append("sampler") }

    // A folder with no meeting being recorded in it (T9R2-RR-3): the meeting playing carries on.
    let quiet = freshRoot()
    let done = make(quiet, "2026-11-10_0900", files: ["audio.m4a": "q"])
    try! app.store.update(done) { $0.state = .done; $0.seconds = 60 }
    app.togglePlayer()
    check(playsB(), "T9 folder change, no recorder: (playing B)")
    app.setMeetingsFolder(quiet)
    check(settle { isAt(prefs.meetingsFolder, quiet) } && app.folderProblem == nil && !app.session.unconfirmed,
          "T9 folder change, no recorder: (the folder is taken)")
    check(playsB() && log == [], "T9 folder change, no recorder: a meeting playing carries on (\(log))")

    // A folder where a recorder is running and ps cannot tell.
    let elsewhere = freshRoot()
    let live = Session.folderURL(elsewhere.appendingPathComponent("2026-11-14_0700").path)
    try! fm.createDirectory(at: live, withIntermediateDirectories: true)
    try! app.store.update(live) { $0.state = .recording; $0.started = Date().addingTimeInterval(-600) }
    try! Data(live.path.utf8).write(to: state.appendingPathComponent("recording.dir"))
    rec.nextPid += 1
    let pid = rec.nextPid
    rec.running[live.path] = pid
    rec.alive.insert(pid)
    rec.findUnknown = true
    // A sample under way and B playing: the app never lets both happen at once, but the player itself knows
    // nothing of samples, so this shows what the move stops and in what order.
    app.recordSample()
    sampler.starts.last?.started(nil)
    player.toggle(fileB)
    check(playsB() && app.sampling, "T9 folder change: (playing B, with a sample under way)")
    log = []
    app.setMeetingsFolder(elsewhere)
    check(settle { app.session.unconfirmed } && app.folderProblem == nil && isAt(prefs.meetingsFolder, elsewhere),
          "T9 folder change: (the folder is taken, and its recorder is unconfirmed)")
    check(player.state == .idle && log == ["player", "sampler"] && app.sample == .failed("Stopped because a meeting started recording."),
          "T9 folder change: as soon as the new folder leaves a recorder unconfirmed, playback stops, then the sample is cancelled (\(log))")
    audio.onStop = nil
    sampler.onStop = nil
    app.closeSample()
    rec.findUnknown = false
    check(settle { app.session.phase == .recording(live) }, "T9 folder change: (the tick adopts the recorder)")
    app.perform(.stop)
    _ = settle { if case .finalising = app.status.phase { return true }; return false }
    rec.exit(pid, 0, verifies: true)
    check(settle { app.session.phase == .idle && app.status.phase == .idle }, "T9 folder change: (the recording is saved)")
    app.shutDown()
    try? fm.removeItem(at: state)
}

// R2-2: the player's own default load queue, the one the app uses, is a background queue: Play returns at
// once while the load is held, and the load runs off the main thread.
MainActor.assumeIsolated {
    let fake = FakeAudio()
    let player = Player(audio: fake, tickQueue: .main)
    let file = make(freshRoot(), "2026-11-14_1200", files: ["audio.m4a": "a"]).appendingPathComponent("audio.m4a")
    let gate = DispatchSemaphore(value: 0)
    fake.gate = gate
    let t0 = Date()
    player.toggle(file)
    let took = Date().timeIntervalSince(t0)
    let ran = Flag()
    DispatchQueue.main.async { ran.on = true }
    check(took < 0.5 && settle({ ran.on }, timeout: 1) && player.state == .idle,
          "T9 default load queue: Play returns at once while the load is held, and the main queue stays free (\(took) s)")
    fake.gate = nil
    gate.signal()
    check(settle { player.state == .playing(file) } && fake.loadedOnMain == [false],
          "T9 default load queue: the load ran off the main thread, then it plays (\(fake.loadedOnMain))")
    player.stop()
}

// Play loads the file off the main queue (T9-ADV-3): the main queue stays free while it loads, and a stop,
// another meeting, a voice sample or a recording that comes first means the late load plays nothing.
MainActor.assumeIsolated {
    let state = shortTemp()
    let root = freshRoot()
    let prefs = Preferences(defaults: testDefaults(), home: root)
    prefs.meetingsFolder = root
    prefs.sounds = false
    prefs.openMinutes = false
    let rec = FakeRecorder()
    let engine = FakeEngine()
    let sampler = FakeSampler()
    let slow = FakeAudio()
    let player = Player(audio: slow, tickQueue: nil, loadQueue: DispatchQueue(label: "meetingbox.test.player.load"))
    let app = AppModel(stateDir: state, preferences: prefs, recorder: rec, runner: FakeRunner(), freeBytes: { _ in 50 * GB },
                       engine: engine, sampler: sampler, player: player)
    let a = make(root, "2026-11-12_0900", files: ["audio.m4a": "a"])
    try! app.store.update(a) { $0.state = .done; $0.seconds = 3900 }
    let b = make(root, "2026-11-11_0900", files: ["audio.m4a": "b"])
    try! app.store.update(b) { $0.state = .done; $0.seconds = 754 }
    let f = make(root, "2026-11-10_0900")
    check(mkfifo(f.appendingPathComponent("audio.m4a").path, 0o600) == 0, "T9 load: (meeting F's audio.m4a is a FIFO)")
    try! app.store.update(f) { $0.state = .done; $0.seconds = 60 }
    let fileA = a.appendingPathComponent("audio.m4a")
    app.launch()
    app.library.reload()
    @MainActor func choose(_ dir: URL) -> Bool {
        app.library.select(LibraryPresentation.key(dir))
        return settle { isAt(app.library.shownContent?.files.audio?.deletingLastPathComponent(), dir) }
    }
    @MainActor func plays(_ f: URL) -> Bool { if case .playing(let u) = player.state { return isAt(u, f) }; return false }

    check(choose(a), "T9 load: (meeting A selected)")
    app.togglePlayer()
    check(player.state == .idle, "T9 load: Play leaves the player as it was until the file has loaded")
    check(settle { plays(fileA) } && slow.count("play") == 1, "T9 load: then it plays")
    app.stopPlayer()

    /// Play with the load held up until `release`: togglePlayer returns at once and the main queue stays free.
    @MainActor func heldPlay(_ label: String) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        slow.gate = gate
        let t0 = Date()
        app.togglePlayer()
        let took = Date().timeIntervalSince(t0)
        let ran = Flag()
        DispatchQueue.main.async { ran.on = true }
        check(took < 0.5 && settle({ ran.on }, timeout: 1) && player.state == .idle,
              "T9 load \(label): togglePlayer returns at once and the main queue stays free while the file loads (\(took) s)")
        return gate
    }
    /// Lets the held load come back and gives its answer time to reach the main queue.
    @MainActor func release(_ gate: DispatchSemaphore) {
        slow.gate = nil
        gate.signal()
        _ = settle({ false }, timeout: 0.5)
    }

    // A recording started before the load comes back is never played into.
    var plays0 = slow.count("play")
    var gate = heldPlay("then a recording")
    let reply = app.handler.reply(for: .start(mic: nil, dir: nil))
    check(reply.hasPrefix("ok recording") && rec.launches.count == 1, "T9 load: (a recording starts while the file loads)")
    release(gate)
    check(slow.count("play") == plays0 && player.state == .idle && slow.calls.last == "stop",
          "T9 load: a recording started before the load came back is never played into: nothing plays, and what was loaded is let go (\(slow.calls.suffix(3)))")
    let pid = rec.nextPid
    app.perform(.stop)
    _ = settle { if case .finalising = app.status.phase { return true }; return false }
    rec.exit(pid, 0, verifies: true)
    check(settle { app.session.phase == .idle && app.status.phase == .idle }, "T9 load: (the recording is saved)")

    // Stop, another meeting, and a voice sample, each before the load comes back.
    plays0 = slow.count("play")
    gate = heldPlay("then Stop")
    app.stopPlayer()
    release(gate)
    check(slow.count("play") == plays0 && player.state == .idle, "T9 load: a Stop before the load came back: nothing plays")
    gate = heldPlay("then another meeting")
    check(choose(b), "T9 load: (meeting B chosen while A loads)")
    release(gate)
    check(slow.count("play") == plays0 && player.state == .idle, "T9 load: another meeting chosen before the load came back: nothing plays")
    check(choose(a), "T9 load: (meeting A again)")
    gate = heldPlay("then a voice sample")
    app.recordSample()
    release(gate)
    check(slow.count("play") == plays0 && player.state == .idle && app.sampling,
          "T9 load: a voice sample started before the load came back: nothing plays")
    app.closeSample()

    // Nothing touches the audio while a load is under way: a late load that comes back while a newer one is
    // still loading leaves the audio alone, and the newer one plays.
    let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
    let loadsBeforeBoth = slow.count("load")
    slow.gate = firstGate
    app.togglePlayer()
    let firstIn = Date().addingTimeInterval(3)
    while !slow.isLoading && Date() < firstIn { usleep(1000) }
    app.stopPlayer()
    slow.gate = secondGate
    app.togglePlayer()
    firstGate.signal()
    // The main queue is held (no run loop) until the newer load is inside load, so the late answer, queued on
    // the main queue meanwhile, is handled while it runs.
    let holdUntil = Date().addingTimeInterval(3)
    while !(slow.count("load") == loadsBeforeBoth + 2 && slow.isLoading) && Date() < holdUntil { usleep(1000) }
    check(slow.count("load") == loadsBeforeBoth + 2 && slow.isLoading, "T9 load: (the newer load is under way, the late answer waiting)")
    _ = settle({ false }, timeout: 0.5)
    check(!slow.calls.contains { $0.hasSuffix("during a load") } && player.state == .idle,
          "T9 load: a late load coming back while a newer one loads touches nothing (\(slow.calls.suffix(4)))")
    slow.gate = nil
    secondGate.signal()
    check(settle { plays(fileA) }, "T9 load: and the newer one plays")
    app.stopPlayer()

    // Play again while the same file loads does not load it twice.
    let loads0 = slow.count("load")
    gate = heldPlay("pressed twice")
    app.togglePlayer()
    release(gate)
    check(plays(fileA) && slow.count("load") == loads0 + 1, "T9 load: Play pressed again while the file loads loads it once, and it plays")
    app.stopPlayer()

    // A FIFO is refused before anything opens it, so the load queue is never stuck.
    let loads1 = slow.count("load")
    check(choose(f), "T9 load: (meeting F selected)")
    let t0 = Date()
    app.togglePlayer()
    check(Date().timeIntervalSince(t0) < 0.5 && settle({ player.state == .failed("This recording cannot be played") }, timeout: 2)
          && slow.count("load") == loads1,
          "T9 load: a FIFO audio.m4a fails at once, and togglePlayer returns at once")
    check(choose(a), "T9 load: (meeting A again)")
    app.togglePlayer()
    check(settle { plays(fileA) }, "T9 load: and the next Play still plays")
    app.stopPlayer()
    app.shutDown()
    try? fm.removeItem(at: state)
}

// MARK: - Sources, the minutes writer and agreement (Stage 3, Task 11)

let t11Anthropic = "https://api.anthropic.com"
let t11Ollama = "http://127.0.0.1:11434/v1"
let t11Bridge = "https://bridge.example/v1"
let t11Other = "https://other.example/v1"
let t11Llama = OutsideWriter(kind: .standard, address: t11Ollama, model: "llama3")
let t11Sonnet = OutsideWriter(kind: .claude, address: t11Anthropic, model: "claude-sonnet-4-5")
let t11BridgeModel = OutsideWriter(kind: .standard, address: t11Bridge, model: "claude")

/// The shared address table, read where it is in the repository (found from this test's own source
/// file, never copied): each case, whether the rule allows it, and its line.
func t11AddressCases() -> (cases: [(allow: Bool, address: String, line: Int)], odd: [Int]) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    guard let text = try? String(contentsOf: repo.appendingPathComponent("tests/fixtures/addresses.txt"), encoding: .utf8) else { return ([], [-1]) }
    var cases: [(allow: Bool, address: String, line: Int)] = []
    var odd: [Int] = []
    for (n, line) in text.components(separatedBy: "\n").enumerated() where !line.isEmpty && !line.hasPrefix("#") {
        guard let space = line.firstIndex(of: " "), line[..<space] == "allow" || line[..<space] == "refuse" else { odd.append(n + 1); continue }
        cases.append((line[..<space] == "allow", t11Unescape(String(line[line.index(after: space)...])), n + 1))
    }
    return (cases, odd)
}
/// The table's four escapes: \n, \r, \t and \\.
func t11Unescape(_ s: String) -> String {
    let escapes: [Character: Character] = ["n": "\n", "r": "\r", "t": "\t", "\\": "\\"]
    var out = ""
    var chars = s.makeIterator()
    while let c = chars.next() {
        guard c == "\\" else { out.append(c); continue }
        guard let next = chars.next() else { out.append(c); break }
        if let e = escapes[next] { out.append(e) } else { out.append(c); out.append(next) }
    }
    return out
}

// The address rule, against every line of the shared table, and the host it parses.
do {
    let (cases, odd) = t11AddressCases()
    let wrong = cases.filter {
        (PreferencesPresentation.host(of: $0.address) != nil) != $0.allow || (PreferencesPresentation.addressProblem($0.address) == nil) != $0.allow
    }
    check(cases.count >= 120 && cases.filter(\.allow).count >= 30 && odd.isEmpty && wrong.isEmpty,
          "T11 address rule: every case in tests/fixtures/addresses.txt (\(cases.count), read in place) agrees with the Swift rule (wrong: \(wrong.map { "line \($0.line) \($0.address.debugDescription)" }), odd lines: \(odd))")
    check(cases.contains { !$0.allow && $0.address.contains("\n") } && cases.contains { !$0.allow && $0.address == " https://api.anthropic.com" }
          && cases.contains { !$0.allow && $0.address == "https://example.com/a\\b" },
          "T11 address rule: the table's escapes and its leading space are read as written")
    let base = "https://a.example/"
    let longest = base + String(repeating: "a", count: 2048 - base.count)
    check(PreferencesPresentation.host(of: longest) == "a.example" && PreferencesPresentation.host(of: longest + "a") == nil,
          "T11 address rule: 2048 characters are accepted, 2049 refused")
    check(PreferencesPresentation.host(of: "https://API.anthropic.com") == nil && PreferencesPresentation.host(of: "https://api.Anthropic.com/v1") == nil
          && PreferencesPresentation.host(of: "https://example.COM") == nil && PreferencesPresentation.host(of: "http://LOCALHOST:11434") == nil,
          "T11 address rule: an upper-case host is refused")
    check(PreferencesPresentation.host(of: "https://1.2.3.4/v1") == nil && PreferencesPresentation.host(of: "https://10.0.0.1") == nil
          && PreferencesPresentation.host(of: "https://192.168.1.10:8443/v1") == nil && PreferencesPresentation.host(of: "https://0x7f000001") == nil,
          "T11 address rule: https to an IPv4 literal, in any spelling, is refused")
    check(PreferencesPresentation.host(of: t11Anthropic) == "api.anthropic.com" && PreferencesPresentation.host(of: "http://[::1]:8080/v1") == "[::1]"
          && PreferencesPresentation.host(of: "https://[2001:db8::1]:8443") == "[2001:db8::1]" && PreferencesPresentation.host(of: "http://localhost:1234/v1") == "localhost"
          && PreferencesPresentation.host(of: "https://my-gateway.example.co.uk:8443/openai/v1") == "my-gateway.example.co.uk"
          && PreferencesPresentation.host(of: t11Ollama) == "127.0.0.1",
          "T11 host: the host as the rule parses it, an IPv6 literal with its brackets")
    check(PreferencesPresentation.addressProblem(t11Ollama) == nil && PreferencesPresentation.addressProblem("http://192.168.1.10:1234/v1") == PreferencesPresentation.addressRefused
          && PreferencesPresentation.addressRefused.hasPrefix("That address is not one meetingbox accepts.") && PreferencesPresentation.addressRefused.contains("[2001:db8::1]"),
          "T11 address rule: a refusal says so, and how an IPv6 address must be written")
    check(ScriptRunner.setAsideLine(OutsideWriter(kind: .standard, address: "http://[::1]:8080/v1", model: "m"))
          == "The minutes writer m at [::1] was set aside because its source was removed, changed or not agreed. Apple's model writes the minutes.",
          "T11 set-aside line: the host as the address rule parses it")
}

// Preferences: sources and minutesWriter in UserDefaults, and the run settings they give.
do {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    let d = testDefaults()
    let p = Preferences(defaults: d, home: home)
    check(p.sources.isEmpty && p.minutesWriter == nil && p.runSettings == .defaults, "T11 Preferences: no sources and Apple writing, by default")
    let claude = Source(kind: .claude, address: t11Anthropic, agreed: true)
    let local = Source(kind: .standard, address: t11Ollama, agreed: false)
    p.sources = [claude, local]
    let llama = OutsideWriter(kind: .standard, address: t11Ollama, model: "llama3.1:8b")
    p.minutesWriter = llama
    let q = Preferences(defaults: d, home: home)
    let stored = d.array(forKey: "sources") as? [[String: Any]]
    check(q.sources == [claude, local] && stored?.count == 2 && stored?[0].count == 3 && stored?[0]["kind"] as? String == "claude"
          && stored?[0]["address"] as? String == t11Anthropic && stored?[0]["agreed"] as? Bool == true && stored?[1]["agreed"] as? Bool == false,
          "T11 Preferences: sources persist as a list of {kind, address, agreed}")
    let w = d.dictionary(forKey: "minutesWriter")
    check(q.minutesWriter == llama && w?.count == 3 && w?["kind"] as? String == "standard" && w?["address"] as? String == t11Ollama
          && w?["model"] as? String == "llama3.1:8b",
          "T11 Preferences: minutesWriter round-trips through UserDefaults with its kind, address and model")
    check(q.runSettings == RunSettings(transcriber: .parakeet, tidy: true, preferredWriter: .outside(llama), agreed: [claude]),
          "T11 Preferences: runSettings puts minutesWriter in preferredWriter, and only the agreed sources in agreed")
    q.minutesWriter = nil
    check(d.object(forKey: "minutesWriter") == nil && Preferences(defaults: d, home: home).runSettings.preferredWriter == .apple,
          "T11 Preferences: Apple is minutesWriter absent")
    d.set([["kind": "gemini", "address": "https://g.example", "agreed": true], ["kind": "claude", "agreed": true],
           ["kind": "standard", "address": "https://s.example", "agreed": "yes"], "junk"], forKey: "sources")
    d.set(["kind": "gemini", "address": "https://g.example", "model": "g"], forKey: "minutesWriter")
    check(q.sources == [Source(kind: .standard, address: "https://s.example", agreed: false)] && q.minutesWriter == nil && q.runSettings.agreed.isEmpty,
          "T11 Preferences: an entry it cannot read is skipped, and only a true Bool is agreed")
}

// What the Minutes section says: the engine's source lines, the choice of writer, the Model name field,
// the Node line, and the fixed words.
do {
    let both = PreferencesPresentation.parseEngines("parakeet ready\napple ready\nvoice none\noutside-runtime ready\noutside model llama3.1:8b\n"
        + "outside model qwen3:30b-cloud\noutside model has space\noutside model \(String(repeating: "m", count: 201))\noutside model org/model@v1+x\n")
    check(both.outside == SourceListing(models: ["llama3.1:8b", "qwen3:30b-cloud", "org/model@v1+x"], error: nil) && both.parakeet == .ready
          && both.outsideRuntime == .ready && both.voice == VoiceState.none,
          "T11 engines: outside model lines beside the others, an id outside the model rule dropped (\(String(describing: both.outside)))")
    check(PreferencesPresentation.parseEngines("outside-runtime ready\noutside none\n").outside == SourceListing(models: [], error: nil),
          "T11 engines: outside none is a listing with no models")
    let unset = PreferencesPresentation.parseEngines("outside-runtime unavailable no Node 20 or later\noutside error outside models are not set up\n")
    check(unset.outside == SourceListing(models: [], error: "outside models are not set up") && unset.outsideRuntime == .unavailable("no Node 20 or later"),
          "T11 engines: outside error <reason>, the reason as given")
    check(PreferencesPresentation.parseEngines("outside error it asked for a key").outside?.error == "it asked for a key"
          && PreferencesPresentation.parseEngines("outside error its address is not one meetingbox accepts\n").outside?.error == "its address is not one meetingbox accepts",
          "T11 engines: every reason is taken as given")
    check(PreferencesPresentation.parseEngines("parakeet ready\napple ready\n").outside == nil
          && PreferencesPresentation.parseEngines("outside maybe\noutside\n").outside == nil,
          "T11 engines: no outside line, or one it cannot read, is no listing")
    check(PreferencesPresentation.listing(status: 0, output: "outside-runtime ready\noutside model a\n") == SourceListing(models: ["a"], error: nil)
          && PreferencesPresentation.listing(status: 124, output: "") == SourceListing(models: [], error: "it did not answer within 10 seconds")
          && PreferencesPresentation.listing(status: 1, output: "meetingbox is not installed; run meetingbox setup")
              == SourceListing(models: [], error: "meetingbox is not installed; run meetingbox setup")
          && PreferencesPresentation.listing(status: 0, output: "parakeet ready\n") == SourceListing(models: [], error: "it gave an unexpected answer"),
          "T11 listing: the models, the limit, the engine's own refusal, and an answer with no outside line")

    let sources = [Source(kind: .claude, address: t11Anthropic, agreed: true), Source(kind: .standard, address: t11Ollama, agreed: false),
                   Source(kind: .standard, address: t11Bridge, agreed: false)]
    let listings = [t11Anthropic: SourceListing(models: ["claude-sonnet-4-5"], error: nil),
                    t11Ollama: SourceListing(models: ["llama3", "gpt-oss:120b-cloud", "glm-4.6:cloud", "my-cloud-model", "cloudy"], error: nil)]
    let options = PreferencesPresentation.writerChoice(sources: sources, listings: listings, saved: nil)
    check(options.map(\.title) == ["Apple, on this Mac", "claude-sonnet-4-5 at api.anthropic.com", "llama3 at 127.0.0.1",
                                   "gpt-oss:120b-cloud at 127.0.0.1 (runs online)", "glm-4.6:cloud at 127.0.0.1 (runs online)",
                                   "my-cloud-model at 127.0.0.1", "cloudy at 127.0.0.1"]
          && options.allSatisfy(\.available) && options.first?.writer == nil
          && options.dropFirst(1).first?.writer == OutsideWriter(kind: .claude, address: t11Anthropic, model: "claude-sonnet-4-5")
          && options.dropFirst(2).first?.writer == OutsideWriter(kind: .standard, address: t11Ollama, model: "llama3"),
          "T11 choice: Apple, on this Mac, then every listed model as <model> at <host>, -cloud and :cloud ids (runs online) (\(options.map(\.title)))")
    let mistral = OutsideWriter(kind: .standard, address: t11Ollama, model: "mistral")
    let gone = PreferencesPresentation.writerChoice(sources: sources, listings: listings, saved: mistral)
    check(gone.count == options.count + 1 && gone.last == WriterOption(writer: mistral, title: "mistral at 127.0.0.1 (not available)", available: false),
          "T11 choice: a saved model its source no longer lists stays, as (not available)")
    check(options.count > 2 && PreferencesPresentation.writerChoice(sources: sources, listings: listings, saved: options[2].writer) == options,
          "T11 choice: a saved model that is listed is not added again")
    let typed = OutsideWriter(kind: .standard, address: t11Bridge, model: "claude")
    check(PreferencesPresentation.writerChoice(sources: sources, listings: listings, saved: typed).last
          == WriterOption(writer: typed, title: "claude at bridge.example", available: true)
          && PreferencesPresentation.writerChoice(sources: sources, listings: [t11Bridge: SourceListing(models: [], error: "it asked for a key")], saved: typed).last
          == WriterOption(writer: typed, title: "claude at bridge.example", available: true),
          "T11 choice: a saved model of a source not listed yet, or that cannot list its models, shows plainly")
    let removed = OutsideWriter(kind: .standard, address: t11Other, model: "m-cloud")
    let changed = OutsideWriter(kind: .claude, address: t11Ollama, model: "llama3")
    check(PreferencesPresentation.writerChoice(sources: sources, listings: listings, saved: removed).last?.title == "m-cloud at other.example (runs online) (not available)"
          && PreferencesPresentation.writerChoice(sources: sources, listings: listings, saved: changed).last
          == WriterOption(writer: changed, title: "llama3 at 127.0.0.1 (not available)", available: false),
          "T11 choice: a saved model whose source was removed, or changed kind, is not available")
    check(!PreferencesPresentation.showsModelField(nil) && PreferencesPresentation.showsModelField(SourceListing(models: [], error: nil))
          && PreferencesPresentation.showsModelField(SourceListing(models: [], error: "it refused the key"))
          && !PreferencesPresentation.showsModelField(SourceListing(models: ["m"], error: nil)),
          "T11 Model name: a field for an empty list and for a listing error; none before a listing, nor once it lists models")
    check(PreferencesPresentation.outsideRuntimeLine(EngineStatus(outsideRuntime: .unavailable("no Node 20 or later was found")))
          == "Outside models need Node 20 or later. Run meetingbox setup."
          && PreferencesPresentation.outsideRuntimeLine(EngineStatus(outsideRuntime: .ready)) == nil
          && PreferencesPresentation.outsideRuntimeLine(EngineStatus()) == nil,
          "T11 Node: Outside models need Node 20 or later. Run meetingbox setup. when outside-runtime is unavailable, and only then")
    check(PreferencesPresentation.listingLine(SourceListing(models: ["a", "b", "c"], error: nil)) == "Found 3 models"
          && PreferencesPresentation.listingLine(SourceListing(models: ["a"], error: nil)) == "Found 1 model"
          && PreferencesPresentation.listingLine(SourceListing(models: [], error: nil)) == "Found 0 models"
          && PreferencesPresentation.listingLine(SourceListing(models: [], error: "it refused the key")) == "Could not list its models: it refused the key."
          && PreferencesPresentation.listingLine(SourceListing(models: [], error: "it asked for a key"))
          == "Could not list its models: it asked for a key. Set a key for this source."
          && PreferencesPresentation.listingLine(nil) == nil,
          "T11 Check: Found N models, Found 1 model, or why not, with a hint when a keyless source asked for a key")

    let noSources = "To use another model, add a source: the Claude API with your key, or a standard address such as Ollama (http://127.0.0.1:11434/v1) or the Local CLI Bridge."
    check(PreferencesPresentation.noSources == noSources, "T11 copy: the no-sources line")
    let stays = PreferencesPresentation.privacyLine(writer: nil)
    let sent = PreferencesPresentation.privacyLine(writer: t11Llama)
    check(stays.text == "Transcripts stay on this Mac." && !stays.amber
          && sent.text == "Transcripts are sent to 127.0.0.1 to write the minutes. Recordings stay on this Mac. This applies to every meeting processed, including new recordings."
          && sent.amber && PreferencesPresentation.privacyLine(writer: OutsideWriter(kind: .standard, address: "http://[::1]:8080/v1", model: "m")).text
          .hasPrefix("Transcripts are sent to [::1] to write"),
          "T11 copy: both privacy lines, the second in amber")
    check(PreferencesPresentation.consentTitle(host: "127.0.0.1") == "Send transcripts to 127.0.0.1?"
          && PreferencesPresentation.consentText(address: t11Ollama) == "To write the minutes, meetingbox will send each meeting's full transcript, with its date, time and length, to http://127.0.0.1:11434/v1. If that is a program on this Mac, it may pass it on: the Local CLI Bridge sends it to Claude or Codex under your account, and an Ollama model whose name ends in 'cloud' runs on Ollama's servers. The transcript includes what other people said, so make sure they are happy with that. Recordings stay on this Mac. You can switch back to Apple at any time."
          && PreferencesPresentation.consentButton(host: "127.0.0.1") == "Send transcripts to 127.0.0.1" && PreferencesPresentation.consentCancel == "Cancel",
          "T11 copy: the consent title, text and buttons")
    check(PreferencesPresentation.writerLabel == "Write the minutes with" && PreferencesPresentation.appleWriter == "Apple, on this Mac"
          && PreferencesPresentation.modelNameLabel == "Model name" && PreferencesPresentation.kindTitle(.claude) == "Claude API"
          && PreferencesPresentation.kindTitle(.standard) == "Standard (Ollama, LM Studio, Local CLI Bridge)"
          && PreferencesPresentation.addSourceTitle == "Add…" && PreferencesPresentation.removeTitle == "Remove" && PreferencesPresentation.setKeyTitle == "Set…"
          && PreferencesPresentation.keyLine(true) == "Key: set" && PreferencesPresentation.keyLine(false) == "Key: none" && PreferencesPresentation.keyLine(nil) == nil
          && PreferencesPresentation.setKeyFirst == "Set a key for this source first."
          && PreferencesPresentation.defaultAddress(.claude) == "https://api.anthropic.com" && PreferencesPresentation.defaultAddress(.standard) == "",
          "T11 copy: the writer picker, the kinds, the source and key buttons and lines, word for word")
    check(PreferencesPresentation.keyRefused == "That key is not one meetingbox accepts: a key is 1 to 4096 letters, digits and . _ ~ + / = -"
          && PreferencesPresentation.keyOK("sk-ant-api03-AZaz09._~+/=-") && !PreferencesPresentation.keyOK("") && !PreferencesPresentation.keyOK("a b")
          && !PreferencesPresentation.keyOK("a\"b") && !PreferencesPresentation.keyOK(String(repeating: "k", count: 4097))
          && PreferencesPresentation.keyOK(String(repeating: "k", count: 4096)),
          "T11 key rule: 1 to 4096 of A-Za-z0-9._~+/=-, refused in the engine's words")
    check(PreferencesPresentation.modelNameProblem("llama3.1:8b") == nil && PreferencesPresentation.modelNameProblem("org/m@v1+x_y-z") == nil
          && PreferencesPresentation.modelNameProblem("has space") != nil && PreferencesPresentation.modelNameProblem("") != nil
          && PreferencesPresentation.modelNameProblem(String(repeating: "m", count: 201)) != nil,
          "T11 model name: 1 to 200 of A-Za-z0-9._:/+@-, as the engine accepts")
}

// The minutes view shows links as plain text.
do {
    let m = LibraryPresentation.minutes("See [the plan](https://evil.example/x), <https://other.example/y> and **this**.")
    let text = String(m.characters)
    check(!m.runs.contains { $0.link != nil } && text.contains("the plan") && text.contains("https://other.example/y") && !text.contains("evil.example")
          && m.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false },
          "T11 minutes: links are shown as plain text: no run is a link, the words stay, and bold is still bold (\(text))")
}

/// An AppModel over a fake engine and a fake runner, with its Preferences in a scratch suite.
@MainActor
final class T11Rig {
    let state = shortTemp()
    let root = freshRoot()
    let prefs: Preferences
    let engine = FakeEngine()
    let runner = FakeRunner()
    let app: AppModel
    init(sources: [Source] = [], writer: OutsideWriter? = nil) {
        prefs = Preferences(defaults: testDefaults(), home: root)
        prefs.meetingsFolder = root
        prefs.sounds = false
        prefs.openMinutes = false
        prefs.sources = sources
        prefs.minutesWriter = writer
        app = AppModel(stateDir: state, preferences: prefs, recorder: FakeRecorder(), runner: runner, freeBytes: { _ in 50 * GB }, engine: engine)
    }
    /// The engine commands so far that begin with these words.
    func calls(_ head: [String]) -> [FakeEngine.Call] { engine.calls.filter { $0.arguments.starts(with: head) } }
    /// Every listing of a source asked for so far (`engines --kind K --address A`).
    var listed: [[String]] { engine.calls.map(\.arguments).filter { $0.starts(with: ["engines", "--kind"]) } }
    /// Answers the last command that begins with these words.
    func answer(_ head: [String], _ status: Int32, _ output: String) {
        guard let i = engine.calls.lastIndex(where: { $0.arguments.starts(with: head) }) else {
            check(false, "T11: there is no \(head) to answer")
            return
        }
        engine.answer(i, status, output)
    }
    /// A finished meeting in the meetings folder, with its audio, a transcript and the minutes.
    func done(_ name: String, _ change: @escaping (inout MeetingRecord) -> Void = { _ in }) -> URL {
        let dir = make(root, name, files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello\n", "notes.md": "minutes\n"])
        try! app.store.update(dir) { $0.state = .done; change(&$0) }
        age(dir)
        return dir
    }
    /// Selects the meeting in the window, once its folder has been read.
    func open(_ dir: URL) -> Bool {
        let key = LibraryPresentation.key(dir)
        app.library.reload()
        guard settle({ self.app.library.meetings.contains { LibraryPresentation.key($0.folder.url) == key } }) else { return false }
        app.library.select(key)
        return settle { self.app.library.shownContent?.key == key && self.app.library.shownContent?.files.transcript == true }
    }
    func raw(_ dir: URL) -> Data? { try? Data(contentsOf: dir.appendingPathComponent("meeting.json")) }
    /// The source at `i` in Preferences, if there is one.
    func source(_ i: Int) -> Source? { prefs.sources.indices.contains(i) ? prefs.sources[i] : nil }
    func finish() {
        app.shutDown()
        try? fm.removeItem(at: state)
    }
}
func t11WriterJSON(_ w: OutsideWriter) -> [String: String] { ["kind": w.kind.rawValue, "address": w.address, "model": w.model] }

// Adding, changing and removing sources.
MainActor.assumeIsolated {
    let r = T11Rig()
    r.app.beginAddSource()
    check(r.app.sourceDraft == SourceDraft(editing: nil, kind: .claude, address: "https://api.anthropic.com", problem: nil) && r.app.preferencesSheet == .source,
          "T11 sources: Add… starts at the Claude API, with https://api.anthropic.com filled in")
    r.app.updateSourceDraft { $0.kind = .standard }
    check(r.app.sourceDraft?.address == "", "T11 sources: choosing Standard empties the filled-in Claude address")
    r.app.updateSourceDraft { $0.kind = .claude }
    check(r.app.sourceDraft?.address == t11Anthropic, "T11 sources: and choosing the Claude API again fills it")
    r.app.updateSourceDraft { $0.kind = .standard; $0.address = t11Ollama }
    r.app.updateSourceDraft { $0.kind = .claude }
    check(r.app.sourceDraft?.address == t11Ollama, "T11 sources: an address typed is kept when the kind changes")
    r.app.cancelSourceDraft()
    check(r.app.sourceDraft == nil && r.prefs.sources.isEmpty && r.engine.calls.isEmpty && r.app.preferencesSheet == nil,
          "T11 sources: Cancel adds nothing and runs nothing")
    r.app.beginAddSource()
    r.app.saveSourceDraft()
    check(r.app.sourceDraft == nil && r.prefs.sources == [Source(kind: .claude, address: t11Anthropic, agreed: false)],
          "T11 sources: adding the Claude API source Add… filled in stores https://api.anthropic.com, not agreed")
    check(r.listed == [["engines", "--kind", "claude", "--address", t11Anthropic]] && r.calls(["engines", "--kind"]).first?.timeout == 10
          && r.calls(["engines", "--kind"]).first?.stdin == nil
          && r.calls(["key", "status"]).map(\.arguments) == [["key", "status", "--address", t11Anthropic]],
          "T11 sources: saving a source lists its models, with a 10 s limit, and reads whether it has a key (\(r.engine.calls.map(\.arguments)))")
    let count = r.engine.calls.count
    check(r.app.addSource(Source(kind: .standard, address: t11Anthropic, agreed: false)) == PreferencesPresentation.addressTaken
          && r.app.addSource(Source(kind: .standard, address: t11Anthropic + "/", agreed: false)) == PreferencesPresentation.addressTaken
          && r.prefs.sources.count == 1 && r.engine.calls.count == count,
          "T11 sources: two sources with one address are refused (a trailing / too), and nothing runs")
    r.app.beginAddSource()
    r.app.updateSourceDraft { $0.kind = .standard; $0.address = "http://192.168.1.10:1234/v1" }
    r.app.saveSourceDraft()
    check(r.app.sourceDraft?.problem == PreferencesPresentation.addressRefused && r.prefs.sources.count == 1 && r.engine.calls.count == count,
          "T11 sources: an address the rule refuses is not added, the sheet says why, and nothing runs")
    r.app.updateSourceDraft { $0.address = " \(t11Ollama)\n" }
    r.app.saveSourceDraft()
    check(r.app.sourceDraft == nil && r.prefs.sources == [Source(kind: .claude, address: t11Anthropic, agreed: false), Source(kind: .standard, address: t11Ollama, agreed: false)],
          "T11 sources: the address is taken without the spaces around it")
    check(r.app.addSource(Source(kind: .claude, address: "", agreed: true)) == PreferencesPresentation.addressTaken,
          "T11 sources: a Claude API source with no address is the default one, already there")
    r.prefs.sources = r.prefs.sources.map { var s = $0; s.agreed = true; return s }

    // a new kind only
    let removesBefore = r.calls(["key", "remove"]).count
    check(r.app.updateSource(at: 1, Source(kind: .claude, address: t11Ollama, agreed: true)) == nil
          && r.prefs.sources == [Source(kind: .claude, address: t11Anthropic, agreed: true), Source(kind: .claude, address: t11Ollama, agreed: false)],
          "T11 sources: changing only a source's kind clears its agreement, and no other's")
    check(r.calls(["key", "remove"]).count == removesBefore && r.listed.last == ["engines", "--kind", "claude", "--address", t11Ollama],
          "T11 sources: changing only its kind removes no key, and lists it afresh")
    r.prefs.sources = r.prefs.sources.map { var s = $0; s.agreed = true; return s }
    check(r.app.updateSource(at: 1, Source(kind: .claude, address: t11Ollama, agreed: false)) == nil && r.source(1)?.agreed == true,
          "T11 sources: saving a source unchanged keeps its agreement")

    // a new address
    check(r.app.updateSource(at: 1, Source(kind: .claude, address: t11Bridge, agreed: true)) == nil
          && r.source(1) == Source(kind: .claude, address: t11Bridge, agreed: false),
          "T11 sources: changing a source's address clears its agreement")
    check(r.calls(["key", "remove"]).map(\.arguments) == [["key", "remove", "--address", t11Ollama]] && r.calls(["key", "remove"]).first?.stdin == nil,
          "T11 sources: changing its address runs key remove --address <old> through the engine")
    check(r.calls(["key", "status", "--address", t11Bridge]).count == 1 && r.listed.last == ["engines", "--kind", "claude", "--address", t11Bridge],
          "T11 sources: and reads the new address's key and lists it")
    check(r.app.updateSource(at: 1, Source(kind: .standard, address: t11Anthropic, agreed: false)) == PreferencesPresentation.addressTaken
          && r.source(1)?.address == t11Bridge
          && r.app.updateSource(at: 1, Source(kind: .standard, address: "ftp://x", agreed: false)) == PreferencesPresentation.addressRefused,
          "T11 sources: a source cannot take another's address, nor one the rule refuses")
    r.answer(["key", "remove", "--address", t11Ollama], 0, "none\n")
    check(r.app.minutesProblem == nil, "T11 sources: a key removed for an old address says nothing")
    r.app.beginEditSource(at: 1)
    check(r.app.sourceDraft == SourceDraft(editing: t11Bridge, kind: .claude, address: t11Bridge, problem: nil), "T11 sources: Edit… starts at the source as it is")
    r.app.updateSourceDraft { $0.kind = .standard }
    r.app.saveSourceDraft()
    check(r.app.sourceDraft == nil && r.source(1) == Source(kind: .standard, address: t11Bridge, agreed: false), "T11 sources: and saves through updateSource")

    // removing
    r.app.removeSource(at: 0)
    check(r.prefs.sources.map(\.address) == [t11Bridge] && r.calls(["key", "remove", "--address", t11Anthropic]).count == 1 && r.prefs.runSettings.agreed.isEmpty,
          "T11 sources: removing a source runs key remove for it, and withdraws its agreement")
    r.answer(["key", "remove", "--address", t11Anthropic], 1, "The key could not be removed from the keychain.\n")
    check(r.app.minutesProblem == "The key for https://api.anthropic.com could not be removed from the keychain. It may still be there.",
          "T11 sources: a key that could not be removed with its source may still be there, and that is said (\(r.app.minutesProblem ?? "-"))")
    r.finish()
}

// Keys: read when Preferences opens, without a listing; Set… and Remove; the key only ever on stdin.
MainActor.assumeIsolated {
    let a = t11Anthropic, b = t11Ollama
    let r = T11Rig(sources: [Source(kind: .claude, address: a, agreed: false), Source(kind: .standard, address: b, agreed: false)])
    r.app.launch()
    check(r.engine.calls.isEmpty, "T11 keys: nothing runs at launch with sources saved")
    r.app.preferencesOpened()
    check(r.calls(["key", "status"]).map(\.arguments) == [["key", "status", "--address", a], ["key", "status", "--address", b]]
          && r.calls(["key", "status"]).allSatisfy { $0.stdin == nil } && r.listed.isEmpty && r.engine.count(["engines"]) == 1,
          "T11 keys: opening Preferences runs key status --address A once per source, engines once, and no engines --kind (\(r.engine.calls.map(\.arguments)))")
    check(r.app.keys.isEmpty, "T11 keys: nothing is said until key status answers")
    r.answer(["key", "status", "--address", a], 0, "set\n")
    r.answer(["key", "status", "--address", b], 0, "none\n")
    check(r.app.keys == [a: true, b: false], "T11 keys: set and none, by address")
    r.app.preferencesOpened()
    r.answer(["key", "status", "--address", a], 1, "The keychain could not be read.\n")
    check(r.app.keys[a] == nil && r.app.keyProblems[a] == "The keychain could not be read." && r.app.keys[b] == false
          && PreferencesPresentation.keyLine(r.app.keys[a]) == nil,
          "T11 keys: a keychain that could not be read is neither set nor none, and is said as a keychain problem")
    r.app.preferencesOpened()
    r.answer(["key", "status", "--address", a], 0, "set\n")
    r.answer(["key", "status", "--address", b], 0, "none\n")
    check(r.app.keys[a] == true && r.app.keyProblems[a] == nil, "T11 keys: a later answer clears it")

    r.app.beginKey(at: 0)
    check(r.app.keyDraft?.address == a && r.app.preferencesSheet == .key, "T11 key: Set… opens the key sheet for that source")
    let key = "sk-ant-api03-abc_DEF.ghi~jkl+mno/pqr=stu-v"
    r.app.keyText(" \(key) \n")
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: a)
    let sets = r.calls(["key", "set"])
    check(sets.count == 1 && sets[0].arguments == ["key", "set", "--address", a] && sets[0].stdin == Data(key.utf8)
          && !r.engine.calls.contains { $0.arguments.contains { $0.contains("sk-ant") } },
          "T11 key: saveKey runs key set --address A with the key on stdin, never in the arguments")
    check(r.app.keyDraft?.saving == true, "T11 key: the sheet waits for the answer")
    r.app.saveKey(key, for: a)
    check(r.calls(["key", "set"]).count == 1, "T11 key: Set pressed again while the key is being stored runs nothing more")
    let statusBefore = r.calls(["key", "status", "--address", a]).count
    r.answer(["key", "set"], 0, "set\n")
    check(r.app.keyDraft == nil && r.calls(["key", "status", "--address", a]).count == statusBefore + 1,
          "T11 keys: once stored the sheet closes, and Set… refreshes keys with key status")
    r.answer(["key", "status", "--address", a], 0, "set\n")
    check(r.app.keys[a] == true, "T11 keys: and keys says set")

    let before = r.engine.calls.count
    r.app.beginKey(at: 1)
    r.app.keyText("has space")
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: b)
    check(r.engine.calls.count == before && r.app.keyDraft?.problem == PreferencesPresentation.keyRefused,
          "T11 key: a key the rule refuses is said in the sheet, and never reaches the engine")
    r.app.keyText("good-key")
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: b)
    r.answer(["key", "set"], 1, "The key could not be stored in the keychain.\n")
    check(r.app.keyDraft?.problem == "The key could not be stored in the keychain." && r.app.keyDraft?.saving == false,
          "T11 key: a refusal stays in the sheet, in the engine's words")
    r.app.cancelKey()
    check(r.app.keyDraft == nil, "T11 key: Cancel closes the sheet")
    r.answer(["key", "status", "--address", b], 0, "none\n")

    r.app.removeKey(for: a)
    check(r.calls(["key", "remove"]).map(\.arguments) == [["key", "remove", "--address", a]], "T11 keys: Remove runs key remove --address A")
    r.answer(["key", "remove", "--address", a], 1, "The key could not be removed from the keychain.\n")
    check(r.app.keys[a] == true && r.app.keyProblems[a] == "The key could not be removed from the keychain. It may still be there.",
          "T11 keys: a key that could not be removed may still be there: said so, and keys keeps it as it was")
    check(r.calls(["key", "status", "--address", a]).count == statusBefore + 2, "T11 keys: Remove refreshes keys with key status")
    r.answer(["key", "status", "--address", a], 0, "set\n")
    check(r.app.keyProblems[a] != nil, "T11 keys: the status read after it does not hide that it was not removed")
    r.app.removeKey(for: a)
    check(r.app.keyProblems[a] == nil, "T11 keys: trying again clears the old line")
    r.answer(["key", "remove", "--address", a], 0, "none\n")
    check(r.app.keys[a] == false, "T11 keys: a key removed is none")
    r.answer(["key", "status", "--address", a], 0, "none\n")

    // A Claude API model for a source with no key: the key line instead of agreement, from Preferences and from a redo sheet.
    r.app.chooseWriter(t11Sonnet)
    check(r.app.consent == nil && r.app.writerNotice == "Set a key for this source first." && r.prefs.minutesWriter == nil,
          "T11 key first: a Claude API model for a source with no key shows Set a key for this source first. and sets no consent, in Preferences")
    let m = r.done("2026-11-14_0900")
    check(r.open(m), "T11 key first: (a meeting is shown)")
    r.app.library.perform(.redoMinutes)
    r.app.library.setRedoWriter(.outside(t11Sonnet))
    check(r.app.consent == nil && r.app.library.writerNotice == "Set a key for this source first." && r.app.library.redoing?.writer == .apple,
          "T11 key first: and from a redo sheet, leaving the sheet's writer as it was")
    r.app.library.cancelRedo()
    check(r.app.library.writerNotice == nil, "T11 key first: closing the sheet clears its line")
    r.finish()
}

// When sources are contacted: only on Check, on opening the picker, or on saving a source; never at launch
// or because Preferences opened. A listing has a 10 s limit, and one overtaken is dropped.
MainActor.assumeIsolated {
    let a = t11Anthropic, l = t11Ollama
    let r = T11Rig(sources: [Source(kind: .standard, address: l, agreed: true), Source(kind: .claude, address: a, agreed: false)])
    r.app.launch()
    r.app.preferencesOpened()
    r.app.preferencesOpened()
    check(r.listed.isEmpty, "T11 contact: opening Preferences, twice, with saved sources and Apple chosen starts no listing with a source")
    r.prefs.minutesWriter = t11Llama
    r.app.preferencesOpened()
    check(r.listed.isEmpty, "T11 contact: nor with an outside model chosen")
    r.app.refreshListing(at: 0)
    check(r.listed == [["engines", "--kind", "standard", "--address", l]] && r.calls(["engines", "--kind"]).last?.timeout == 10
          && r.calls(["engines", "--kind"]).last?.stdin == nil && r.app.listings[l] == nil,
          "T11 contact: Check lists that source's models with a 10 s limit, and nothing is shown until it answers")
    r.answer(["engines", "--kind"], 0, "parakeet ready\napple ready\nvoice none\noutside-runtime ready\noutside model llama3\noutside model qwen3\n")
    check(r.app.listings[l] == SourceListing(models: ["llama3", "qwen3"], error: nil) && PreferencesPresentation.listingLine(r.app.listings[l]) == "Found 2 models",
          "T11 contact: its answer is the source's listing")
    check(r.app.writerOptions.map(\.title) == ["Apple, on this Mac", "llama3 at 127.0.0.1", "qwen3 at 127.0.0.1"] && r.app.writerSelection == 1,
          "T11 contact: the picker offers the models listed, at the choice saved")
    r.app.writerPickerOpened()
    check(r.listed.count == 3 && r.listed[1] == ["engines", "--kind", "standard", "--address", l] && r.listed[2] == ["engines", "--kind", "claude", "--address", a],
          "T11 contact: opening the picker lists every source")
    r.app.refreshListing(at: 0)
    let pending = r.engine.calls.indices.filter { r.engine.calls[$0].arguments == ["engines", "--kind", "standard", "--address", l] }
    if pending.count == 3 {
        r.engine.answer(pending[2], 0, "outside model newest\n")
        r.engine.answer(pending[1], 0, "outside model older\n")
    }
    check(pending.count == 3 && r.app.listings[l]?.models == ["newest"], "T11 contact: a listing overtaken by a newer one is dropped")
    r.answer(["engines", "--kind", "claude"], 1, "outside error the Claude API needs a key\n")
    check(r.app.listings[a] == SourceListing(models: [], error: "the Claude API needs a key"), "T11 contact: a listing error is kept as given")
    r.app.refreshListing(at: 1)
    r.answer(["engines", "--kind", "claude"], 124, "")
    check(r.app.listings[a]?.error == "it did not answer within 10 seconds", "T11 contact: a listing past its limit says so")
    r.app.refreshListing(at: 0)
    let stale = r.engine.calls.lastIndex { $0.arguments == ["engines", "--kind", "standard", "--address", l] }
    check(r.app.updateSource(at: 0, Source(kind: .standard, address: "http://localhost:11434/v1", agreed: false)) == nil, "T11 contact: (the source's address changes)")
    if let stale = stale { r.engine.answer(stale, 0, "outside model stale\n") }
    check(stale != nil && r.app.listings[l] == nil && r.app.listings["http://localhost:11434/v1"] == nil,
          "T11 contact: a listing for an address since changed is dropped, and the old listing goes")
    r.finish()
}

// Agreement in Preferences: consent before anything leaves the Mac.
MainActor.assumeIsolated {
    let l = t11Ollama
    let r = T11Rig(sources: [Source(kind: .standard, address: l, agreed: false)])
    let before = r.prefs.runSettings
    r.app.chooseWriter(t11Llama)
    check(r.app.consent == ConsentRequest(writer: t11Llama, origin: .preferences) && r.prefs.runSettings == before && r.prefs.minutesWriter == nil,
          "T11 agreement: choosing a model from an unagreed source sets consent (origin preferences), and Preferences.runSettings is unchanged")
    check(r.app.preferencesSheet == .consent && r.app.privacy.text == "Transcripts stay on this Mac." && !r.app.privacy.amber,
          "T11 agreement: the Preferences window shows the consent sheet, and transcripts still stay on this Mac")
    r.app.cancelConsent()
    check(r.app.consent == nil && r.prefs.runSettings == before && r.prefs.minutesWriter == nil && r.source(0)?.agreed == false && r.app.writerSelection == 0,
          "T11 agreement: cancelConsent() keeps Apple")
    r.app.chooseWriter(t11Llama)
    r.app.closePreferencesSheet()
    check(r.app.consent == nil && r.prefs.runSettings == before && r.app.preferencesSheet == nil,
          "T11 agreement: the consent sheet closed from outside (Escape) is Cancel")
    r.app.chooseWriter(t11Llama)
    r.app.agree()
    check(r.app.consent == nil && r.source(0)?.agreed == true && r.prefs.minutesWriter == t11Llama && r.prefs.runSettings.preferredWriter == .outside(t11Llama)
          && r.prefs.runSettings.agrees(to: t11Llama),
          "T11 agreement: agree() marks the source agreed, then sets minutesWriter")
    check(r.app.privacy.text == PreferencesPresentation.privacyLine(writer: t11Llama).text && r.app.privacy.amber,
          "T11 privacy: the amber line while an agreed outside model writes")
    let qwen = OutsideWriter(kind: .standard, address: l, model: "qwen3")
    r.app.chooseWriter(qwen)
    check(r.app.consent == nil && r.prefs.minutesWriter == qwen, "T11 agreement: another model of an agreed source needs no new agreement")
    r.app.chooseWriter(nil)
    check(r.prefs.minutesWriter == nil && r.prefs.runSettings.preferredWriter == .apple && !r.app.privacy.amber,
          "T11 agreement: Apple, on this Mac, is minutesWriter absent")
    r.app.setModelName(" my-model:latest ", for: l)
    r.app.useModelName(for: l, origin: .preferences)
    check(r.prefs.minutesWriter == OutsideWriter(kind: .standard, address: l, model: "my-model:latest") && r.app.writerNotice == nil,
          "T11 Model name: a name typed for a source is chosen as its model")
    r.app.setModelName("bad name", for: l)
    r.app.useModelName(for: l, origin: .preferences)
    check(r.prefs.minutesWriter?.model == "my-model:latest" && r.app.writerNotice == PreferencesPresentation.modelNameProblem("bad name"),
          "T11 Model name: one the engine would refuse is not chosen, and is said")
    r.app.chooseWriter(qwen)
    _ = r.app.updateSource(at: 0, Source(kind: .claude, address: l, agreed: true))
    check(r.source(0)?.agreed == false && r.prefs.minutesWriter == qwen && !r.app.privacy.amber
          && r.app.writerOptions.last == WriterOption(writer: qwen, title: "qwen3 at 127.0.0.1 (not available)", available: false)
          && r.app.writerSelection == r.app.writerOptions.count - 1,
          "T11 agreement: a changed kind withdraws agreement: the saved choice stays, not available, and transcripts stay on this Mac")
    _ = r.app.updateSource(at: 0, Source(kind: .standard, address: l, agreed: false))
    r.app.chooseWriter(t11Llama)
    check(r.app.consent?.writer == t11Llama, "T11 agreement: (asked again)")
    _ = r.app.updateSource(at: 0, Source(kind: .standard, address: "http://localhost:11434/v1", agreed: false))
    r.app.agree()
    check(!r.prefs.sources.contains { $0.agreed } && r.prefs.minutesWriter == qwen && r.app.consent == nil,
          "T11 agreement: agreeing after the source changed agrees to nothing and chooses nothing")
    r.finish()
}

// The redo sheets: the writer picker, agreement from there, and what reaches meeting.json.
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .standard, address: t11Ollama, agreed: true), Source(kind: .claude, address: t11Anthropic, agreed: false),
                             Source(kind: .standard, address: t11Bridge, agreed: false), Source(kind: .standard, address: t11Other, agreed: false)],
                   writer: t11Llama)
    let otherModel = OutsideWriter(kind: .standard, address: t11Other, model: "o1")
    r.app.launch()
    let lib = r.app.library
    check(lib.requestConsent != nil, "T11 redo: AppModel sets the window's requestConsent")
    let mA = r.done("2026-11-14_0900") { $0.writer = .outside(t11BridgeModel) }
    let mB = r.done("2026-11-14_1000")
    let mC = r.done("2026-11-14_1100")
    let mD = r.done("2026-11-14_1200")
    let mE = r.done("2026-11-14_1300")
    let mF = r.done("2026-11-14_1400")

    check(r.open(mA), "T11 redo: (meeting A)")
    lib.perform(.redoMinutes)
    check(lib.redoing?.writer == .outside(t11BridgeModel), "T11 redo: the writer picker starts at the meeting's writer")
    check(r.app.redoWriterOptions.last == WriterOption(writer: t11BridgeModel, title: "claude at bridge.example", available: true)
          && r.app.redoWriterSelection == r.app.redoWriterOptions.count - 1,
          "T11 redo: the sheet's picker offers and shows the draft's writer")
    let bytesA = r.raw(mA)
    lib.commitRedo()
    check(r.app.consent == ConsentRequest(writer: t11BridgeModel, origin: .redo) && lib.redoing != nil,
          "T11 redo: Redo with a writer not agreed asks at the click, before any check runs")
    _ = settle({ false }, timeout: 0.3)
    check(r.runner.calls.isEmpty && r.raw(mA) == bytesA && lib.redoing != nil && r.app.consent == ConsentRequest(writer: t11BridgeModel, origin: .redo),
          "T11 redo: Redo with a writer not agreed asks for agreement, queues nothing and leaves meeting.json byte-identical")
    r.app.cancelConsent()
    lib.cancelRedo()

    check(r.open(mB), "T11 redo: (meeting B)")
    lib.perform(.redoMinutes)
    check(lib.redoing?.writer == .outside(t11Llama), "T11 redo: else the picker starts at the Preferences choice")
    lib.setRedoWriter(.outside(t11Sonnet))
    r.answer(["key", "status", "--address", t11Anthropic], 0, "set\n") // its key, not known yet, is read first (round 1)
    check(r.app.consent == ConsentRequest(writer: t11Sonnet, origin: .redo) && lib.redoing?.writer == .outside(t11Llama),
          "T11 redo: an unagreed choice sets consent with origin redo and leaves the draft's writer as it was")
    check(r.app.preferencesSheet == nil, "T11 redo: the Preferences window does not show it (the library window does)")
    r.app.agree()
    check(lib.redoing?.writer == .outside(t11Sonnet) && r.source(1)?.agreed == true && r.prefs.minutesWriter == t11Llama,
          "T11 redo: agree() then sets the draft's writer, and leaves the Preferences choice")
    lib.commitRedo()
    check(settle { r.runner.calls.count == 1 } && recordJSON(mB)["writer"] as? [String: String] == t11WriterJSON(t11Sonnet)
          && argsAre(r.runner.calls.first?.arguments, "notes", mB, ["--writer", "outside", "--kind", "claude", "--address", t11Anthropic,
                                                                    "--writer-model", "claude-sonnet-4-5"]),
          "T11 redo: commitRedo stores it as the meeting's writer, and the job carries --writer outside --kind --address --writer-model (\(r.runner.calls.first?.arguments ?? []))")
    r.runner.finishNotes(0, 0)
    check(settle { MeetingStore.record(in: mB)?.state == .done }, "T11 redo: (B done)")

    check(r.open(mC), "T11 redo: (meeting C)")
    lib.perform(.transcribeAgain)
    lib.setRedoWriter(.outside(t11BridgeModel))
    check(r.app.consent?.origin == .redo, "T11 redo: (asked)")
    r.app.cancelConsent()
    check(lib.redoing?.writer == .outside(t11Llama) && r.source(2)?.agreed == false, "T11 redo: cancelConsent() leaves the draft's earlier writer")
    lib.commitRedo()
    check(settle { r.runner.calls.count == 2 } && recordJSON(mC)["writer"] as? [String: String] == t11WriterJSON(t11Llama),
          "T11 redo: and commitRedo stores that one")
    r.runner.finish(1, 0)
    check(settle { MeetingStore.record(in: mC)?.state == .done }, "T11 redo: (C done)")

    // Whatever the order of calls, an unagreed outside writer never reaches meeting.json.
    check(r.open(mD), "T11 redo: (meeting D)")
    lib.perform(.redoMinutes)
    lib.setRedoWriter(.outside(otherModel))
    lib.commitRedo() // before agreeing: the draft still holds the earlier, agreed writer
    check(settle { r.runner.calls.count == 3 } && recordJSON(mD)["writer"] as? [String: String] == t11WriterJSON(t11Llama),
          "T11 redo: committed while agreement is still asked for, the earlier writer is stored, not the one asked about")
    r.app.agree()
    check(recordJSON(mD)["writer"] as? [String: String] == t11WriterJSON(t11Llama) && lib.redoing == nil,
          "T11 redo: agreeing after the sheet has gone changes no meeting")
    r.runner.finishNotes(2, 0)
    check(settle { MeetingStore.record(in: mD)?.state == .done }, "T11 redo: (D done)")
    r.prefs.sources = r.prefs.sources.map { var s = $0; if s.address == t11Other { s.agreed = false }; return s } // not agreed again
    check(r.open(mE), "T11 redo: (meeting E)")
    lib.perform(.redoMinutes)
    lib.updateRedo { $0.writer = .outside(otherModel) } // past setRedoWriter
    let bytesE = r.raw(mE)
    lib.commitRedo()
    _ = settle({ false }, timeout: 0.3)
    check(r.runner.calls.count == 3 && r.raw(mE) == bytesE && r.app.consent?.writer == otherModel,
          "T11 redo: a writer put in the draft past setRedoWriter is still refused at Redo, and asked about")
    r.app.cancelConsent()
    lib.setRedoWriter(.apple)
    check(lib.redoing?.writer == .apple && r.app.consent == nil, "T11 redo: Apple is taken at once")
    lib.commitRedo()
    check(settle { r.runner.calls.count == 4 } && recordJSON(mE)["writer"] as? String == "apple"
          && argsAre(r.runner.calls.last?.arguments, "notes", mE, ["--writer", "apple"]),
          "T11 redo: the choice, Apple included, is stored as the meeting's writer")
    r.runner.finishNotes(3, 0)
    check(settle { MeetingStore.record(in: mE)?.state == .done }, "T11 redo: (E done)")
    check(r.open(mF), "T11 redo: (meeting F)")
    lib.perform(.redoMinutes)
    let phi = OutsideWriter(kind: .standard, address: t11Ollama, model: "phi4")
    r.app.setModelName(" phi4 ", for: t11Ollama)
    r.app.useModelName(for: t11Ollama, origin: .redo)
    check(lib.redoing?.writer == .outside(phi) && r.prefs.minutesWriter == t11Llama, "T11 redo: a Model name typed in the sheet is the sheet's writer, not Preferences'")
    r.app.setModelName("bad name", for: t11Ollama)
    r.app.useModelName(for: t11Ollama, origin: .redo)
    check(lib.redoing?.writer == .outside(phi) && lib.writerNotice == PreferencesPresentation.modelNameRefused,
          "T11 redo: a Model name the engine would refuse is said in the sheet, and not taken")
    lib.setRedoWriter(.outside(t11Llama))
    check(lib.redoing?.writer == .outside(t11Llama) && lib.writerNotice == nil, "T11 redo: an agreed source's model is taken at once")
    let bytesF = r.raw(mF)
    lib.commitRedo() // agreed now: the check runs off the main queue
    r.app.removeSource(at: 0) // and its source goes before the check comes back
    _ = settle { lib.writerNotice != nil || r.runner.calls.count > 4 }
    check(r.runner.calls.count == 4 && r.raw(mF) == bytesF && lib.redoing != nil && r.app.consent == nil
          && lib.writerNotice == PreferencesPresentation.writerGone(t11Llama),
          "T11 redo: a source removed while Redo's check runs: nothing is queued or written, the sheet stays and says why (\(lib.writerNotice ?? "-"))")
    r.finish()
}

// Writers at launch: an agreed outside writer in Preferences, Apple chosen in the sheet, and a relaunch.
MainActor.assumeIsolated {
    let r = Rig()
    let session = r.make()
    let prefs = Preferences(defaults: testDefaults(), home: r.root)
    prefs.sources = [Source(kind: .standard, address: t11Ollama, agreed: true)]
    prefs.minutesWriter = t11Llama
    let runner = FakeRunner()
    let queue = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil, settings: { prefs.runSettings })
    let model = LibraryModel(store: r.store, session: session, queue: queue, settings: { prefs.runSettings })
    let m = make(r.store.root, "2026-11-14_0900", files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello\n", "notes.md": "minutes\n"])
    try! r.store.update(m) { $0.state = .done }
    age(m)
    model.reload()
    check(settle { model.meetings.count == 1 }, "T11 launch: (the meeting is read)")
    model.select(LibraryPresentation.key(m))
    check(settle { model.shownContent?.files.transcript == true }, "T11 launch: (and shown)")
    model.perform(.redoMinutes)
    check(model.redoing?.writer == .outside(t11Llama), "T11 launch: the sheet starts at the agreed Preferences writer")
    model.setRedoWriter(.apple)
    model.commitRedo()
    check(settle { runner.calls.count == 1 } && argsAre(runner.calls[0].arguments, "notes", m, ["--writer", "apple"]) && r.json(m)["writer"] as? String == "apple",
          "T11 launch: with an agreed outside writer in Preferences, a Redo minutes with Apple chosen in the sheet launches notes <dir> --writer apple (\(runner.calls.first?.arguments ?? []))")
    // The app quits while it runs, and opens again with Preferences as they were.
    let again = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil, settings: { prefs.runSettings })
    again.resume()
    check(runner.calls.count == 2 && runner.calls[1].job.kind == .minutes && argsAre(runner.calls[1].arguments, "notes", m, ["--writer", "apple"]),
          "T11 launch: and after a simulated relaunch, still notes <dir> --writer apple (\(runner.calls.last?.arguments ?? []))")
    runner.finishNotes(1, 0)
}

// Writers at launch: a Transcribe again queued with an agreed outside writer whose source is then removed or
// changed (the app quits first), runs with --writer apple, the set-aside line the last line of .process-log.
for variant in ["removed", "kind changed", "kind changed and agreed again", "address changed"] {
    MainActor.assumeIsolated {
        let r = Rig()
        let session = r.make()
        let prefs = Preferences(defaults: testDefaults(), home: r.root)
        prefs.sources = [Source(kind: .standard, address: t11Ollama, agreed: true)]
        prefs.minutesWriter = t11Llama
        let runner = FakeRunner()
        let first = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil, settings: { prefs.runSettings })
        let model = LibraryModel(store: r.store, session: session, queue: first, settings: { prefs.runSettings })
        let busy = make(r.store.root, "2026-11-14_0800", files: ["audio.m4a": "a"])
        try! r.store.update(busy) { $0.state = .queued }
        first.enqueue(busy)
        let m = make(r.store.root, "2026-11-14_0900", files: ["audio.m4a": "a", "transcript.txt": "[00:00:01] Me: hello\n", "notes.md": "minutes\n",
                                                            ".process-log": "an earlier run\n"])
        try! r.store.update(m) { $0.state = .done }
        age(m)
        model.reload()
        _ = settle { model.meetings.count == 2 }
        model.select(LibraryPresentation.key(m))
        _ = settle { model.shownContent?.files.transcript == true }
        model.perform(.transcribeAgain)
        model.commitRedo()
        check(settle { r.stateOf(m) == "queued" } && runner.calls.count == 1 && r.json(m)["writer"] as? [String: String] == t11WriterJSON(t11Llama),
              "T11 launch (\(variant)): a Transcribe again with the agreed writer is queued behind another job, that writer kept for the meeting")
        switch variant {
        case "removed": prefs.sources = []
        case "kind changed": prefs.sources = [Source(kind: .claude, address: t11Ollama, agreed: false)]
        case "kind changed and agreed again": prefs.sources = [Source(kind: .claude, address: t11Ollama, agreed: true)]
        default: prefs.sources = [Source(kind: .standard, address: "http://localhost:11434/v1", agreed: false)]
        }
        let runs = runner.calls.count
        let next = ProcessingQueue(store: r.store, runner: runner, tickQueue: nil, settings: { prefs.runSettings })
        next.resume()
        runner.finish(runs, 0) // the other job, taken up again first, ends
        let run = runner.calls.last
        check(runner.calls.count == runs + 2 && run?.job.kind == .transcribe && run.map { Array($0.arguments.suffix(2)) } == ["--writer", "apple"]
              && run?.logAtRun == "an earlier run\n" + ScriptRunner.setAsideLine(t11Llama) + "\n",
              "T11 launch (\(variant)): resumed, it launches --writer apple, the set-aside line the last line of .process-log before the engine starts (\(run?.arguments ?? []), \(run?.logAtRun ?? "-"))")
        if runner.calls.count == runs + 2 { runner.finish(runs + 1, 0) }
    }
}

// Writers at launch: a meeting's own outside writer whose source was removed; and the arguments of an agreed one.
do {
    let r = QRig()
    let prefs = Preferences(defaults: testDefaults(), home: r.root)
    prefs.sources = [Source(kind: .standard, address: t11Ollama, agreed: true)]
    prefs.minutesWriter = t11Llama
    let q = r.make(settings: { prefs.runSettings })
    let a = r.meeting("2026-11-14_0900", files: ["audio.m4a": "a"], queued)
    q.enqueue(a)
    check(r.runner.calls.first?.arguments == ["process", a.appendingPathComponent("audio.m4a").path, "--parakeet", "--tidy", "--writer", "outside",
                                              "--kind", "standard", "--address", t11Ollama, "--writer-model", "llama3"],
          "T11 arguments: a job with an agreed writer in Preferences carries --writer outside --kind K --address A --writer-model M")
    r.runner.finish(0, 0)
    prefs.minutesWriter = nil
    let own = t8Done(r, "2026-11-14_1000", notes: false) { $0.writer = .outside(t11BridgeModel) }
    try! "an earlier run\n".write(to: own.appendingPathComponent(".process-log"), atomically: true, encoding: .utf8)
    prefs.sources = [Source(kind: .standard, address: t11Ollama, agreed: true), Source(kind: .standard, address: t11Bridge, agreed: true)]
    check(ScriptRunner.writer(meeting: .outside(t11BridgeModel), settings: prefs.runSettings).use == t11BridgeModel, "T11 launch: (its source agreed)")
    prefs.sources = [Source(kind: .standard, address: t11Ollama, agreed: true)] // and then removed
    q.retry(own)
    let run = r.runner.calls.last
    check(r.runner.calls.count == 2 && run.map { Array($0.arguments.suffix(2)) } == ["--writer", "apple"]
          && run?.logAtRun == "an earlier run\n" + ScriptRunner.setAsideLine(t11BridgeModel) + "\n",
          "T11 launch: a meeting's own outside writer whose source was removed: --writer apple, the set-aside line last in .process-log (\(run?.arguments ?? []))")
    r.runner.finish(1, 0)
}

// MARK: - Sources and consent, round 1 (Stage 3, Task 11)

// 1. A Claude API model chosen while its source's key state is not known: `key status` (local) is read
// first, then the choice is decided as it is once keys is known. Never from a listing's reason.
for (label, status, answer) in [("none", Int32(0), "none\n"), ("set", Int32(0), "set\n"), ("unreadable", Int32(1), "The keychain could not be read.\n")] {
    MainActor.assumeIsolated {
        let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false)])
        r.app.launch()
        let lib = r.app.library
        let m = r.done("2026-11-14_0900")
        check(r.open(m), "T11R1 key first (\(label)): (a meeting is shown, Preferences never opened)")
        lib.perform(.redoMinutes)
        lib.setRedoWriter(.outside(t11Sonnet))
        check(r.calls(["key", "status"]).map(\.arguments) == [["key", "status", "--address", t11Anthropic]] && r.listed.isEmpty
              && r.app.consent == nil && lib.writerNotice == nil && lib.redoing?.writer == .apple,
              "T11R1 key first (\(label)): a Claude API choice in a redo sheet with the key not known reads key status first, and decides nothing yet")
        r.answer(["key", "status", "--address", t11Anthropic], status, answer)
        if label == "none" {
            check(r.app.consent == nil && lib.writerNotice == "Set a key for this source first." && lib.redoing?.writer == .apple
                  && r.calls(["key", "status"]).count == 1,
                  "T11R1 key first: with no key it says Set a key for this source first., asks nothing, and read key status exactly once")
            r.app.setModelName("claude-opus-4-1", for: t11Anthropic)
            r.app.useModelName(for: t11Anthropic, origin: .redo)
            check(r.app.consent == nil && lib.writerNotice == "Set a key for this source first." && r.calls(["key", "status"]).count == 1,
                  "T11R1 key first: a Model name for it then says so at once, with no second read")
        } else {
            check(r.app.consent == ConsentRequest(writer: t11Sonnet, origin: .redo) && lib.writerNotice == nil && lib.redoing?.writer == .apple
                  && r.calls(["key", "status"]).count == 1,
                  "T11R1 key first (\(label)): with the key set, or the keychain unreadable (never taken for none), it asks for agreement")
        }
        r.finish()
    }
}
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false)])
    r.app.launch()
    r.app.preferencesOpened() // its own key read is not answered yet (round 2: Preferences choices need the window open)
    r.app.chooseWriter(t11Sonnet)
    check(r.calls(["key", "status"]).count == 2 && r.app.consent == nil && r.app.writerNotice == nil,
          "T11R1 key first: in Preferences too, with the key not known yet, key status is read before deciding")
    r.answer(["key", "status", "--address", t11Anthropic], 0, "none\n")
    check(r.app.consent == nil && r.app.writerNotice == "Set a key for this source first." && r.prefs.minutesWriter == nil,
          "T11R1 key first: and with no key, Preferences says Set a key for this source first.")
    let fresh = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false)])
    fresh.app.preferencesOpened()
    fresh.app.chooseWriter(t11Sonnet)
    fresh.app.chooseWriter(nil)
    fresh.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(fresh.app.consent == nil && fresh.app.writerNotice == nil && fresh.prefs.minutesWriter == nil,
          "T11R1 key first: a choice overtaken by Apple while its key was read is dropped, in Preferences")
    let sheet = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false)])
    let m = sheet.done("2026-11-14_0900")
    check(sheet.open(m), "T11R1 key first: (a meeting)")
    sheet.app.library.perform(.redoMinutes)
    sheet.app.library.setRedoWriter(.outside(OutsideWriter(kind: .claude, address: t11Anthropic, model: "claude-haiku-4-5")))
    sheet.app.library.setRedoWriter(.apple)
    check(sheet.calls(["key", "status"]).count == 1, "T11R1 key first: (its key read is under way)")
    sheet.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(sheet.app.consent == nil && sheet.app.library.writerNotice == nil && sheet.app.library.redoing?.writer == .apple,
          "T11R1 key first: and in a redo sheet, overtaken by Apple")
    sheet.app.library.setRedoWriter(.outside(OutsideWriter(kind: .claude, address: t11Anthropic, model: "claude-haiku-4-5")))
    check(sheet.app.consent?.origin == .redo && sheet.calls(["key", "status"]).count == 1, "T11R1 key first: (asked once the key is known)")
    sheet.app.library.cancelRedo()
    let pending = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false)])
    let p = pending.done("2026-11-14_0900")
    check(pending.open(p), "T11R1 key first: (another meeting)")
    pending.app.library.perform(.redoMinutes)
    pending.app.library.setRedoWriter(.outside(t11Sonnet))
    pending.app.library.cancelRedo()
    pending.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(pending.app.consent == nil, "T11R1 key first: a choice whose sheet closed while its key was read asks nothing")
    r.finish()
    fresh.finish()
    sheet.finish()
    pending.finish()
}

// 2. An agreement request belongs to its sheet: a .redo one goes when its sheet closes (Cancel or from
// outside, or once its check queues it) or another redo begins, and agree() acts only for the sheet it was
// asked from.
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .standard, address: t11Ollama, agreed: false)])
    r.app.launch()
    let lib = r.app.library
    let mA = r.done("2026-11-14_0900")
    let mB = r.done("2026-11-14_1000")
    check(r.open(mA), "T11R1 sheet: (meeting A)")
    lib.perform(.redoMinutes)
    lib.setRedoWriter(.outside(t11Llama))
    check(r.app.consent == ConsentRequest(writer: t11Llama, origin: .redo), "T11R1 sheet: (agreement asked from A's sheet)")
    lib.cancelRedo()
    check(r.app.consent == nil, "T11R1 sheet: Cancel, or the sheet closed from outside, drops its agreement request")
    check(r.open(mB), "T11R1 sheet: (meeting B)")
    lib.perform(.redoMinutes)
    check(r.app.consent == nil, "T11R1 sheet: A's request never shows over B's sheet")
    r.app.agree()
    check(lib.redoing?.writer == .apple && r.source(0)?.agreed == false, "T11R1 sheet: and agreeing cannot change B, nor agree to the source")
    lib.setRedoWriter(.outside(t11Llama))
    check(r.app.consent?.origin == .redo, "T11R1 sheet: (asked from B's sheet)")
    lib.beginRedo(lib.selectedMeeting!, kind: .transcribe)
    check(r.app.consent == nil && lib.redoing?.kind == .transcribe, "T11R1 sheet: another redo beginning drops it")
    lib.setRedoWriter(.outside(t11Llama))
    lib.commitRedo() // Apple, still: the check runs and queues it
    check(settle { r.runner.calls.count == 1 } && lib.redoing == nil && r.app.consent == nil && r.source(0)?.agreed == false,
          "T11R1 sheet: once the check queues it and the sheet closes, the request goes with it")
    r.app.agree()
    check(r.source(0)?.agreed == false && recordJSON(mB)["writer"] as? String == "apple", "T11R1 sheet: and agreeing then does nothing")
    r.runner.finish(0, 0)
    r.finish()
}

// 3. A pending agreement request goes when its source changes kind or address, or is removed (decision 8).
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .standard, address: t11Ollama, agreed: false), Source(kind: .standard, address: t11Bridge, agreed: false)])
    r.app.chooseWriter(t11Llama)
    _ = r.app.updateSource(at: 1, Source(kind: .claude, address: t11Bridge, agreed: false))
    check(r.app.consent == ConsentRequest(writer: t11Llama, origin: .preferences), "T11R1 decision 8: changing another source keeps the request")
    _ = r.app.updateSource(at: 0, Source(kind: .claude, address: t11Ollama, agreed: false))
    check(r.app.consent == nil, "T11R1 decision 8: its source changing kind drops the request")
    _ = r.app.updateSource(at: 0, Source(kind: .standard, address: t11Ollama, agreed: false))
    r.app.chooseWriter(t11Llama)
    _ = r.app.updateSource(at: 0, Source(kind: .standard, address: "http://localhost:11434/v1", agreed: false))
    check(r.app.consent == nil, "T11R1 decision 8: its source changing address drops the request")
    _ = r.app.updateSource(at: 0, Source(kind: .standard, address: t11Ollama, agreed: false))
    r.app.chooseWriter(t11Llama)
    check(r.app.consent != nil, "T11R1 decision 8: (asked again)")
    r.app.removeSource(at: 0)
    check(r.app.consent == nil, "T11R1 decision 8: its source removed drops the request")
    r.finish()
}

// 4. The key goes to the address the key sheet was opened for, or nowhere.
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false), Source(kind: .standard, address: t11Ollama, agreed: false),
                             Source(kind: .standard, address: t11Bridge, agreed: false)])
    r.app.beginKey(at: 1)
    r.app.keyText("local-key")
    r.app.removeSource(at: 0) // the list shifts under the open sheet: another source is at its index now
    check(r.source(1)?.address == t11Bridge && r.app.keyDraft?.address == t11Ollama, "T11R1 key sheet: (the sheet's index now names another source)")
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: r.app.keyDraft?.address ?? "")
    check(r.calls(["key", "set"]).map(\.arguments) == [["key", "set", "--address", t11Ollama]] && r.calls(["key", "set"]).first?.stdin == Data("local-key".utf8),
          "T11R1 key sheet: the key goes to the address the sheet was opened for, though the sources shifted under it")
    r.answer(["key", "set"], 0, "set\n")
    r.app.beginKey(at: 0)
    r.app.keyText("second-key")
    r.app.removeSource(at: 0)
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: r.app.keyDraft?.address ?? t11Ollama)
    check(r.calls(["key", "set"]).count == 1 && r.app.keyDraft == nil && !r.engine.calls.contains { $0.stdin == Data("second-key".utf8) },
          "T11R1 key sheet: when no source has its address any more, nothing is sent and the sheet closes")
    r.finish()
}

// 5. A listing cut at the 64 KB limit drops its unterminated last line, so no partial id is offered.
do {
    var full = "parakeet ready\napple ready\nvoice none\noutside-runtime ready\n"
    var n = 0
    while full.utf8.count < 70_000 {
        full += "outside model vendor/a-rather-long-model-name-number-\(String(format: "%05d", n))\n"
        n += 1
    }
    let cut = String(decoding: Array(full.utf8.prefix(65_536)), as: UTF8.self)
    let complete = cut.split(separator: "\n", omittingEmptySubsequences: false).dropLast().filter { $0.hasPrefix("outside model ") }.count
    let listing = PreferencesPresentation.listing(status: 0, output: cut)
    let idLength = "vendor/a-rather-long-model-name-number-00000".count
    check(cut.utf8.count == 65_536 && !cut.hasSuffix("\n") && listing.error == nil && listing.models.count == complete
          && listing.models.allSatisfy { $0.count == idLength },
          "T11R1 listing: a listing of exactly 65,536 bytes that ends mid-id offers only the whole ids (\(listing.models.count) of \(complete), last \(listing.models.last ?? "-"))")
    check(PreferencesPresentation.listing(status: 0, output: "outside-runtime ready\noutside model a\noutside model b").models == ["a", "b"],
          "T11R1 listing: a short listing with no final newline keeps its last line")
}

// 6. While Redo's check runs, the sheet's choices cannot change, so the job uses the writer the sheet shows.
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .standard, address: t11Ollama, agreed: true), Source(kind: .standard, address: t11Bridge, agreed: false)],
                   writer: t11Llama)
    r.app.launch()
    let lib = r.app.library
    let m = r.done("2026-11-14_0900")
    check(r.open(m), "T11R1 check: (a meeting)")
    lib.perform(.transcribeAgain)
    check(!lib.redoChecking, "T11R1 check: (no check yet)")
    lib.commitRedo()
    check(lib.redoChecking, "T11R1 check: while Redo's check runs the sheet says so")
    lib.setRedoWriter(.apple)
    lib.setRedoWriter(.outside(t11BridgeModel))
    lib.updateRedo { $0.tidy = false; $0.writer = .apple }
    r.app.setModelName("phi4", for: t11Ollama)
    r.app.useModelName(for: t11Ollama, origin: .redo)
    check(lib.redoing?.writer == .outside(t11Llama) && lib.redoing?.tidy == true && r.app.consent == nil,
          "T11R1 check: meanwhile setRedoWriter, updateRedo and Model name change nothing, and nothing is asked")
    check(settle { r.runner.calls.count == 1 } && !lib.redoChecking && lib.redoing == nil
          && r.runner.calls.first.map { Array($0.arguments.suffix(9)) } == ["--tidy", "--writer", "outside", "--kind", "standard", "--address", t11Ollama, "--writer-model", "llama3"],
          "T11R1 check: the job uses the writer and tidying the sheet shows (\(r.runner.calls.first?.arguments ?? []))")
    r.runner.finish(0, 0)
    check(settle { MeetingStore.record(in: m)?.state == .done }, "T11R1 check: (done)")
    let m2 = r.done("2026-11-14_1000")
    check(r.open(m2), "T11R1 check: (another meeting)")
    lib.perform(.redoMinutes)
    lib.commitRedo()
    r.app.removeSource(at: 0) // refused when the check comes back
    check(settle { lib.writerNotice != nil } && !lib.redoChecking && lib.redoing != nil, "T11R1 check: a check refused on its return ends the check")
    lib.setRedoWriter(.apple)
    check(lib.redoing?.writer == .apple, "T11R1 check: and the sheet can be changed again")
    lib.commitRedo()
    lib.cancelRedo()
    _ = settle({ false }, timeout: 0.3)
    check(!lib.redoChecking && lib.redoing == nil && r.runner.calls.count == 1, "T11R1 check: Cancel during a check ends it, and nothing is queued")
    r.finish()
}

// MARK: - Sources and consent, round 2 (Stage 3, Task 11)

/// Answers every engine command so far that begins with these words and has not been answered yet, in order.
@MainActor func t11AnswerAll(_ r: T11Rig, _ head: [String], _ status: Int32, _ output: String, after: Int = 0) {
    for i in r.engine.calls.indices where i >= after && r.engine.calls[i].arguments.starts(with: head) { r.engine.answer(i, status, output) }
}

// 1. An open agreement sheet never changes host: Redo overtakes a choice still waiting on its key read, also
// when it returns at once to ask for agreement, and a waiting choice never replaces a request already shown.
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false), Source(kind: .standard, address: t11Bridge, agreed: false)])
    r.app.launch()
    let lib = r.app.library
    let m = r.done("2026-11-14_0900") { $0.writer = .outside(t11BridgeModel) }
    check(r.open(m), "T11R2 host: (a meeting whose own writer is not agreed)")
    lib.perform(.redoMinutes)
    lib.setRedoWriter(.outside(t11Sonnet)) // waits on its key read
    lib.commitRedo() // asks for the sheet's own writer at once
    check(r.app.consent == ConsentRequest(writer: t11BridgeModel, origin: .redo) && r.app.redoConsentShown,
          "T11R2 host: Redo asks for the sheet's own writer, at bridge.example")
    r.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(r.app.consent == ConsentRequest(writer: t11BridgeModel, origin: .redo) && r.app.redoConsentShown,
          "T11R2 host: the key read answering afterwards leaves the request shown as it was, with its host")
    r.app.agree()
    check(r.source(1)?.agreed == true && r.source(0)?.agreed == false && lib.redoing?.writer == .outside(t11BridgeModel),
          "T11R2 host: and agreeing applies to the request shown")
    r.finish()
}
MainActor.assumeIsolated {
    // Redo's early return overtakes the waiting choice by itself: the request it asked for is cancelled before the read answers.
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false), Source(kind: .standard, address: t11Bridge, agreed: false)])
    r.app.launch()
    let lib = r.app.library
    let m = r.done("2026-11-14_0900") { $0.writer = .outside(t11BridgeModel) }
    check(r.open(m), "T11R2 overtaken: (a meeting whose own writer is not agreed)")
    lib.perform(.redoMinutes)
    lib.setRedoWriter(.outside(t11Sonnet))
    lib.commitRedo()
    r.app.cancelConsent()
    r.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(r.app.consent == nil && lib.redoing?.writer == .outside(t11BridgeModel),
          "T11R2 overtaken: a Redo click that returns at once to ask overtakes a choice still waiting on its key read")
    r.finish()
}
MainActor.assumeIsolated {
    // And so does the Redo click that starts the check (the re-reviewer's RR-1 (a)).
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false), Source(kind: .standard, address: t11Ollama, agreed: true)],
                   writer: t11Llama)
    r.app.launch()
    let lib = r.app.library
    let m = r.done("2026-11-14_0900")
    check(r.open(m), "T11R2 overtaken: (a meeting)")
    lib.perform(.redoMinutes)
    lib.setRedoWriter(.outside(t11Sonnet))
    lib.commitRedo()
    r.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(r.app.consent == nil && lib.redoChecking, "T11R2 overtaken: and the Redo click that starts the check, so nothing is asked over it")
    _ = settle { r.runner.calls.count == 1 }
    r.finish()
}
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false), Source(kind: .standard, address: t11Ollama, agreed: false)])
    r.app.launch()
    let m = r.done("2026-11-14_0900")
    check(r.open(m), "T11R2 host: (a meeting)")
    r.app.library.perform(.redoMinutes)
    r.app.library.setRedoWriter(.outside(t11Sonnet)) // waits on its key read, in the meetingbox window
    r.app.preferencesOpened()
    r.app.chooseWriter(t11Llama) // asked at once, in Preferences
    check(r.app.consent == ConsentRequest(writer: t11Llama, origin: .preferences), "T11R2 host: (agreement asked in Preferences)")
    r.answer(["key", "status", "--address", t11Anthropic], 0, "set\n")
    check(r.app.consent == ConsentRequest(writer: t11Llama, origin: .preferences),
          "T11R2 host: a waiting choice decided afterwards never replaces a request already shown")
    r.finish()
}

// 2. A choice waiting on its key read goes when its source changes or goes (decision 8), from a redo sheet and
// from Preferences, so changing it and back, or removing it and adding it again, asks nothing for the old choice.
for (origin, sequence) in [(ConsentOrigin.redo, "changed and back"), (.redo, "removed and added again"),
                           (.preferences, "changed and back"), (.preferences, "removed and added again")] {
    MainActor.assumeIsolated {
        let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: false)])
        r.app.launch()
        if origin == .redo {
            let m = r.done("2026-11-14_0900")
            _ = r.open(m)
            r.app.library.perform(.redoMinutes)
            r.app.library.setRedoWriter(.outside(t11Sonnet))
        } else {
            r.app.preferencesOpened()
            r.app.chooseWriter(t11Sonnet)
        }
        if sequence == "changed and back" {
            _ = r.app.updateSource(at: 0, Source(kind: .standard, address: t11Anthropic, agreed: false))
            _ = r.app.updateSource(at: 0, Source(kind: .claude, address: t11Anthropic, agreed: false))
        } else {
            r.app.removeSource(at: 0)
            _ = r.app.addSource(Source(kind: .claude, address: t11Anthropic, agreed: false))
        }
        t11AnswerAll(r, ["key", "remove"], 0, "none\n")
        t11AnswerAll(r, ["key", "status"], 0, "set\n")
        check(r.calls(["key", "status"]).count >= 2 && r.app.consent == nil && r.prefs.minutesWriter == nil && !r.app.redoConsentShown,
              "T11R2 waiting: a \(origin == .redo ? "redo sheet's" : "Preferences") choice waiting on its key read, its source \(sequence), asks nothing")
        r.finish()
    }
}

// 3. A Preferences choice decided late asks nothing out of place: not once the window has closed, and not over
// the key sheet or the source sheet. The choice is dropped, and the writer stays as it was.
MainActor.assumeIsolated {
    let a = t11Anthropic
    let unreadable = "The keychain could not be read.\n"
    let r = T11Rig(sources: [Source(kind: .claude, address: a, agreed: false)])
    r.app.launch()
    r.app.preferencesOpened()
    r.answer(["key", "status", "--address", a], 1, unreadable) // the key state stays unknown
    r.app.chooseWriter(t11Sonnet)
    r.app.preferencesClosed()
    r.answer(["key", "status", "--address", a], 1, unreadable)
    check(r.app.consent == nil && r.prefs.minutesWriter == nil && r.app.writerNotice == nil,
          "T11R2 window: a read answering after the Preferences window closed asks nothing, and the writer stays as it was")
    r.app.preferencesOpened()
    check(r.app.preferencesSheet == nil && r.app.consent == nil, "T11R2 window: and nothing shows when Preferences next opens")
    r.answer(["key", "status", "--address", a], 1, unreadable)
    r.app.chooseWriter(t11Sonnet)
    r.app.beginKey(at: 0)
    r.app.keyText("sk-ant-typed")
    r.answer(["key", "status", "--address", a], 1, unreadable)
    check(r.app.preferencesSheet == .key && r.app.consent == nil && r.app.keyDraft?.text == "sk-ant-typed",
          "T11R2 window: a read answering while the key sheet is open does not replace it")
    r.app.cancelKey()
    r.app.chooseWriter(t11Sonnet)
    r.app.beginAddSource()
    r.answer(["key", "status", "--address", a], 1, unreadable)
    check(r.app.preferencesSheet == .source && r.app.consent == nil, "T11R2 window: nor the source sheet")
    r.app.cancelSourceDraft()
    r.app.chooseWriter(t11Sonnet)
    r.answer(["key", "status", "--address", a], 1, unreadable)
    check(r.app.consent == ConsentRequest(writer: t11Sonnet, origin: .preferences) && r.app.preferencesSheet == .consent,
          "T11R2 window: with the window open and nothing over it, it asks (the keychain unreadable is not none)")
    r.app.preferencesClosed()
    check(r.app.consent == nil, "T11R2 window: and a request in Preferences goes when the window closes")
    r.finish()
}

// 4. A waiter runs once; beginRedo drops a check still running, so a late check never closes a new sheet; an
// agreed source's model is taken at once, with no key read.
MainActor.assumeIsolated {
    let a = t11Anthropic
    let r = T11Rig(sources: [Source(kind: .claude, address: a, agreed: false)])
    r.app.launch()
    r.app.preferencesOpened()
    r.app.chooseWriter(t11Sonnet)
    r.answer(["key", "status", "--address", a], 0, "none\n")
    check(r.app.writerNotice == "Set a key for this source first." && r.app.consent == nil, "T11R2 once: (no key: Set a key for this source first.)")
    r.app.beginKey(at: 0)
    r.app.keyText("sk-ant-api03-stored")
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: a)
    r.answer(["key", "set"], 0, "set\n")
    r.answer(["key", "status", "--address", a], 0, "set\n")
    check(r.app.keys[a] == true && r.app.consent == nil && r.app.preferencesSheet == nil,
          "T11R2 once: a waiter runs once: storing the key afterwards raises no agreement sheet on its own")
    r.finish()
}
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .standard, address: t11Ollama, agreed: true)], writer: t11Llama)
    r.app.launch()
    let lib = r.app.library
    let m = r.done("2026-11-14_0900")
    check(r.open(m), "T11R2 new sheet: (a meeting)")
    lib.perform(.redoMinutes)
    lib.commitRedo()
    check(lib.redoChecking, "T11R2 new sheet: (Redo's check runs)")
    lib.beginRedo(lib.selectedMeeting!, kind: .transcribe)
    check(!lib.redoChecking && lib.redoing?.kind == .transcribe, "T11R2 new sheet: another redo begun meanwhile is not checking")
    _ = settle({ false }, timeout: 0.5)
    check(lib.redoing?.kind == .transcribe && r.runner.calls.isEmpty && MeetingStore.record(in: m)?.state == .done,
          "T11R2 new sheet: the earlier sheet's check comes back without closing the new sheet or queueing the earlier draft")
    r.finish()
}
MainActor.assumeIsolated {
    let r = T11Rig(sources: [Source(kind: .claude, address: t11Anthropic, agreed: true)])
    r.app.launch()
    r.app.preferencesOpened()
    let reads = r.calls(["key", "status"]).count
    r.app.chooseWriter(t11Sonnet)
    check(r.prefs.minutesWriter == t11Sonnet && r.app.consent == nil && r.calls(["key", "status"]).count == reads,
          "T11R2 agreed: an agreed Claude API source's model is taken at once in Preferences, with no key read")
    let m = r.done("2026-11-14_0900")
    check(r.open(m), "T11R2 agreed: (a meeting)")
    r.app.library.perform(.redoMinutes)
    r.app.library.setRedoWriter(.outside(OutsideWriter(kind: .claude, address: t11Anthropic, model: "claude-haiku-4-5")))
    check(r.app.library.redoing?.writer == .outside(OutsideWriter(kind: .claude, address: t11Anthropic, model: "claude-haiku-4-5"))
          && r.calls(["key", "status"]).count == reads, "T11R2 agreed: and in a redo sheet")
    r.finish()
}

// 5. A key stored after its source went is removed at once.
MainActor.assumeIsolated {
    let a = t11Anthropic
    let r = T11Rig(sources: [Source(kind: .claude, address: a, agreed: false)])
    var keychain = Set<String>() // a stand-in for the keychain: what each answered command did, in the order answered
    r.app.beginKey(at: 0)
    r.app.keyText("sk-ant-api03-probe")
    r.app.saveKey(r.app.keyDraft?.text ?? "", for: a)
    r.app.cancelKey()
    r.app.removeSource(at: 0)
    check(r.engine.calls.map(\.arguments) == [["key", "set", "--address", a], ["key", "remove", "--address", a]],
          "T11R2 late key: (key set still running when the source is removed)")
    r.answer(["key", "remove", "--address", a], 0, "none\n")
    keychain.remove(a)
    r.answer(["key", "set"], 0, "set\n") // it was stored after the remove
    keychain.insert(a)
    let late = Array(r.engine.calls.indices.filter { r.engine.calls[$0].arguments == ["key", "remove", "--address", a] }.dropFirst())
    check(late.count == 1 && late.first == r.engine.calls.count - 1 && r.engine.calls.last?.stdin == nil,
          "T11R2 late key: a key stored for an address no source has is removed at once (key remove --address)")
    for i in late { // only what the app sent changes the stand-in
        r.engine.answer(i, 0, "none\n")
        keychain.remove(a)
    }
    check(keychain.isEmpty && r.app.minutesProblem == nil && r.app.keys[a] == nil, "T11R2 late key: and the keychain ends without it")
    r.finish()
}

// 6. The Edit… sheet and Remove key pick their source by address, not by index.
MainActor.assumeIsolated {
    let changed = "https://bridge2.example/v1"
    let r = T11Rig(sources: [Source(kind: .standard, address: t11Ollama, agreed: true), Source(kind: .standard, address: t11Bridge, agreed: true),
                             Source(kind: .standard, address: t11Other, agreed: true)])
    r.app.beginEditSource(at: 1)
    r.app.updateSourceDraft { $0.address = changed }
    r.app.removeSource(at: 0) // the list shifts under the open sheet
    r.app.saveSourceDraft()
    check(r.prefs.sources == [Source(kind: .standard, address: changed, agreed: false), Source(kind: .standard, address: t11Other, agreed: true)]
          && r.calls(["key", "remove"]).map(\.arguments) == [["key", "remove", "--address", t11Ollama], ["key", "remove", "--address", t11Bridge]]
          && r.app.sourceDraft == nil,
          "T11R2 address: the Edit… sheet changes the source it was opened for, though the list shifted, and the other keeps its agreement and key")
    r.app.beginEditSource(at: 1)
    r.app.updateSourceDraft { $0.address = "https://other2.example/v1" }
    r.app.removeSource(at: 1)
    let before = r.engine.calls.count
    let left = r.prefs.sources
    r.app.saveSourceDraft()
    check(r.prefs.sources == left && r.engine.calls.count == before && r.app.sourceDraft == nil,
          "T11R2 address: when no source has the sheet's address, Save changes nothing, sends nothing and closes the sheet")
    let removes = r.calls(["key", "remove"]).count
    r.app.removeKey(for: t11Other)
    check(r.calls(["key", "remove"]).count == removes, "T11R2 address: Remove key for an address no source has sends nothing")
    r.app.removeKey(for: changed)
    check(r.calls(["key", "remove"]).last?.arguments == ["key", "remove", "--address", changed], "T11R2 address: Remove key acts on the source with that address")
    r.finish()
}

try? fm.removeItem(at: scratch)
if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
