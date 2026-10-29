import Foundation
import AVFoundation

func eprint(_ message: String) {
    fputs(message + "\n", stderr)
}

/// Records the mic and the call side by side into working files, mic.caf and
/// call.caf: 16-bit PCM, which keeps every sample written even if the recorder is
/// killed. `finish()` turns them into audio.m4a (the mix), mic.m4a and call.m4a.
/// Writing happens off the capture threads, on one serial queue.
final class RecordingOutput: @unchecked Sendable {
    static let names = Finaliser.finals
    static let workingNames = Finaliser.working
    static let workingSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: AudioMixer.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    private let directory: URL
    private let queue = DispatchQueue(label: "audio-capture.writer")
    private var mic: AVAudioFile?
    private var call: AVAudioFile?
    private var reportedFileError = false
    private let lock = NSLock()
    private var framesWritten: Int64 = 0
    // Held while recording, so recovery cannot finalise a folder still being written.
    private let folderLock: FolderLock

    /// The files this output created, so a failed start can remove exactly those.
    private(set) var created: [URL] = []

    init(directory: URL) throws {
        self.directory = directory
        for name in Self.names + Self.workingNames + [Finaliser.marker] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                throw RecordingError("\(url.path) already exists")
            }
        }
        folderLock = try FolderLock(directory)
        var files: [AVAudioFile] = []
        do {
            for name in Self.workingNames {
                let url = directory.appendingPathComponent(name)
                files.append(try AVAudioFile(forWriting: url, settings: Self.workingSettings,
                                             commonFormat: .pcmFormatFloat32, interleaved: false))
                created.append(url)
                try Finaliser.makePrivate(url)
            }
        } catch {
            files.removeAll()
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        (mic, call) = (files[0], files[1])
    }

    /// Seconds of audio written so far. Safe to read from any thread.
    var secondsWritten: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / AudioMixer.sampleRate
    }

    func write(mic micSamples: [Float], system systemSamples: [Float]) {
        queue.async { [self] in
            write(micSamples, to: mic)
            write(systemSamples, to: call)
            lock.lock()
            framesWritten += Int64(max(micSamples.count, systemSamples.count))
            lock.unlock()
        }
    }

    private func write(_ samples: [Float], to file: AVAudioFile?) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
        } catch where !reportedFileError {
            reportedFileError = true
            eprint("Failed to write audio file: \(error.localizedDescription)")
        } catch {}
    }

    /// Closes the working files. They stay on disk.
    func close() {
        queue.sync {
            if #available(macOS 15.0, *) {
                mic?.close()
                call?.close()
            }
            (mic, call) = (nil, nil)
        }
    }

    /// Closes the working files and finalises the folder: encodes, verifies and
    /// publishes the three .m4a, writes the completion marker, and only then
    /// removes the working files. On failure they are kept for recovery.
    func finish() throws {
        close()
        try Finaliser.finaliseLocked(directory: directory)
    }
}

struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
