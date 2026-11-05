// sources: ../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift ../../recorder/Finalise.swift ../../recorder/Health.swift ../../recorder/DiskFloor.swift ../../recorder/Stop.swift ../../recorder/CaptureError.swift
// The recorder writes crash-safe working files (mic.caf, call.caf) and turns them
// into the three .m4a at stop, or later through recovery. Synthetic sine audio in
// temporary folders only: no devices, no permissions.
import Foundation
import AVFoundation

let sr = 48000

// MARK: - Child mode: write audio, then wait to be killed

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--child" {
    let dir = URL(fileURLWithPath: CommandLine.arguments[2])
    let output = try! RecordingOutput(directory: dir)
    for k in 0..<30 {
        output.write(mic: sine(440, 0.3, 4800, from: k * 4800), system: sine(660, 0.3, 4800, from: k * 4800))
    }
    while output.secondsWritten < 3 { usleep(10_000) }
    FileManager.default.createFile(atPath: dir.appendingPathComponent("ready").path, contents: nil)
    while true { sleep(60) }
}

// Child mode: hold the folder lock for a while from another process, as a dying recorder would.
if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--hold" {
    let fd = open(CommandLine.arguments[2], O_RDONLY)
    flock(fd, LOCK_EX)
    FileManager.default.createFile(atPath: CommandLine.arguments[4], contents: nil)
    usleep(useconds_t(Double(CommandLine.arguments[3])! * 1_000_000))
    exit(0)
}

// MARK: - Helpers

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

func sine(_ hz: Double, _ amp: Float, _ count: Int, from start: Int = 0) -> [Float] {
    (0..<count).map { amp * Float(sin(2 * Double.pi * hz * Double(start + $0) / Double(sr))) }
}

