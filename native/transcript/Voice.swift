// The user's voice print (spec 6.2): reading and writing voice.json, when it is usable, learning it from
// calls, and saving it only if nobody changed it while the meeting was processed. Foundation only.
import Foundation

/// voice.json: `{"model", "seconds", "meetings", "sources", "sample", "refusals", "vector", "updated"}`.
/// `sample` is true when the print began from a recorded sample; `refusals` counts calls refused in a row
/// by the print-match test while the print is not usable.
struct VoicePrint: Codable, Equatable {
    var model: String
    var seconds: Double
    var meetings: Int
    var sources: [String]
    var sample: Bool = false
    var refusals: Int = 0
    var vector: [Double]
    var updated: String
}

extension VoicePrint {
    /// A file from before `sample` and `refusals` reads them as false and 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        seconds = try c.decode(Double.self, forKey: .seconds)
        meetings = try c.decode(Int.self, forKey: .meetings)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        sample = try c.decodeIfPresent(Bool.self, forKey: .sample) ?? false
        refusals = try c.decodeIfPresent(Int.self, forKey: .refusals) ?? 0
        vector = try c.decode([Double].self, forKey: .vector)
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
        guard seconds.isFinite, seconds >= 0, meetings >= 0, refusals >= 0, vector.allSatisfy({ $0.isFinite }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "a voice print with impossible numbers"))
        }
    }
}

func decodePrint(_ data: Data) throws -> VoicePrint { try JSONDecoder().decode(VoicePrint.self, from: data) }

func encodePrint(_ print: VoicePrint) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(print)
    data.append(0x0A)
    return data
}

/// The cosine of two vectors; 0 when either is all zeros or their lengths differ.
func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, aa = 0.0, bb = 0.0
    for k in a.indices {
        dot += a[k] * b[k]
        aa += a[k] * a[k]
        bb += b[k] * b[k]
    }
    guard aa > 0, bb > 0 else { return 0 }
    return dot / (aa.squareRoot() * bb.squareRoot())
}

/// The print, if this run may use it: the same speaker model, 60 s or more of speech, and 2 or more
/// meetings or a recorded sample.
func usablePrint(_ print: VoicePrint?, model: String) -> VoicePrint? {
    guard let p = print, p.model == model, atLeast(p.seconds, Rule.usableSeconds), p.meetings >= 2 || p.sample else { return nil }
    return p
}

/// A vector scaled to length 1 (a zero vector stays as it is).
private func scaledToOne(_ v: [Double]) -> [Double] {
    let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return length > 0 ? v.map { $0 / length } : v
}

private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

enum LearnOutcome: Equatable {
    case unchanged
    case write(VoicePrint)
    case discard
}

/// Why a meeting did or did not add to the print, for the meeting's log.
enum LearnReason: Equatable {
    case notACall
    case noCallSpeakers
    case noDominant
    case likeTheCall
    case alreadyLearnt
    case refused
    case discarded
    case learnt(seconds: Double)
}

/// What a first processing does to the print (spec 6.2, "When a meeting adds to it"). `mic` and
/// `keptWords` are the microphone's speakers that are not echo and their kept words; `call` the call
/// side's speakers. A call adds only if: it is a call with at least one call speaker; its dominant
/// microphone speaker holds 80% or more of the kept words; that speaker's cosine with every call speaker
/// is under 0.40; when the print (of this model) holds any speech, its cosine with the print is 0.60 or
/// more; and this meeting has not added to it before. A learnt call is `write` with `refusals` 0. A call
/// refused by the print-match test while the print is not usable is `write` with `refusals` plus 1, or
/// `discard` when that makes 2. Every other case is `unchanged`. Another model's print is replaced.
func learn(_ print: VoicePrint?, mic: [SpeakerInfo], keptWords: [String: Int], call: [SpeakerInfo], isCall: Bool,
           model: String, source: String, now: Date) -> LearnOutcome {
    learnWithReason(print, mic: mic, keptWords: keptWords, call: call, isCall: isCall, model: model, source: source, now: now).outcome
}

