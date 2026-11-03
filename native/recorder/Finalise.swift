import Foundation
import AVFoundation

/// Rebuilds a recording folder's three .m4a from its working files, mic.caf and
/// call.caf. Used by the recorder's own stop and by `--recover` after a crash.
/// Waits up to 5 s for the folder's lock: a recorder just killed with -9, or that
/// crashed a moment ago, can hold it until the kernel has finished with it.
func recover(directory: URL, lockWait: TimeInterval = 5,
             freeBytes: (URL) -> Int64? = Finaliser.freeSpaceUnknown) throws {
    try Finaliser.finalise(directory: directory, lockWait: lockWait, freeBytes: freeBytes)
}

/// `--recover`'s exit status: 0 when the folder ends complete; 75 (EX_TEMPFAIL) when
/// another process still holds the folder's lock after the wait (a recorder still
/// recording, or another finalise), so the caller knows it is busy rather than lost;
/// `Finaliser.refusedStatus` (1) when the disk is too full to finish it, with nothing
/// encoded and the working files kept, as for a refused stop; 1 when it cannot be
/// finished. The message says what happened. `freeBytes` reads the free space, which
/// a full finalise is checked against: the recorder gives the real one, a test a fake.
func recoverStatus(directory: URL, lockWait: TimeInterval = 5,
                   freeBytes: (URL) -> Int64?) -> (status: Int32, message: String) {
    do {
        try recover(directory: directory, lockWait: lockWait, freeBytes: freeBytes)
        return (0, "Recovered \(directory.path)")
    } catch let error as NoRoomToFinishError {
        return (Finaliser.refusedStatus, error.message)
    } catch {
        let message = "Could not recover \(directory.path): \(error.localizedDescription)"
        return (error is FolderBusyError ? 75 : 1, message)
    }
}

/// A point in finalising that a test can interrupt, to stand in for a crash there.
enum FinaliseStep: Equatable {
    case encoded(String)    // .tmp-<name> written
    case published(String)  // <name> in place
}