let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("mb-recorder-test-\(getpid())")
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
var folderCount = 0
func newFolder() -> URL {
    folderCount += 1
    let dir = scratch.appendingPathComponent("m\(folderCount)")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func exists(_ dir: URL, _ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
func names(_ dir: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1 }
func inode(_ dir: URL, _ name: String) -> UInt64 {
    var st = stat()
    return stat(dir.appendingPathComponent(name).path, &st) == 0 ? UInt64(st.st_ino) : 0
}
func duration(_ dir: URL, _ name: String) -> Double { Finaliser.duration(of: dir.appendingPathComponent(name)) ?? 0 }
let finals = ["audio.m4a", "mic.m4a", "call.m4a"]

/// Names, sizes, inodes and modification times: enough to tell that nothing changed.
func snapshot(_ dir: URL) -> [String] {
    names(dir).map { name in
        var st = stat()
        stat(dir.appendingPathComponent(name).path, &st)
        return "\(name) \(st.st_size) \(st.st_ino) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }
}

/// A folder holding mic.caf and call.caf, as a recorder leaves it when killed.
func cafFolder(micSeconds: Double = 3, callSeconds: Double = 3) -> URL {
    let dir = newFolder()
    for (name, hz, secs) in [("mic.caf", 440.0, micSeconds), ("call.caf", 660.0, callSeconds)] {
        let file = try! AVAudioFile(forWriting: dir.appendingPathComponent(name), settings: RecordingOutput.workingSettings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(secs * Double(sr))
        let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let samples = sine(hz, 0.3, n)
        for i in 0..<n { buffer.floatChannelData![0][i] = samples[i] }
        try! file.write(from: buffer)
    }
    return dir
}

func complete(_ dir: URL) -> Bool {
    Finaliser.verify(directory: dir) && exists(dir, ".recording-complete")
        && !exists(dir, "mic.caf") && !exists(dir, "call.caf")
        && !names(dir).contains { $0.hasPrefix(".tmp-") }
}

struct Interrupt: Error {}

/// Free space for a --recover that is not about room: far more than any test folder needs.
let ample: (URL) -> Int64? = { _ in 5_000_000_000 }

// Files must come out 0600 whatever umask the caller left, so loosen it here.
umask(0o022)

// MARK: - The mixing rule

check(AudioMixer.mix([0.1], [0.2]).first.map { abs($0 - 0.3) < 1e-6 } == true, "mix: adds the two sides")
check(AudioMixer.mix([0.7, -0.7], [0.6, -0.6]) == [1, -1], "mix: clips to -1...1")
check(AudioMixer.mix([0.5, 0.5], [0.25]) == [0.75, 0.5], "mix: a shorter side is padded with silence")

// MARK: - A clean recording: write 3 s, then finish

do {
    let dir = newFolder()
    let output = try RecordingOutput(directory: dir)
    for k in 0..<30 {
        output.write(mic: sine(440, 0.3, 4800, from: k * 4800), system: sine(660, 0.3, 4800, from: k * 4800))
    }
    while output.secondsWritten < 3 { usleep(10_000) }
    check(exists(dir, "mic.caf") && exists(dir, "call.caf"), "recording: writes mic.caf and call.caf")
    check(!finals.contains { exists(dir, $0) }, "recording: no .m4a until it stops")
    check(mode(dir.appendingPathComponent("mic.caf")) == 0o600 && mode(dir.appendingPathComponent("call.caf")) == 0o600,
          "recording: working files are 0600")
    let caf = try AVAudioFile(forReading: dir.appendingPathComponent("mic.caf"))
    check(caf.fileFormat.commonFormat == .pcmFormatInt16 && caf.fileFormat.sampleRate == 48000 && caf.fileFormat.channelCount == 1,
          "recording: working files are 16-bit PCM, 48 kHz, mono")

    // As the recorder does: from async top-level code, on the main actor.
    try await MainActor.run { try output.finish() }
    check(finals.allSatisfy { exists(dir, $0) }, "finish: audio.m4a, mic.m4a and call.m4a written")
    check(finals.allSatisfy { abs(duration(dir, $0) - 3) < 0.25 }, "finish: each about 3 s long (\(finals.map { duration(dir, $0) }))")
    check(!exists(dir, "mic.caf") && !exists(dir, "call.caf"), "finish: working files removed")
    check(exists(dir, ".recording-complete"), "finish: completion marker written")
    check(!names(dir).contains { $0.hasPrefix(".tmp-") }, "finish: no temporaries left")
    check(names(dir).allSatisfy { mode(dir.appendingPathComponent($0)) == 0o600 }, "finish: every file is 0600")
} catch {
    check(false, "clean recording: \(error)")
}

// A folder that already holds a recording is never written into.
for name in ["mic.caf", "audio.m4a", ".recording-complete"] {
    let dir = newFolder()
    fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
    let before = snapshot(dir)
    check((try? RecordingOutput(directory: dir)) == nil && snapshot(dir) == before, "refuses a folder that already has \(name)")
}

// MARK: - Killed while recording, then recovered

do {
    let dir = newFolder()
    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["--child", dir.path]
    try child.run()
    var waited = 0
    while !exists(dir, "ready") && waited < 1000 { usleep(10_000); waited += 1 }
    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()
    try? fm.removeItem(at: dir.appendingPathComponent("ready"))
    check(exists(dir, "mic.caf") && exists(dir, "call.caf") && !finals.contains { exists(dir, $0) },
          "kill -9: leaves mic.caf and call.caf, no .m4a")

    try recover(directory: dir)
    let d = finals.map { duration(dir, $0) }
    check(complete(dir), "kill -9: recover gives three verified .m4a, the marker, no .caf")
    check(d.allSatisfy { $0 > 2 } && d.max()! - d.min()! <= 1, "kill -9: the three agree within 1 s and kept the audio (\(d))")
    check(names(dir).allSatisfy { mode(dir.appendingPathComponent($0)) == 0o600 }, "kill -9: recovered files are 0600")
} catch {
    check(false, "kill -9: \(error)")
}

// MARK: - Finalise interrupted part way, then recovered (Review Focus 5)

do {
    let dir = cafFolder()
    do {
        try Finaliser.finalise(directory: dir) { step in
            if step == .encoded("audio.m4a") { throw Interrupt() }
        }
        check(false, "interrupted after .tmp-audio.m4a: hook did not fire")
    } catch is Interrupt {}
    check(names(dir) == [".tmp-audio.m4a", "call.caf", "mic.caf"], "interrupted after .tmp-audio.m4a: only that temporary (\(names(dir)))")
    try recover(directory: dir)
    check(complete(dir), "interrupted after .tmp-audio.m4a: recover ends complete")
} catch {
    check(false, "interrupted after .tmp-audio.m4a: \(error)")
}

do {
    let dir = cafFolder()
    do {
        try Finaliser.finalise(directory: dir) { step in
            if step == .published("mic.m4a") { throw Interrupt() }
        }
        check(false, "interrupted after audio.m4a and mic.m4a: hook did not fire")
    } catch is Interrupt {}
    check(exists(dir, "audio.m4a") && exists(dir, "mic.m4a") && !exists(dir, "call.m4a")
          && exists(dir, "mic.caf") && exists(dir, "call.caf") && !exists(dir, ".recording-complete"),
          "interrupted after audio.m4a and mic.m4a: call.m4a not yet published, .caf kept")
    let kept = [inode(dir, "audio.m4a"), inode(dir, "mic.m4a")]
    try recover(directory: dir)
    check(complete(dir), "interrupted after audio.m4a and mic.m4a: recover ends complete")
    check([inode(dir, "audio.m4a"), inode(dir, "mic.m4a")] == kept, "interrupted after audio.m4a and mic.m4a: verified audio not overwritten")
} catch {
    check(false, "interrupted after audio.m4a and mic.m4a: \(error)")
}

// Unverified output from an earlier attempt is replaced.
do {
    let dir = cafFolder()
    fm.createFile(atPath: dir.appendingPathComponent("call.m4a").path, contents: Data("half written".utf8))
    try recover(directory: dir)
    check(complete(dir), "an unreadable call.m4a from an earlier attempt is replaced")
} catch {
    check(false, "unreadable call.m4a: \(error)")
}

// The two sides of different lengths still give three aligned files.
do {
    let dir = cafFolder(micSeconds: 2, callSeconds: 3)
    try recover(directory: dir)
    let d = finals.map { duration(dir, $0) }
    check(complete(dir) && d.allSatisfy { abs($0 - 3) < 0.25 }, "sides of different lengths: three files of the longer length (\(d))")
} catch {
    check(false, "sides of different lengths: \(error)")
}

// Crash after publishing all three, before the marker: accepted as it is.
do {
    let source = cafFolder()
    try recover(directory: source)
    let dir = newFolder()
    for name in finals { try fm.copyItem(at: source.appendingPathComponent(name), to: dir.appendingPathComponent(name)) }
    let kept = finals.map { inode(dir, $0) }
    try recover(directory: dir)
    check(complete(dir) && finals.map { inode(dir, $0) } == kept, "three verified .m4a without the marker: accepted, marker added, audio untouched")
} catch {
    check(false, "three verified .m4a without the marker: \(error)")
}

// A finished folder is left exactly as it is.
do {
    let dir = cafFolder()
    try recover(directory: dir)
    let before = snapshot(dir)
    try recover(directory: dir)
    check(snapshot(dir) == before, "a folder with the marker is left exactly as it is")
} catch {
    check(false, "folder with the marker: \(error)")
}

// Nothing to recover from: fail and change nothing.
for (label, files) in [("nothing", [String]()), ("an unreadable audio.m4a", ["audio.m4a"]), ("mic.caf alone", ["mic.caf"])] {
    let dir = newFolder()
    for name in files { fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8)) }
    let before = snapshot(dir)
    check((try? recover(directory: dir)) == nil && snapshot(dir) == before, "\(label): recover fails and changes nothing")
    check(recoverStatus(directory: dir, freeBytes: ample).status == 1, "\(label): --recover exits 1")
}

// Another process holding the folder's lock: a recorder still dying after kill -9.
/// Starts a process that holds the lock on `dir` for `seconds`, once it has the lock.
func holdLock(_ dir: URL, for seconds: Double) -> Process {
    let ready = scratch.appendingPathComponent("held-\(dir.lastPathComponent)")
    let holder = Process()
    holder.executableURL = Bundle.main.executableURL
    holder.arguments = ["--hold", dir.path, String(seconds), ready.path]
    try! holder.run()
    while !fm.fileExists(atPath: ready.path) { usleep(10_000) }
    return holder
}

do {
    let dir = cafFolder()
    let holder = holdLock(dir, for: 1.5)
    let started = Date()
    let recovered = (try? recover(directory: dir)) != nil
    check(recovered && complete(dir) && Date().timeIntervalSince(started) >= 1,
          "recover waits for a lock released 1.5 s later, then succeeds")
    holder.waitUntilExit()
}

do {
    let dir = cafFolder()
    let holder = holdLock(dir, for: 7)
    let before = snapshot(dir)
    let started = Date()
    var message = ""
    do { try recover(directory: dir) } catch { message = error.localizedDescription }
    let waited = Date().timeIntervalSince(started)
    check(message.contains("is still being recorded or saved") && snapshot(dir) == before && waited >= 4.5 && waited < 6.5,
          "a lock held past 5 s: recover fails after about 5 s and changes nothing (\(String(format: "%.1f", waited)) s)")
    // The same lock seen by --recover's exit status: 75 (EX_TEMPFAIL), busy, not 1.
    let quick = recoverStatus(directory: dir, lockWait: 0, freeBytes: ample)
    check(quick.status == 75 && quick.message.contains("is still being recorded or saved") && snapshot(dir) == before,
          "--recover exits 75 while another process holds the folder lock")
    holder.terminate()
    holder.waitUntilExit()
}

// The recorder itself never waits: a second recorder in a locked folder fails at once.
do {
    let dir = newFolder()
    let holder = holdLock(dir, for: 3)
    let started = Date()
    check((try? RecordingOutput(directory: dir)) == nil && Date().timeIntervalSince(started) < 0.5,
          "a recorder does not wait for a locked folder")
    holder.terminate()
    holder.waitUntilExit()
}

// MARK: - Health

do {
    var t = Date(timeIntervalSince1970: 1000)
    let health = HealthMonitor(now: { t })
    check(health.line() == "health mic=ok system=ok", "health: ok at the start")
    for _ in 0..<6 {
        t += 1
        health.buffer(from: .mic)
    }
    check(health.line() == "health mic=ok system=stalled", "health: a source with no buffers for 5 s is stalled")
    health.buffer(from: .system)
    check(health.line() == "health mic=ok system=ok", "health: buffers again, ok again")
    t += 4.9
    check(health.line() == "health mic=ok system=ok", "health: under 5 s without buffers is still ok")
    health.error(from: .system)
    health.buffer(from: .system)
    check(health.line() == "health mic=ok system=error", "health: a stream error sticks")
}

// MARK: - The disk floor (Gate 2)
// A recorder whose app has gone (crashed, quit with "keep recording", not reopened) would run until
// the disk is full. It watches the free space of its own output volume and stops itself below
// 100 MB, as on SIGINT. A fake free-space source stands in for the disk: a real full disk is never needed.

/// Counts calls and gives out free space from a script of values; the last value repeats.
final class FakeDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64?]
    private(set) var asked: [URL] = []
    private(set) var low = 0
    private(set) var lines: [String] = []
    init(_ values: [Int64?]) { self.values = values }
    func free(_ url: URL) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        asked.append(url)
        return values.count > 1 ? values.removeFirst() : values.first ?? nil
    }
    func report(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func onLow() { lock.lock(); low += 1; lock.unlock() }
    var askedCount: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
    var lowCount: Int { lock.lock(); defer { lock.unlock() }; return low }
    var reported: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// A value shared with timers and other threads.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; usleep(10_000) }
    return cond()
}

