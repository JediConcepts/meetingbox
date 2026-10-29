import Foundation
import AVFoundation

func eprint(_ message: String) {
    fputs(message + "\n", stderr)
}

/// Writes the mix (audio.m4a), the mic (mic.m4a) and the call (call.m4a) side by side.
/// Encoding happens off the capture threads, on one serial queue.
final class RecordingOutput: @unchecked Sendable {
    static let names = ["audio.m4a", "mic.m4a", "call.m4a"]

    private let queue = DispatchQueue(label: "audio-capture.writer")
    private var mix: AVAudioFile?
    private var mic: AVAudioFile?
    private var call: AVAudioFile?
    private var reportedFileError = false
    private let lock = NSLock()
    private var framesWritten: Int64 = 0

    /// The files this output created, so a failed start can remove exactly those.
    private(set) var created: [URL] = []

    init(directory: URL) throws {
        let urls = Self.names.map { directory.appendingPathComponent($0) }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            throw NSError(domain: "AudioCapture", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(url.path) already exists"])
        }
        var files: [AVAudioFile] = []
        do {
            for url in urls {
                files.append(try Self.open(url))
                created.append(url)
            }
        } catch {
            files.removeAll()
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        (mix, mic, call) = (files[0], files[1], files[2])
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
    }

    /// Seconds of audio handed to the encoder so far. Safe to read from any thread.
    var secondsWritten: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / AudioMixer.sampleRate
    }

    func write(mic micSamples: [Float], system systemSamples: [Float]) {
        let mixed = zip(micSamples, systemSamples).map { min(max($0 + $1, -1), 1) }
        queue.async { [self] in
            write(micSamples, to: mic)
            write(systemSamples, to: call)
            write(mixed, to: mix)
            lock.lock()
            framesWritten += Int64(mixed.count)
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

    func close() {
        queue.sync {
            if #available(macOS 15.0, *) {
                mix?.close()
                mic?.close()
                call?.close()
            }
            (mix, mic, call) = (nil, nil, nil)
        }
    }
}
