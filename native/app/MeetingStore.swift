import Darwin
import Foundation

enum MeetingState: String {
    case recording, finalising, queued, processing, done, failed
    /// Never processed and not queued. Inferred by `scan` for a folder with no usable record, and
    /// written by `update` when it starts a record for an old folder. The queue never picks it up.
    case unprocessed
}

/// The `meeting.json` fields. Unknown keys in the file are kept by `MeetingStore.update`.
struct MeetingRecord {
    var id: String
    var title: String?
    var started: Date
    var seconds: Int
    var pausedAt: Date?
    var pausedSeconds: Int?
    var state: MeetingState
    var stage: String?
    var error: String?
    var attempts: Int?
    var attempt: String?
    /// Why a recording ended without being asked to (its recorder went, or the disk stop). Written
    /// once, when it ends; queued, processing, done and a new attempt leave it as it is.
    var stopReason: String?

    /// How many people a redo is told there are on each side (1 to 6); nil is Work it out.
    struct People: Equatable {
        var room: Int?
        var call: Int?

        static let range = 1...6
    }

    /// A redo's kind and choices, written before it runs and cleared on every final outcome: `job`
    /// (absent for a process), and for Transcribe again `jobTranscriber` and `jobTidy`.
    var job: JobKind? { didSet { setFields.insert(.job) } }
    var jobTranscriber: Transcriber? { didSet { setFields.insert(.jobTranscriber) } }
    var jobTidy: Bool? { didSet { setFields.insert(.jobTidy) } }
    /// Kept settings, never cleared by the queue: the writer last chosen and agreed in a sheet for this
    /// meeting, and the counts last chosen in Transcribe again.
    var writer: MeetingWriter? { didSet { setFields.insert(.writer) } }
    var people = People()

    /// The redo fields set since this record was read: `apply` writes only these, and a count only when it
    /// differs from the one read. So a value this version cannot read (a later version's writer or job, a
    /// count out of range), or a key it does not know inside one, stays as it is until the field is set.
    private enum Field { case job, jobTranscriber, jobTidy, writer }
    private var setFields: Set<Field> = []
    /// The counts as they were read.
    private var readPeople = People()
    /// A `job` was there that this version cannot read.
    private var unreadableJob = false

    /// The record names a job this version does not know (a later version's kind, a mistyped word, not a
    /// word at all). It must never run, as a process or as anything else. Setting `job` ends it.
    var jobUnknown: Bool { unreadableJob && !setFields.contains(.job) }

    init(id: String = UUID().uuidString, title: String? = nil, started: Date = Date(), seconds: Int = 0,
         state: MeetingState) {
        self.id = id
        self.title = title
        self.started = started
        self.seconds = seconds
        self.state = state
    }