do {
    check(DiskFloor.bytes == 100_000_000, "G2: the floor is 100 MB, decimal")
    check(DiskFloor.interval == 10, "G2: the free space is checked every 10 s")
    check(DiskFloor.message == "stopped: the disk is nearly full", "G2: the line the recorder writes is exact")

    let out = newFolder()
    func make(_ disk: FakeDisk, floor: Int64 = DiskFloor.bytes, interval: TimeInterval = 10) -> DiskFloor {
        DiskFloor(directory: out, floor: floor, interval: interval, freeBytes: { disk.free($0) },
                  report: { disk.report($0) }, onLow: { disk.onLow() })
    }

    // one check, by hand
    let plenty = FakeDisk([5_000_000_000])
    let a = make(plenty)
    a.check(); a.check()
    check(plenty.lowCount == 0 && plenty.reported.isEmpty, "G2: plenty of space never stops the recorder")
    check(plenty.asked.allSatisfy { $0 == out } && plenty.askedCount == 2, "G2: the free space asked about is the output folder's")

    let edge = FakeDisk([100_000_000])
    make(edge).check()
    check(edge.lowCount == 0, "G2: exactly 100 MB free is not below the floor")

    let under = FakeDisk([99_999_999])
    let b = make(under)
    b.check()
    check(under.lowCount == 1 && under.reported == ["stopped: the disk is nearly full"], "G2: below 100 MB it stops, with the one line")
    b.check(); b.check()
    check(under.lowCount == 1 && under.reported.count == 1, "G2: it stops once and says so once, however often it is asked")

    let unreadable = FakeDisk([nil])
    make(unreadable).check()
    check(unreadable.lowCount == 0 && unreadable.reported.isEmpty, "G2: space that cannot be read does not stop a recording")

    let custom = FakeDisk([400])
    make(custom, floor: 500).check()
    check(custom.lowCount == 1, "G2: the floor can be set for a test")

    // on its timer: fine, fine, then the disk fills
    let filling = FakeDisk([900, 800, 700, 50, 40])
    let timed = make(filling, floor: 100, interval: 0.03)
    timed.start()
    check(waitUntil(5) { filling.lowCount == 1 }, "G2: on its timer it notices the disk filling")
    usleep(300_000)
    check(filling.lowCount == 1 && filling.reported == ["stopped: the disk is nearly full"],
          "G2: and stops asking once it has stopped the recorder")
    let askedAtStop = filling.askedCount
    usleep(150_000)
    check(filling.askedCount == askedAtStop, "G2: the timer is cancelled after that")

    // the first check is at once, so a recorder started into a full disk does not wait 10 s
    let full = FakeDisk([10])
    let immediate = make(full, floor: 100, interval: 600)
    immediate.start()
    check(waitUntil(5) { full.lowCount == 1 }, "G2: the first check is at the start, not one interval later")

    // cancelled, it stays quiet
    let quiet = FakeDisk([10])
    let cancelled = make(quiet, floor: 100, interval: 0.03)
    cancelled.cancel()
    cancelled.start()
    usleep(200_000)
    check(quiet.lowCount == 0 && quiet.askedCount == 0, "G2: cancel before start keeps it quiet")
    let later = FakeDisk([1000])
    let stopped = make(later, floor: 100, interval: 0.03)
    stopped.start()
    check(waitUntil(5) { later.askedCount >= 2 }, "G2: it keeps asking while all is well")
    stopped.cancel()
    usleep(100_000)
    let askedAtCancel = later.askedCount
    usleep(150_000)
    check(later.askedCount == askedAtCancel && later.lowCount == 0, "G2: cancel stops the timer")

    // the real source, on a scratch folder: its volume, or its nearest parent that exists
    let real = DiskFloor.freeBytes(near: scratch)
    check(real != nil && real! > 0, "G2: the real source reads the free space of a folder")
    let viaParent = DiskFloor.freeBytes(near: scratch.appendingPathComponent("not/made/yet"))
    check(viaParent != nil && real != nil && abs(viaParent! - real!) < 100_000_000,
          "G2: a folder not made yet is read through its nearest parent")
}