/// Finalising, shared by a clean stop and recovery, in this order and safe to repeat:
///   1. the marker exists and the three .m4a verify: done (remove leftover working files);
///   2. the three .m4a verify without the marker: write the marker, remove working files;
///   3. mic.caf and call.caf exist: (recovery first refuses, changing nothing, if the volume has
///      less than `finishNeed` of their length free) encode .tmp-<name> for each, verify, publish each
///      (keeping verified output from an earlier attempt, replacing unverified), write
///      the marker atomically, and only then remove the working files;
///   4. otherwise change nothing and fail.
/// Verified means every file opens with AVURLAsset with a duration over zero, and the
/// three durations agree within one second.
enum Finaliser {
    static let finals = ["audio.m4a", "mic.m4a", "call.m4a"]
    static let working = ["mic.caf", "call.caf"]
    static let marker = ".recording-complete"
    private static let markerTemp = ".tmp-recording-complete"
    static let encodeBitRate = 96_000
    static let encodeSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioMixer.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: encodeBitRate,
    ]

    /// What finalising writes for each second recorded: the three .m4a, mono AAC at 96 kbit/s each,
    /// so 12 000 bytes a second apiece. They are written beside the working files, which go only
    /// once the .m4a verify, so this much free space is needed on top of what the recording holds.
    static let finishBytesPerSecond = Int64(finals.count * encodeBitRate / 8)
    /// Room to spare over the estimate, for container overhead and the encoder's own variation.
    static let finishMargin = 1.25

    /// The free space finalising `seconds` of recording needs (36 000 bytes a second, plus a quarter).
    /// The stop floors of the recorder and of the app both add it to their reserve, so a stop leaves
    /// room to finish.
    static func finishNeed(seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((Double(finishBytesPerSecond) * seconds * finishMargin).rounded(.up))
    }

    /// What a refused finalise exits with: the recorder after a stop with too little room, and
    /// `--recover` with too little room. The same code, so a caller reads both alike.
    static let refusedStatus: Int32 = 1

    /// The line printed when there is too little room to finish `directory`'s recording.
    static func tooFullLine(directory: URL) -> String {
        "the disk is too full to finish the recording; free some space, then run: meetingbox recover \(directory.path)"
    }

    /// The default free-space source: it knows nothing, and space that cannot be read is never a
    /// reason to refuse. A caller that wants the room checked gives a real one.
    static let freeSpaceUnknown: (URL) -> Int64? = { _ in nil }

    /// Takes the folder's lock first, so it never runs beside a recorder still
    /// writing there, or beside another finalise. Waits up to `lockWait` seconds for it.
    /// With a `freeBytes` that reads the folder's volume, a finalise that has to encode first
    /// checks there is room for the three .m4a (see `finaliseLocked`).
    static func finalise(directory: URL, lockWait: TimeInterval = 0,
                         afterStep: (FinaliseStep) throws -> Void = { _ in },
                         encode: Encoder = Finaliser.encode,
                         freeBytes: (URL) -> Int64? = Finaliser.freeSpaceUnknown) throws {
        let lock = try FolderLock(directory, wait: lockWait)
        try withExtendedLifetime(lock) {
            try finaliseLocked(directory: directory, afterStep: afterStep, encode: encode, freeBytes: freeBytes)
        }
    }

    /// Writes one output (`name`: audio.m4a, mic.m4a or call.m4a) from the two working files.
    /// A test can give its own, to fail the way a full disk does.
    typealias Encoder = (_ name: String, _ output: URL, _ mic: URL, _ call: URL) throws -> Void

    /// For a caller that already holds the folder's lock (the recorder at stop). The recorder's
    /// stop does its own room check first (`DiskFloor.refusal`) and gives no `freeBytes`; recovery
    /// gives one and is refused, before anything is encoded, if the volume holds less than
    /// `finishNeed` of the seconds in the working files.
    static func finaliseLocked(directory: URL, afterStep: (FinaliseStep) throws -> Void = { _ in },
                               encode: Encoder = Finaliser.encode,
                               freeBytes: (URL) -> Int64? = Finaliser.freeSpaceUnknown) throws {
        let fm = FileManager.default
        func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: url(name).path) }

        // 1 and 2: the recording is already in place.
        if verify(directory: directory) {
            if !has(marker) { try writeMarker(in: directory) }
            removeWorkingFiles(in: directory)
            return
        }

        // 4: nothing to build it from.
        guard working.allSatisfy(has) else {
            throw RecordingError("\(directory.path) has no working files to recover from and no readable recording")
        }

        // 3: build it from the working files.
        // What an earlier attempt left is cleared first: it is only ever partial, and it would
        // hold the very room this attempt needs.
        func clearTemporaries() { for name in finals { try? fm.removeItem(at: url(temp(name))) } }
        clearTemporaries()
        if let seconds = workingSeconds(in: directory), let free = freeBytes(directory), free < finishNeed(seconds: seconds) {
            throw NoRoomToFinishError(message: tooFullLine(directory: directory))
        }
        for name in finals {
            do {
                try encode(name, url(temp(name)), url("mic.caf"), url("call.caf"))
            } catch {
                // An encode that fails, a full disk most likely, must not leave what it wrote: that
                // is what keeps the disk full. The working files are never touched here.
                clearTemporaries()
                throw error
            }
            try makePrivate(url(temp(name)))
            try afterStep(.encoded(name))
        }
        guard let encoded = durations(finals.map { url(temp($0)) }) else {
            // Encoded, but not audio that verifies: the three files are as large, and as useless, as
            // a failed encode's leftovers. Only this run's temporaries go; the working files stay.
            clearTemporaries()
            throw RecordingError("the files encoded from the working files in \(directory.path) did not verify")
        }
        for (name, newDuration) in zip(finals, encoded) {
            if let existing = duration(of: url(name)) {
                // Verified output from an earlier attempt is never overwritten.
                guard abs(existing - newDuration) <= 1 else {
                    throw RecordingError("\(url(name).path) already exists and does not match the working files")
                }
                try fm.removeItem(at: url(temp(name)))
            } else if has(name) {
                // Unreadable output from an earlier attempt: replace it in one step.
                guard rename(url(temp(name)).path, url(name).path) == 0 else { throw posixError("replace \(name)") }
            } else {
                guard renamex_np(url(temp(name)).path, url(name).path, UInt32(RENAME_EXCL)) == 0 else {
                    throw posixError("publish \(name)")
                }
            }
            try afterStep(.published(name))
        }
        guard verify(directory: directory) else {
            throw RecordingError("the recording in \(directory.path) did not verify after publishing")
        }
        try writeMarker(in: directory)
        removeWorkingFiles(in: directory)
    }

    /// The seconds of audio the working files hold: the frames of the longer one over 48 000, as
    /// every output is as long as the longer side. Nil unless both open; the encode then fails
    /// with its own reason, and there is nothing to estimate.
    static func workingSeconds(in directory: URL) -> Double? {
        var frames: AVAudioFramePosition = 0
        for name in working {
            guard let file = try? AVAudioFile(forReading: directory.appendingPathComponent(name)) else { return nil }
            frames = max(frames, file.length)
        }
        return Double(frames) / AudioMixer.sampleRate
    }

    static func verify(directory: URL) -> Bool {
        durations(finals.map { directory.appendingPathComponent($0) }) != nil
    }

    /// Each file's duration, or nil unless all of them open, are over zero, and agree within one second.
    static func durations(_ urls: [URL]) -> [Double]? {
        let found = urls.compactMap(duration(of:))
        guard found.count == urls.count, let low = found.min(), let high = found.max(), high - low <= 1 else { return nil }
        return found
    }

    /// The duration AVURLAsset reads, or nil if the file is missing, unreadable or empty.
    static func duration(of url: URL) -> Double? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let result = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.value = try? await AVURLAsset(url: url).load(.duration).seconds
            done.signal()
        }
        done.wait()
        guard let seconds = result.value, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func makePrivate(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func temp(_ name: String) -> String { ".tmp-" + name }

    /// One pass over the working files: the mix for audio.m4a (by the mixer's rule),
    /// or one side. Every output is as long as the longer side, padded with silence.
    static func encode(_ name: String, _ output: URL, _ mic: URL, _ call: URL) throws {
        let micFile = try AVAudioFile(forReading: mic, commonFormat: .pcmFormatFloat32, interleaved: false)
        let callFile = try AVAudioFile(forReading: call, commonFormat: .pcmFormatFloat32, interleaved: false)
        for file in [micFile, callFile] where file.processingFormat != AudioMixer.format {
            throw RecordingError("\(file.url.lastPathComponent) is not 48 kHz mono")
        }
        let total = max(micFile.length, callFile.length)
        var writer: AVAudioFile? = try AVAudioFile(forWriting: output, settings: encodeSettings,
                                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var done: Int64 = 0
        while done < total {
            let n = Int(min(Int64(AudioMixer.sampleRate), total - done))
            var samples: [Float]
            switch name {
            case "mic.m4a": samples = try read(micFile, n)
            case "call.m4a": samples = try read(callFile, n)
            default: samples = AudioMixer.mix(try read(micFile, n), try read(callFile, n))
            }
            if samples.count < n { samples += repeatElement(0, count: n - samples.count) }
            let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: n)
            }
            try writer!.write(from: buffer)
            done += Int64(n)
        }
        if #available(macOS 15.0, *) { writer?.close() }
        writer = nil
    }

    /// Up to `count` frames from where the file was left, fewer at its end.
    private static func read(_ file: AVAudioFile, _ count: Int) throws -> [Float] {
        let left = Int(max(0, file.length - file.framePosition))
        let n = min(count, left)
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { return [] }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Written whole under a temporary name, then renamed into place.
    private static func writeMarker(in directory: URL) throws {
        let tempURL = directory.appendingPathComponent(markerTemp)
        try? FileManager.default.removeItem(at: tempURL)
        let lines = finals.map { name in
            "\(name) \(String(format: "%.3f", duration(of: directory.appendingPathComponent(name)) ?? 0))"
        }
        guard FileManager.default.createFile(atPath: tempURL.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw RecordingError("could not write \(tempURL.path)")
        }
        try makePrivate(tempURL)
        guard rename(tempURL.path, directory.appendingPathComponent(marker).path) == 0 else { throw posixError("write the marker") }
    }

    /// Only the working files this recorder makes, and only once the marker exists.
    private static func removeWorkingFiles(in directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) else { return }
        for name in working + finals.map(temp) + [markerTemp] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func posixError(_ what: String) -> RecordingError {
        RecordingError("could not \(what): \(String(cString: strerror(errno)))")
    }

    private final class Box: @unchecked Sendable {
        var value: Double?
    }
}

/// An exclusive lock on a folder, held for as long as this object lives. A process
/// that dies releases it, so a crash never leaves a folder locked. By default it
/// fails at once if the lock is taken; with `wait`, it tries again for that long.
final class FolderLock {
    private let fd: Int32

    init(_ directory: URL, wait: TimeInterval = 0) throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw RecordingError("could not open \(directory.path)") }
        let deadline = Date().addingTimeInterval(wait)
        var locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        while !locked && Date() < deadline {
            usleep(50_000)
            locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        guard locked else {
            Darwin.close(fd)
            throw FolderBusyError(message: "\(directory.path) is still being recorded or saved")
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }
}

/// A recovery that finds less free space than the three .m4a need. Nothing was encoded and the
/// working files are kept; `message` is the line to print (`Finaliser.tooFullLine`).
struct NoRoomToFinishError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Another process holds a folder's lock: busy for now, not broken.
struct FolderBusyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