    private static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: s)
    }

    /// Nil when the object lacks a valid id, started or state.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty,
              let startedText = json["started"] as? String, let started = MeetingRecord.parseDate(startedText),
              let stateText = json["state"] as? String, let state = MeetingState(rawValue: stateText)
              else { return nil }
        self.id = id
        self.started = started
        self.state = state
        self.title = json["title"] as? String
        self.seconds = (json["seconds"] as? NSNumber)?.intValue ?? 0
        self.pausedAt = (json["pausedAt"] as? String).flatMap(MeetingRecord.parseDate)
        self.pausedSeconds = (json["pausedSeconds"] as? NSNumber)?.intValue
        self.stage = json["stage"] as? String
        self.error = json["error"] as? String
        self.attempts = (json["attempts"] as? NSNumber)?.intValue
        self.attempt = json["attempt"] as? String
        self.stopReason = json["stopReason"] as? String
        // A redo's own: only values in their words are taken; anything else reads as absent, and is kept
        // as it is in the file (see `apply`).
        self.job = (json["job"] as? String).flatMap(JobKind.init(rawValue:))
        self.unreadableJob = json["job"] != nil && !(json["job"] is NSNull) && job == nil
        self.jobTranscriber = (json["jobTranscriber"] as? String).flatMap(Transcriber.init(rawValue:))
        self.jobTidy = MeetingRecord.flag(json["jobTidy"])
        self.writer = MeetingRecord.writer(json["writer"])
        let people = json["people"] as? [String: Any]
        self.people = People(room: MeetingRecord.count(people?["room"]), call: MeetingRecord.count(people?["call"]))
        self.readPeople = self.people
    }

    /// true or false, as JSON writes them; nil for anything else (a number or a string included).
    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A whole number from 1 to 6; nil for anything else.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let n = Int(exactly: number.doubleValue), People.range.contains(n) else { return nil }
        return n
    }

    /// `"apple"`, or `{"kind", "address", "model"}` with a kind meetingbox knows.
    private static func writer(_ value: Any?) -> MeetingWriter? {
        if let word = value as? String { return word == "apple" ? .apple : nil }
        guard let object = value as? [String: Any],
              let kind = (object["kind"] as? String).flatMap(SourceKind.init(rawValue:)),
              let address = object["address"] as? String, let model = object["model"] as? String else { return nil }
        return .outside(OutsideWriter(kind: kind, address: address, model: model))
    }

    /// Writes every known field into `json`, removing keys whose value is nil; a redo's fields only when
    /// they were set (`setFields`), and a count only when it changed. Other keys are untouched, and so are
    /// keys inside `people` other than `room` and `call`.
    func apply(to json: inout [String: Any]) {
        let iso = ISO8601DateFormatter()
        func put(_ key: String, _ value: Any?) {
            if let value = value { json[key] = value } else { json.removeValue(forKey: key) }
        }
        json["id"] = id
        put("title", title)
        json["started"] = iso.string(from: started)
        json["seconds"] = seconds
        put("pausedAt", pausedAt.map { iso.string(from: $0) })
        put("pausedSeconds", pausedSeconds)
        json["state"] = state.rawValue
        put("stage", stage)
        put("error", error)
        put("attempts", attempts)
        put("attempt", attempt)
        put("stopReason", stopReason)
        if setFields.contains(.job) { put("job", job == .process ? nil : job?.rawValue) }
        if setFields.contains(.jobTranscriber) { put("jobTranscriber", jobTranscriber?.rawValue) }
        if setFields.contains(.jobTidy) { put("jobTidy", jobTidy) }
        if setFields.contains(.writer) {
            switch writer {
            case .apple?: json["writer"] = "apple"
            case .outside(let w)?: json["writer"] = ["kind": w.kind.rawValue, "address": w.address, "model": w.model]
            case nil: json.removeValue(forKey: "writer")
            }
        }
        let changed = [("room", people.room, readPeople.room), ("call", people.call, readPeople.call)].filter { $0.1 != $0.2 }
        if !changed.isEmpty {
            var counts = json["people"] as? [String: Any] ?? [:] // people that was not an object is replaced
            for (key, value, _) in changed {
                if let value = value { counts[key] = value } else { counts.removeValue(forKey: key) }
            }
            put("people", counts.isEmpty ? nil : counts)
        }
    }
}

struct Meeting {
    let folder: MeetingFolder
    let record: MeetingRecord?
    let state: MeetingState
}

/// The library: scans the Meetings root, owns `meeting.json` writes, and searches transcripts.
final class MeetingStore: @unchecked Sendable {
    // Sendable: the root, the writes and the transcript cache are behind these locks, and `scan` only reads.
    private let rootLock = NSLock()
    private var currentRoot: URL
    private let writeLock = NSLock()
    private let cacheLock = NSLock()
    private var transcripts: [String: String] = [:]
    private let indexQueue = DispatchQueue(label: "meetingbox.store.index", qos: .utility)

    /// The other folders recordings were started in (Preferences.otherRoots in the app), read each time.
    private let otherRoots: () -> [URL]

    init(root: URL, otherRoots: @escaping () -> [URL] = { [] }) {
        currentRoot = root
        self.otherRoots = otherRoots
    }

    /// The Meetings folder. The app moves it when the meetings folder setting changes (never while a
    /// recording is running), so the session, the queue and the library, which share this one store,
    /// all follow at once. A scan already running finishes on the root it began with; `update` takes a
    /// folder's full path and does not depend on it.
    var root: URL {
        get {
            rootLock.lock()
            defer { rootLock.unlock() }
            return currentRoot
        }
        set {
            rootLock.lock()
            currentRoot = newValue
            rootLock.unlock()
        }
    }

    private static func recordURL(_ folder: URL) -> URL { folder.appendingPathComponent("meeting.json") }

    /// The folder's record as `meeting.json` has it now; nil when there is no usable one.
    static func record(in folder: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: recordURL(folder)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return MeetingRecord(json: obj)
    }

    /// Folded for searching: case and accents ignored, so "cafe" finds "Café".
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// The meetings folder, then each other folder a recording was started in that is not the same
    /// folder, each once. The queue's resume and the session's sweep look in all of them; the window
    /// lists `root` alone. One that is not there (a disk not plugged in) is skipped by the scan, and stays.
    var roots: [URL] {
        var all = [root]
        var seen: Set<String> = [root.standardizedFileURL.path]
        for other in otherRoots() where seen.insert(other.standardizedFileURL.path).inserted {
            all.append(other)
        }
        return all
    }