// MARK: - Room to finish (Gate 2 fix round 1, I2)
// A stop must leave room for the three .m4a, or finalising a long recording fills the disk to zero.
// The floors are therefore a reserve plus what finalising needs for the audio recorded so far.

do {
    // The figure, from what Finalise.swift really does: three mono AAC files at 96 kbit/s.
    check(Finaliser.finals.count == 3 && (Finaliser.encodeSettings[AVEncoderBitRateKey] as? Int) == 96_000
          && (Finaliser.encodeSettings[AVNumberOfChannelsKey] as? Int) == 1,
          "I2: finalising writes three mono files at 96 kbit/s")
    check(Finaliser.finishBytesPerSecond == 36_000, "I2: that is 36 000 bytes per recorded second")
    check(Finaliser.finishNeed(seconds: 0) == 0 && Finaliser.finishNeed(seconds: -3) == 0 && Finaliser.finishNeed(seconds: .nan) == 0,
          "I2: nothing recorded needs nothing")
    check(Finaliser.finishNeed(seconds: 1) == 45_000, "I2: the need is 36 000 x seconds x 1.25")
    check(Finaliser.finishNeed(seconds: 3600) == 162_000_000 && Finaliser.finishNeed(seconds: 7 * 3600) == 1_134_000_000,
          "I2: an hour needs 162 MB, seven hours 1.134 GB")

    // Measured: a real finalise of 20 s writes no more than the estimate, and not a great deal less.
    let dir = cafFolder(micSeconds: 20, callSeconds: 20)
    try recover(directory: dir)
    let total = finals.reduce(0) { sum, name in
        sum + ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size]) as? Int ?? 0)
    }
    check(complete(dir) && Int64(total) <= Finaliser.finishNeed(seconds: 20) && total > 36_000 * 20 / 2,
          "I2: the three real .m4a of 20 s fit the estimate (\(total) of \(Finaliser.finishNeed(seconds: 20)) bytes)")
} catch {
    check(false, "I2: the figure: \(error)")
}

