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
/// Only the app builds this file; no test makes one.
final class MicSampleRecorder: SampleRecorder {
    private var recorder: MicRecorder?
    private var file: AVAudioFile?
    /// Which start is current: `stop` moves it on, so a permission answered after a stop starts nothing.
    private var generation = 0

    func start(folder: URL, microphone: String?, started: @escaping (String?) -> Void) {
        generation += 1
        let mine = generation
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { [weak self] in self?.begin(mine, folder: folder, microphone: microphone, started: started) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted {
                        self?.begin(mine, folder: folder, microphone: microphone, started: started)
                    } else if self?.generation == mine {
                        started(PreferencesPresentation.sampleMicrophoneRefused)
                    }
                }
            }
        default:
            DispatchQueue.main.async { started(PreferencesPresentation.sampleMicrophoneRefused) }
        }
    }

    /// On the main queue. Opens sample.caf and starts capturing, unless this start was stopped meanwhile.
    private func begin(_ mine: Int, folder: URL, microphone: String?, started: @escaping (String?) -> Void) {
        guard mine == generation, recorder == nil else { return }
        guard let device = microphone.flatMap(findDevice(matching:)) ?? AVCaptureDevice.default(for: .audio) else {
            started(PreferencesPresentation.sampleNoMicrophone)
            return
        }
        let url = folder.appendingPathComponent(SampleFolder.audioName)
        do {
            let file = try AVAudioFile(forWriting: url, settings: RecordingOutput.workingSettings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try Finaliser.makePrivate(url)
            // One extractor for the one source; MicRecorder calls back on its own serial queue.
            let extractor = SampleExtractor()
            let recorder = MicRecorder { buffer, _ in
                guard let samples = extractor.samples(from: buffer), !samples.isEmpty,
                      let pcm = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(samples.count))
                else { return }
                pcm.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                try? file.write(from: pcm)
            }
            try recorder.start(device: device)
            self.file = file
            self.recorder = recorder
            started(nil)
        } catch {
            started("The voice sample could not be recorded: \(error.localizedDescription)")
        }
    }

    /// Stops capturing (MicRecorder waits for its last buffer) and closes sample.caf.
    func stop() {
        generation += 1
        recorder?.stop()
        recorder = nil
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }
}
