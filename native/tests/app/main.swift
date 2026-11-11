// sources: ../../app/Preferences.swift ../../app/ControlServer.swift ../../app/MeetingFolder.swift ../../app/MeetingStore.swift ../../app/Session.swift ../../app/ChildRecorder.swift ../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift ../../recorder/Finalise.swift ../../app/ProcessingQueue.swift ../../app/StatusPresentation.swift ../../app/StatusReducer.swift ../../app/LaunchMode.swift ../../app/LibraryPresentation.swift ../../app/LibraryModel.swift ../../app/PreferencesPresentation.swift ../../app/AppModel.swift ../../app/RecordingMenu.swift ../../app/BuildInfo.swift
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
        LibraryPresentation.actions(for: m, phase: phase, files: files)
    }
    check(acts(libMeeting(name, .done), audio) == [.rename, .showInFinder, .playAudio], "L5: a done meeting: Rename, Show in Finder, Play audio")
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
    check(LibraryAction.allCases.map(\.title) == ["Pause", "Resume", "Stop", "Rename…", "Show in Finder", "Play audio", "Process"], "L5: the words")
    // the meeting being recorded
    let live = libMeeting(name, .recording)
    check(acts(live, none, .recording(here)) == [.pause, .stop, .showInFinder], "L5: recording: Pause, Stop, Show in Finder")
    check(acts(live, none, .paused(here)) == [.resume, .stop, .showInFinder], "L5: paused: Resume, Stop, Show in Finder")
    check(acts(live, none, .finalising(here)) == [.showInFinder], "L5: finalising: only Show in Finder")
    // C5: nothing is played while a recording or a pause is under way: system audio would take it in
    check(acts(libMeeting(name, .done), audio, .recording(libURL("2026-10-28_1600"))) == [.rename, .showInFinder],
          "L5, C5: while another meeting records, no Play audio")
    check(acts(libMeeting(name, .unprocessed), audio, .paused(libURL("2026-10-28_1600"))) == [.rename, .showInFinder, .process],
          "L5, C5: nor while it is paused; Process is still offered")
    check(acts(libMeeting(name, .done), audio, .finalising(libURL("2026-10-28_1600"))) == [.rename, .showInFinder, .playAudio],
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
    check(model.actions(for: model.selectedMeeting!) == [.rename, .showInFinder, .playAudio], "W2: its actions")
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
          "C6: Show in Finder opens the meeting's own folder in the Finder (not its parent), opening no file; the message goes")
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

try? fm.removeItem(at: scratch)
if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("all passed")