do {
    check(DiskFloor.stopBytes(secondsWritten: 0) == 100_000_000, "I2: the recorder's floor starts at 100 MB")
    check(DiskFloor.stopBytes(secondsWritten: 3600) == 262_000_000, "I2: and takes an hour's finalising on top: 262 MB")
    check(DiskFloor.stopBytes(secondsWritten: 7 * 3600) == 1_234_000_000, "I2: seven hours: 1.234 GB")
    check(DiskFloor.stopBytes(secondsWritten: 10, floor: 500) == 500 + 450_000, "I2: the reserve can be set for a test")

    // The floor rises with the recording: 200 MB is plenty at the start and too little after an hour.
    let out = newFolder()
    let seconds = Locked(0.0)
    func make(_ disk: FakeDisk) -> DiskFloor {
        DiskFloor(directory: out, secondsWritten: { seconds.value }, freeBytes: { disk.free($0) },
                  report: { disk.report($0) }, onLow: { disk.onLow() })
    }
    let early = FakeDisk([200_000_000])
    make(early).check()
    check(early.lowCount == 0, "I2: 200 MB free is enough at the start of a recording")
    seconds.value = 3600
    let late = FakeDisk([261_999_999])
    make(late).check()
    check(late.lowCount == 1 && late.reported == [DiskFloor.message], "I2: below 262 MB after an hour it stops, with the same line")
    let exact = FakeDisk([262_000_000])
    make(exact).check()
    check(exact.lowCount == 0, "I2: exactly the floor is not below it")
    seconds.value = 7 * 3600
    let orphan = FakeDisk([1_000_000_000])
    make(orphan).check()
    check(orphan.lowCount == 1, "I2: a seven-hour orphan with 1 GB left stops, as 1 GB is below its 1.234 GB floor (100 MB and 1.134 GB to finish)")
}

// The stop request: one request whoever makes it, and the first reason stands.
do {
    let stop = StopRequest()
    check(stop.reason == nil, "M3: nothing is requested at first")
    let stopped = Locked(0)
    stop.onStop { stopped.value += 1 }
    stop.request(.diskFloor)
    stop.request(.signal)
    check(stop.reason == .diskFloor, "M3: the first reason stands")
    await stop.wait()
    check(stopped.value == 1, "M3: whatever hangs on the stop runs once")

    let later = StopRequest()
    let signalled = Task.detached { try? await Task.sleep(nanoseconds: 100_000_000); later.request(.signal) }
    await later.wait()
    check(later.reason == .signal, "M3: a wait is ended by the request, from another thread")
    _ = await signalled.value
}

