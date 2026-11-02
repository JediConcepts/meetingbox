// sources: ../../recorder/RecordingOutput.swift ../../recorder/AudioMixer.swift ../../recorder/Finalise.swift ../../recorder/Health.swift ../../recorder/DiskFloor.swift
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
    check(recoverStatus(directory: dir).status == 1, "\(label): --recover exits 1")
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
    let quick = recoverStatus(directory: dir, lockWait: 0)
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

try? fm.removeItem(at: scratch)
if failures > 0 { print("\(failures) failed") }
exit(failures == 0 ? 0 : 1)