/// learn, with the reason the log gives.
func learnWithReason(_ print: VoicePrint?, mic: [SpeakerInfo], keptWords: [String: Int], call: [SpeakerInfo], isCall: Bool,
                     model: String, source: String, now: Date) -> (outcome: LearnOutcome, reason: LearnReason) {
    guard isCall else { return (.unchanged, .notACall) }
    guard !call.isEmpty else { return (.unchanged, .noCallSpeakers) }
    let total = mic.reduce(0) { $0 + (keptWords[$1.id] ?? 0) }
    guard total > 0, let top = mic.max(by: { (keptWords[$0.id] ?? 0) < (keptWords[$1.id] ?? 0) }), top.seconds > 0,
          atLeast(Double(keptWords[top.id] ?? 0) / Double(total), Rule.dominantShare) else {
        return (.unchanged, .noDominant)
    }
    guard !call.contains(where: { atLeast(cosine(top.vector, $0.vector), Rule.learnCallLimit) }) else {
        return (.unchanged, .likeTheCall)
    }
    let own = print.flatMap { $0.model == model ? $0 : nil }
    if let p = own, p.sources.contains(source) { return (.unchanged, .alreadyLearnt) }
    if let p = own, p.seconds > 0, !atLeast(cosine(top.vector, p.vector), Rule.printMatch) {
        if usablePrint(p, model: model) != nil { return (.unchanged, .refused) }
        if p.refusals + 1 >= 2 { return (.discard, .discarded) }
        var counted = p
        counted.refusals += 1
        counted.updated = stamp(now)
        return (.write(counted), .refused)
    }
    let unit = scaledToOne(top.vector)
    var next = VoicePrint(model: model, seconds: top.seconds, meetings: 1, sources: [source], sample: false, refusals: 0,
                          vector: unit, updated: stamp(now))
    if let p = own, p.seconds > 0, p.vector.count == unit.count {
        // each vector at length 1, weighted by its talk
        let old = scaledToOne(p.vector), seconds = p.seconds + top.seconds
        next = VoicePrint(model: model, seconds: seconds, meetings: p.meetings + 1, sources: p.sources + [source], sample: p.sample,
                          refusals: 0, vector: zip(old, unit).map { ($0 * p.seconds + $1 * top.seconds) / seconds }, updated: stamp(now))
    }
    return (.write(next), .learnt(seconds: top.seconds))
}

/// The meeting's log lines for a learning reason. A room recording, or a call without call speakers,
/// says nothing here. A discard says its own line once the print is gone.
func learnLog(_ reason: LearnReason) -> [String] {
    switch reason {
    case .notACall, .noCallSpeakers: return []
    case .noDominant: return ["Your voice was not learnt from this call: no one voice held 80% of the microphone words"]
    case .likeTheCall: return ["Your voice was not learnt from this call: the microphone voice was too like a voice on the call side"]
    case .alreadyLearnt: return ["Your voice was learnt from this meeting before, so it was not learnt again"]
    case .refused, .discarded: return ["This call's microphone voice did not match the voice learnt so far, so it was not learnt"]
    case .learnt(let seconds): return ["Learnt \(Int(seconds.rounded())) s of your voice from this call"]
    }
}

/// What a file was when it was read: its identity and bytes. nil means there was nothing at the path.
struct FileState: Equatable {
    let device: UInt64
    let inode: UInt64
    let regular: Bool
    let contents: Data
}

/// The file at `url` as it is now, or nil when there is nothing there. Anything but a plain file (a link,
/// a folder) has no contents and is never a print.
func fileState(at url: URL) -> FileState? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    let regular = (info.st_mode & S_IFMT) == S_IFREG
    let contents = regular ? (FileManager.default.contents(atPath: url.path) ?? Data()) : Data()
    return FileState(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), regular: regular, contents: contents)
}

private func failure(_ what: String) -> TranscriptError {
    TranscriptError(description: "\(what): \(String(cString: strerror(errno)))")
}

/// Writes the print to `url` only if the file there is as it was when read (`readState`, nil for none),
/// so "Forget my voice" or a new sample during processing holds. It is written to the fixed name
/// `voice.json.tmp` beside it (0600), checked once more, and renamed into place. Returns false, writing
/// nothing, when the file changed or vanished.
func savePrintIfUnchanged(_ print: VoicePrint, at url: URL, readState: FileState?) throws -> Bool {
    guard fileState(at: url) == readState else { return false }
    let data = try encodePrint(print)
    let tmp = url.path + ".tmp"
    if unlink(tmp) != 0 && errno != ENOENT { throw failure("cannot replace \(tmp)") }
    let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw failure("cannot write \(tmp)") }
    var written = data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    written = written && fsync(fd) == 0
    close(fd)
    guard written else { let error = failure("cannot write \(tmp)"); unlink(tmp); throw error }
    guard fileState(at: url) == readState else { unlink(tmp); return false }
    guard rename(tmp, url.path) == 0 else { let error = failure("cannot rename \(tmp)"); unlink(tmp); throw error }
    return true
}

/// Removes the print only if it is as it was when read. Returns false, removing nothing, otherwise.
func discardPrintIfUnchanged(at url: URL, readState: FileState?) throws -> Bool {
    guard let state = readState, fileState(at: url) == state else { return false }
    guard unlink(url.path) == 0 else { throw failure("cannot remove \(url.path)") }
    return true
}