// What runRecorder wires: the floor asks for the stop, through the request a signal also uses.
do {
    let out = newFolder()
    let disk = FakeDisk([10_000_000_000, 10_000_000_000, 50_000_000])
    let stop = StopRequest()
    let watch = DiskFloor.watching(out, secondsWritten: { 0 }, stop: stop, interval: 0.03,
                                   freeBytes: { disk.free($0) }, report: { disk.report($0) })
    check(waitUntil(5) { stop.reason != nil }, "M3: the floor asks for the stop when the disk fills")
    await stop.wait()
    check(stop.reason == .diskFloor && disk.reported == ["stopped: the disk is nearly full"],
          "M3: as the floor's, with the one line")
    check(disk.asked.allSatisfy { $0 == out }, "M3: it watched the output folder")
    watch.cancel()

    let calm = FakeDisk([10_000_000_000])
    let quiet = StopRequest()
    let watching = DiskFloor.watching(out, secondsWritten: { 0 }, stop: quiet, interval: 0.03,
                                      freeBytes: { calm.free($0) }, report: { calm.report($0) })
    check(waitUntil(5) { calm.askedCount >= 3 } && quiet.reason == nil, "M3: plenty of space asks for nothing")
    watching.cancel()
}

// The end of a recording, as runRecorder calls it, with a real output and fake free space.
/// A recording of `seconds` whole seconds, still open as the recorder holds it at a stop.
final class OpenRecording {
    var output: RecordingOutput?
    let dir = newFolder()
    init(seconds: Int) {
        let output = try! RecordingOutput(directory: dir)
        for k in 0..<(seconds * 10) {
            output.write(mic: sine(440, 0.3, 4800, from: k * 4800), system: sine(660, 0.3, 4800, from: k * 4800))
        }
        self.output = output
    }
    func end(_ stop: StopRequest, free: (URL) -> Int64?) -> Ending {
        endRecording(output: output!, stop: stop, directory: dir, freeBytes: free)
    }
}
func requested(_ reason: StopRequest.Reason) -> StopRequest {
    let stop = StopRequest()
    stop.request(reason)
    return stop
}
func untouched(_ dir: URL) -> Bool {
    exists(dir, "mic.caf") && exists(dir, "call.caf") && !finals.contains { exists(dir, $0) }
        && !exists(dir, ".recording-complete") && !names(dir).contains { $0.hasPrefix(".tmp-") }
}
let tooFull = "the disk is too full to finish the recording; free some space, then run: meetingbox recover "

do {
    // 3 s recorded: finalising needs 135 000 bytes.
    let rec = OpenRecording(seconds: 3)
    check(rec.end(requested(.diskFloor), free: { _ in 134_999 }) == .refused(tooFull + rec.dir.path),
          "I2: at the floor with less than finalising needs it refuses, with the line")
    check(untouched(rec.dir), "I2: and encodes nothing: the working files are kept, no .m4a, no temporaries, no marker (\(names(rec.dir)))")
    rec.output = nil // the recorder exits, and the folder's lock with it
    try recover(directory: rec.dir)
    check(complete(rec.dir), "I2: once there is room, recover finishes it from those files")
} catch {
    check(false, "I2: refusing: \(error)")
}

do {
    let rec = OpenRecording(seconds: 3)
    var asked: [URL] = []
    let result = rec.end(requested(.diskFloor), free: { asked.append($0); return 135_000 })
    check(result == .saved && complete(rec.dir) && asked == [rec.dir], "I2: exactly what finalising needs is room enough, and the output folder is asked")
}

do {
    let rec = OpenRecording(seconds: 3)
    check(rec.end(requested(.diskFloor), free: { _ in 5_000_000_000 }) == .saved && complete(rec.dir),
          "I2: at the floor with room to finish, it finishes as ever")
}

do {
    let rec = OpenRecording(seconds: 3)
    check(rec.end(requested(.diskFloor), free: { _ in nil }) == .saved && complete(rec.dir),
          "I2: space that cannot be read is not a reason to refuse")
}

do {
    let rec = OpenRecording(seconds: 3)
    check(rec.end(requested(.signal), free: { _ in 1 }) == .saved && complete(rec.dir),
          "I2: only the floor's stop is refused; a stop by signal finalises as before")
}

do {
    // The seconds are what was written, so a longer recording needs more room.
    let rec = OpenRecording(seconds: 6)
    check(rec.end(requested(.diskFloor), free: { _ in 269_999 }) == .refused(tooFull + rec.dir.path) && untouched(rec.dir),
          "I2: six seconds need 270 000 bytes: 269 999 is refused")
}