    // MARK: scan

    /// Every meeting folder under the root, newest first. Read-only: it never writes or repairs anything.
    func scan() -> [Meeting] { scan(in: root) }

    /// Every meeting folder in every one of `roots`, newest first.
    func scanEveryRoot() -> [Meeting] { MeetingStore.newestFirst(roots.flatMap(scan(in:))) }

    /// Every meeting folder directly in `root`, newest first; none when it cannot be listed.
    func scan(in root: URL) -> [Meeting] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return MeetingStore.newestFirst(items.compactMap(MeetingStore.meeting(at:)))
    }

    /// The meeting in this folder, as a scan would find it; nil when it is not a meeting folder.
    static func meeting(at item: URL) -> Meeting? {
        guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false,
              let folder = MeetingFolder.parse(item) else { return nil }
        let record = MeetingStore.record(in: item)
        let state: MeetingState
        if let record = record {
            state = record.state
        } else if FileManager.default.fileExists(atPath: item.appendingPathComponent("notes.md").path) {
            state = .done // an earlier version of meetingbox already wrote the minutes
        } else {
            state = .unprocessed
        }
        return Meeting(folder: folder, record: record, state: state)
    }

    private static func newestFirst(_ meetings: [Meeting]) -> [Meeting] {
        meetings.sorted {
            $0.folder.date != $1.folder.date
                ? $0.folder.date > $1.folder.date
                : $0.folder.url.lastPathComponent > $1.folder.url.lastPathComponent
        }
    }

    // MARK: update

    /// Applies `change` to the folder's `meeting.json`, merging into the existing JSON object so
    /// unknown keys survive, and writes atomically. A folder with no `meeting.json` is given a fresh
    /// id. One that will not decode is first copied to `meeting.json.bad-<timestamp>`.
    func update(_ folder: URL, _ change: (inout MeetingRecord) -> Void) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let fm = FileManager.default
        let file = MeetingStore.recordURL(folder)
        var json: [String: Any] = [:]
        var record: MeetingRecord? = nil
        if fm.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let decoded = MeetingRecord(json: obj) {
                json = obj
                record = decoded
            } else {
                try backUpBad(file)
            }
        }
        // A fresh record is never queued as a side effect: it starts as the state a scan would infer.
        let inferred: MeetingState = fm.fileExists(atPath: folder.appendingPathComponent("notes.md").path)
            ? .done : .unprocessed
        var current = record ?? MeetingRecord(started: MeetingFolder.parse(folder)?.date ?? Date(), state: inferred)
        change(&current)
        current.apply(to: &json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try MeetingStore.writePrivately(data, to: file)
    }

    /// Writes through a temp file created 0600, then renames it into place, so the file is never
    /// readable by others and a reader never sees half of it. Session writes its state files with it too.
    static func writePrivately(_ data: Data, to file: URL) throws {
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { failure = errno; return }
                offset += n
            }
        }
        if failure == 0 && fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == 0 && rename(tmp.path, file.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(tmp.path) // our own temp file, created just above
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    private func backUpBad(_ file: URL) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let fm = FileManager.default
        var backup = file.deletingLastPathComponent().appendingPathComponent("meeting.json.bad-\(stamp)")
        var n = 2
        while fm.fileExists(atPath: backup.path) {
            backup = file.deletingLastPathComponent().appendingPathComponent("meeting.json.bad-\(stamp)-\(n)")
            n += 1
        }
        try fm.copyItem(at: file, to: backup)
    }

    // MARK: search

    /// Reads every `transcript.txt` once, on a background queue, into a folded cache, then calls `done`
    /// (on that queue).
    func indexTranscripts(_ done: @escaping () -> Void) {
        indexQueue.async { [self] in
            var fresh: [String: String] = [:]
            for meeting in scan() {
                let file = meeting.folder.url.appendingPathComponent("transcript.txt")
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    fresh[meeting.folder.url.path] = MeetingStore.fold(text)
                }
            }
            cacheLock.lock()
            transcripts = fresh
            cacheLock.unlock()
            done()
        }
    }

    /// True when the folded query is in the meeting's title or its indexed transcript. A blank query
    /// matches everything. Reads only the cache, never the disk.
    func matches(_ meeting: Meeting, query: String) -> Bool {
        let q = MeetingStore.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        let title = meeting.record?.title ?? meeting.folder.displayTitle
        if MeetingStore.fold(title).contains(q) { return true }
        cacheLock.lock()
        let text = transcripts[meeting.folder.url.path]
        cacheLock.unlock()
        return text?.contains(q) ?? false
    }
}
