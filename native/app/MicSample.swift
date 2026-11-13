import AVFoundation
import Foundation

/// The real `SampleRecorder`: the microphone alone, inside the app, through the recorder's own
/// microphone code (`MicRecorder`, `SampleExtractor`, unchanged), into `<folder>/sample.caf` written
/// with `RecordingOutput.workingSettings` and made 0600. The meeting recorder is not used, because it
/// always records the Mac's sound too.
///
/// It uses the Microphone permission meetings use, which macOS files under meetingbox: if it was never
/// given, macOS asks once (with the app's NSMicrophoneUsageDescription); if it was refused, `started`
/// says how to allow it. The microphone is the Preferences one when it is connected, else the default.
///
/// The capture session's start and stop block until they are done (AVCaptureSession), so they run on
/// this recorder's own serial queue, never the main queue; so does opening and closing sample.caf.
/// `started` and `stop`'s `done` are posted back to the main queue. Only the app builds this file; no
/// test makes one.
final class MicSampleRecorder: SampleRecorder {
    private let queue = DispatchQueue(label: "meetingbox.voice-sample")
    /// Which start is current, under `lock`: `stop` moves it on, so a start whose turn on the queue (or
    /// whose permission answer) comes after a stop captures nothing.
    private let lock = NSLock()
    private var generation = 0
    /// Only on `queue`.
    private var recorder: MicRecorder?
    private var output: SampleFile?

    func start(folder: URL, microphone: String?, started: @escaping (String?) -> Void) {
        let mine = nextGeneration()
        let tell: (String?) -> Void = { reason in DispatchQueue.main.async { started(reason) } }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            queue.async { self.begin(mine, folder: folder, microphone: microphone, tell: tell) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    self.queue.async { self.begin(mine, folder: folder, microphone: microphone, tell: tell) }
                } else if self.isCurrent(mine) {
                    tell(PreferencesPresentation.sampleMicrophoneRefused)
                }
            }
        default:
            tell(PreferencesPresentation.sampleMicrophoneRefused)
        }
    }

    /// Returns at once. On the queue, after any start before it: capturing stops (MicRecorder waits for
    /// its last buffer) and sample.caf is closed; then `done`, on the main queue.
    func stop(_ done: @escaping () -> Void) {
        _ = nextGeneration()
        queue.async {
            self.recorder?.stop()
            self.recorder = nil
            self.output?.close()
            self.output = nil
            DispatchQueue.main.async(execute: done)
        }
    }

    /// On the queue. Opens sample.caf and starts capturing, unless this start was stopped meanwhile.
    private func begin(_ mine: Int, folder: URL, microphone: String?, tell: @escaping (String?) -> Void) {
        guard isCurrent(mine), recorder == nil else { return }
        guard let device = microphone.flatMap(findDevice(matching:)) ?? AVCaptureDevice.default(for: .audio) else {
            tell(PreferencesPresentation.sampleNoMicrophone)
            return
        }
        let url = folder.appendingPathComponent(SampleFolder.audioName)
        do {
            let file = try AVAudioFile(forWriting: url, settings: RecordingOutput.workingSettings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try Finaliser.makePrivate(url)
            let output = SampleFile(file)
            // One extractor for the one source; MicRecorder calls back on its own serial queue.
            let extractor = SampleExtractor()
            // startRunning never throws: a session that cannot start, or that fails later, posts its
            // runtime error, which MicRecorder passes to onError (on whatever thread posted it). The
            // first one ends the sample, unless it has been stopped since.
            let failure = CaptureFailure()
            let recorder = MicRecorder(onError: { [weak self] in
                guard failure.mark(), self?.isCurrent(mine) == true else { return }
                tell(PreferencesPresentation.sampleMicrophoneFailed)
            }, onBuffer: { buffer, _ in output.write(extractor.samples(from: buffer)) })
            try recorder.start(device: device)
            self.output = output
            self.recorder = recorder
            if !failure.happened { tell(nil) }
        } catch {
            tell("The voice sample could not be recorded: \(error.localizedDescription)")
        }
    }

    private func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mine == generation
    }
}

/// Whether the capture session has reported an error: only the first is told.
private final class CaptureFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    /// True the first time only.
    func mark() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failed { return false }
        failed = true
        return true
    }

    var happened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

/// sample.caf while it is written. MicRecorder's queue writes to it; the sampler's queue closes it, only
/// after MicRecorder.stop has waited for the last buffer, so the two never overlap. Closing lets the
/// AVAudioFile go (the capture closure keeps only this box), which closes the file before macOS 15 too.
private final class SampleFile: @unchecked Sendable {
    private var file: AVAudioFile?

    init(_ file: AVAudioFile) { self.file = file }

    func write(_ samples: [Float]?) {
        guard let file = file, let samples = samples, !samples.isEmpty,
              let pcm = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: pcm)
    }

    func close() {
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }
}