do {
    // A finalise that fails for another reason is reported as that.
    let rec = OpenRecording(seconds: 2)
    rec.output!.close()
    try fm.removeItem(at: rec.dir.appendingPathComponent("mic.caf"))
    if case .failed(let message) = rec.end(requested(.signal), free: { _ in 5_000_000_000 }) {
        check(message.contains("no working files to recover from"), "I2: a failed finalise comes back as failed, with its reason (\(message))")
    } else {
        check(false, "I2: a failed finalise comes back as failed")
    }
} catch {
    check(false, "I2: a failed finalise: \(error)")
}

// A finalise that fails part way, for want of space, must not leave the disk full: its own
// temporaries go, the working files stay, and the next attempt works.
do {
    struct DiskFull: Error {}
    let dir = cafFolder()
    fm.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data("mine".utf8))
    var calls = 0
    var thrown: Error?
    do {
        try Finaliser.finalise(directory: dir, encode: { name, output, mic, call in
            calls += 1
            if calls == 1 {
                try Finaliser.encode(name, output, mic, call)
            } else {
                fm.createFile(atPath: output.path, contents: Data(repeating: 1, count: 4096))
                throw DiskFull()
            }
        })
    } catch { thrown = error }
    check(thrown is DiskFull && calls == 2, "I2: an encode that fails fails the finalise with its own error")
    check(names(dir) == ["call.caf", "mic.caf", "notes.txt"],
          "I2: its .tmp-*.m4a files are removed, the .caf files and anything else are kept (\(names(dir)))")
    try recover(directory: dir)
    check(complete(dir) && exists(dir, "notes.txt"), "I2: and a later recover finishes the folder")
} catch {
    check(false, "I2: failed encode: \(error)")
}

// The same when every encode returns but the files do not verify: the three temporaries go, nothing else.
do {
    let dir = cafFolder()
    fm.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data("mine".utf8))
    fm.createFile(atPath: dir.appendingPathComponent(".tmp-theirs").path, contents: Data("not this run's".utf8))
    var calls = 0
    var message = ""
    do {
        try Finaliser.finalise(directory: dir, encode: { name, output, mic, call in
            calls += 1
            if calls < 3 {
                try Finaliser.encode(name, output, mic, call)
            } else {
                fm.createFile(atPath: output.path, contents: Data(repeating: 1, count: 4096)) // returns, but is not audio
            }
        })
    } catch { message = error.localizedDescription }
    check(calls == 3 && message.contains("did not verify"), "I2: encodes that return but do not verify fail the finalise with that reason (\(message))")
    check(names(dir) == [".tmp-theirs", "call.caf", "mic.caf", "notes.txt"],
          "I2: all three .tmp-*.m4a of this run are removed; the .caf files, other .tmp- names and anything else are kept (\(names(dir)))")
    try fm.removeItem(at: dir.appendingPathComponent(".tmp-theirs"))
    try recover(directory: dir)
    check(complete(dir) && exists(dir, "notes.txt"), "I2: and a later recover finishes the folder")
} catch {
    check(false, "I2: failed verify: \(error)")
}

// A simulated crash is not an encode that failed: its temporary stays, for recovery to clear.
do {
    let dir = cafFolder()
    do { try Finaliser.finalise(directory: dir, afterStep: { step in if step == .encoded("audio.m4a") { throw Interrupt() } }) } catch is Interrupt {}
    check(exists(dir, ".tmp-audio.m4a"), "I2: only a failed encode clears the temporaries; an interruption elsewhere leaves them")
}

// MARK: - Recovery looks for room first (Gate 2 fix round 2, item 4)
// --recover gets the stop's check: the three .m4a need finishNeed of the seconds the working files hold
// (frames of the longer one over 48 000). Too little room: nothing is encoded, the files stay, the same
// line is printed and the exit status is a refused stop's. Fake free space, as in the stop's tests above.

do {
    check(Finaliser.refusedStatus == 1, "R2: a refusal exits 1, as a refused stop does")
    check(Finaliser.tooFullLine(directory: URL(fileURLWithPath: "/x/y")) == tooFull + "/x/y",
          "R2: it is the same line a refused stop prints")
    check(Finaliser.workingSeconds(in: cafFolder(micSeconds: 2, callSeconds: 6)) == 6, "R2: the seconds are the longer file's frames over 48 000")
    check(Finaliser.workingSeconds(in: newFolder()) == nil, "R2: no working files, no seconds")
}

do {
    // 3 s on each side: finalising needs 135 000 bytes.
    let dir = cafFolder()
    let before = snapshot(dir)
    var asked: [URL] = []
    let refused = recoverStatus(directory: dir, freeBytes: { asked.append($0); return 134_999 })
    check(refused.status == 1 && refused.message == tooFull + dir.path, "R2: with less room than finalising needs, --recover refuses with the line, exit 1")
    check(snapshot(dir) == before && untouched(dir), "R2: and encodes nothing: both .caf as they were, no .m4a, no temporaries, no marker (\(names(dir)))")
    check(asked == [dir], "R2: the recording folder is the one asked about")
    let enough = recoverStatus(directory: dir, freeBytes: { _ in 135_000 })
    check(enough.status == 0 && enough.message == "Recovered \(dir.path)" && complete(dir),
          "R2: exactly what finalising needs is room enough, and the same folder then recovers")
}

