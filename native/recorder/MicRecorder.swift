import Foundation
import AVFoundation
import CoreMedia

final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "audio-capture.mic")
    private let onBuffer: (CMSampleBuffer, CMTime) -> Void
    private let onError: () -> Void
    private var session: AVCaptureSession?
    private var clock: CMClock?
    private var errorObserver: NSObjectProtocol?

    init(onError: @escaping () -> Void = {}, onBuffer: @escaping (CMSampleBuffer, CMTime) -> Void) {
        self.onError = onError
        self.onBuffer = onBuffer
    }

    func start(device: AVCaptureDevice) throws {
        let captureSession = AVCaptureSession()
        captureSession.addInput(try AVCaptureDeviceInput(device: device))

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        captureSession.addOutput(output)

        clock = captureSession.synchronizationClock
        session = captureSession
        errorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: captureSession, queue: nil
        ) { [onError] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            eprint("Microphone error: \(error?.localizedDescription ?? "unknown")")
            onError()
        }
        captureSession.startRunning()
    }

    func stop() {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        session?.stopRunning()
        session = nil
        audioQueue.sync {}
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = sampleBuffer.presentationTimeStamp
        // Capture-session timestamps are on the session clock; the mixer aligns everything on host time.
        let hostTime = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        onBuffer(sampleBuffer, hostTime)
    }
}