do {
    // The longer file counts: 2 s and 6 s need 270 000 bytes, not 90 000.
    let dir = cafFolder(micSeconds: 2, callSeconds: 6)
    check(recoverStatus(directory: dir, freeBytes: { _ in 269_999 }) == (1, tooFull + dir.path) && untouched(dir),
          "R2: 2 s and 6 s need 270 000 bytes (the longer file): 269 999 is refused")
    check(recoverStatus(directory: dir, freeBytes: { _ in 270_000 }).status == 0 && complete(dir), "R2: and 270 000 recovers")
}

do {
    let dir = cafFolder()
    let result = recoverStatus(directory: dir, freeBytes: { _ in nil })
    check(result.status == 0 && complete(dir), "R2: space that cannot be read is not a reason to refuse")
}

do {
    // A stale temporary from an interrupted finalise is not counted against the room, and a refusal keeps the rest.
    let dir = cafFolder()
    fm.createFile(atPath: dir.appendingPathComponent(".tmp-audio.m4a").path, contents: Data(repeating: 1, count: 4096))
    fm.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data("mine".utf8))
    let cafs = ["mic.caf", "call.caf"].map { name in (name, try? Data(contentsOf: dir.appendingPathComponent(name))) }
    let result = recoverStatus(directory: dir, freeBytes: { _ in 1 })
    check(result.status == 1 && result.message == tooFull + dir.path, "R2: a folder with a stale temporary is refused the same way")
    check(names(dir) == ["call.caf", "mic.caf", "notes.txt"], "R2: its stale temporary is cleared as before; the .caf files and anything else are kept (\(names(dir)))")
    check(cafs.allSatisfy { (try? Data(contentsOf: dir.appendingPathComponent($0.0))) == $0.1 }, "R2: and the .caf files are byte for byte what they were")
}

do {
    // Only a recovery that has to encode needs room: a finished folder asks for nothing.
    let dir = cafFolder()
    try recover(directory: dir)
    let before = snapshot(dir)
    let result = recoverStatus(directory: dir, freeBytes: { _ in 0 })
    check(result.status == 0 && snapshot(dir) == before, "R2: a folder that is already complete is not refused, whatever is free")

    // Three verified .m4a beside the working files (a crash before the marker) need no encoding, so no room.
    let crashed = cafFolder()
    for name in finals { try fm.copyItem(at: dir.appendingPathComponent(name), to: crashed.appendingPathComponent(name)) }
    let finished = recoverStatus(directory: crashed, freeBytes: { _ in 0 })
    check(finished.status == 0 && complete(crashed), "R2: verified .m4a beside the working files are finished with no room at all")
} catch {
    check(false, "R2: complete folder: \(error)")
}

do {
    // The lock comes first: a recorder still holding the folder is busy (75), not a full disk.
    let dir = cafFolder()
    let holder = holdLock(dir, for: 2)
    let before = snapshot(dir)
    let result = recoverStatus(directory: dir, lockWait: 0, freeBytes: { _ in 1 })
    check(result.status == 75 && result.message.contains("is still being recorded or saved") && snapshot(dir) == before,
          "R2: a folder still locked is busy (75), not refused for room")
    holder.terminate()
    holder.waitUntilExit()
}

do {
    // Nothing to recover from is that error, whatever is free.
    let dir = newFolder()
    let result = recoverStatus(directory: dir, freeBytes: { _ in 1 })
    check(result.status == 1 && result.message.contains("no working files to recover from") && !result.message.contains("too full"),
          "R2: a folder with no working files fails for that, not for room")
}

// MARK: - System audio that cannot start: why, in words (Task 10, item 7)
// The app shows the recorder's last line. No display (the screen asleep or locked) is not a
// missing permission, so it must not send anyone to Privacy & Security.

do {
    let asleep = CaptureError.systemAudioFailure(CaptureError.noDisplay)
    let lines = asleep.components(separatedBy: "\n")
    check(lines.first == "Failed to start system audio: No display found for audio capture"
          && lines.last == "The screen is asleep or locked, so the call side cannot be recorded. Wake the screen and try again."
          && !asleep.contains("Grant Screen Recording"),
          "T10: no display says the screen is asleep or locked, last, and not to grant a permission")
    let denied = CaptureError.systemAudioFailure(NSError(domain: "SCStreamErrorDomain", code: -3801,
                                                          userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs"]))
    check(denied == "Failed to start system audio: The user declined TCCs\nGrant Screen Recording permission in System Settings → Privacy & Security.",
          "T10: any other failure still points at Screen Recording, as before")
}

try? fm.removeItem(at: scratch)
if failures > 0 { print("\(failures) failed") }
exit(failures == 0 ? 0 : 1)
