import Foundation
import AVFoundation
import CoreMedia

enum AudioSource: Int {
    case system = 0
    case mic = 1
}

/// Places each source on its own host-time timeline, both sharing one origin, and emits
/// contiguous 48kHz mono chunks of the two side by side (always the same length).
final class AudioMixer: @unchecked Sendable {
    static let sampleRate = 48000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private let now: () -> CMTime
    private let startTime: CMTime
    // How long to wait for a lagging (or silent) source before emitting without it.
    private let maxLag = Int64(0.5 * sampleRate)
    // Buffers are placed back-to-back unless their timestamp drifts further than this, which avoids clicks from jitter.
    private let resyncThreshold = Int64(0.03 * sampleRate)
    private var timelines: [[Float]] = [[], []]
    private var baseFrame: Int64 = 0
    private var cursors: [Int64?] = [nil, nil]
    private var clockOffsets: [Int64?] = [nil, nil]
    // Frames of paused time taken out of the timeline, so audio after a resume joins the audio before it.
    private var shift: Int64 = 0
    private var paused = false
    private let emit: (_ mic: [Float], _ system: [Float]) -> Void

    /// The mix of the two sides, as audio.m4a holds it: their sum, clipped to -1...1.
    /// A shorter side counts as silence where it has run out.
    static func mix(_ mic: [Float], _ system: [Float]) -> [Float] {
        (0..<max(mic.count, system.count)).map { i in
            let sum = (i < mic.count ? mic[i] : 0) + (i < system.count ? system[i] : 0)
            return min(max(sum, -1), 1)
        }
    }

    init(now: @escaping () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) },
         emit: @escaping (_ mic: [Float], _ system: [Float]) -> Void) {
        self.now = now
        self.startTime = now()
        self.emit = emit
    }

    func append(_ samples: [Float], from source: AudioSource, at hostTime: CMTime) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !paused else { return }

        let i = source.rawValue
        let raw = frame(at: hostTime)
        if clockOffsets[i] == nil {
            // Fall back to arrival time if a source's timestamps aren't on the host clock.
            let arrival = frame(at: now())
            clockOffsets[i] = abs(raw - arrival) > Int64(2 * Self.sampleRate) ? arrival - raw : 0
        }
        let placed = raw + clockOffsets[i]!
        var start = placed
        if let cursor = cursors[i], abs(placed - cursor) < resyncThreshold {
            start = cursor
        }
        cursors[i] = start + Int64(samples.count)

        let skip = Int(max(0, baseFrame - start))
        guard skip < samples.count else { return }
        let index = Int(max(start, baseFrame) - baseFrame)
        let count = samples.count - skip
        if timelines[i].count < index + count {
            timelines[i].append(contentsOf: repeatElement(0, count: index + count - timelines[i].count))
        }
        for j in 0..<count {
            timelines[i][index + j] += samples[skip + j]
        }
        drain(final: false)
    }

    func finish() {
        lock.lock()
        drain(final: true)
        lock.unlock()
    }

    /// Emits everything buffered, then drops what arrives until `resume()`.
    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard !paused else { return }
        drain(final: true)
        paused = true
    }

    /// The next samples from each source land straight after the last emitted frame.
    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard paused else { return }
        let end = baseFrame + Int64(timelines.map(\.count).max()!)
        shift += frame(at: now()) - end
        cursors = [nil, nil]
        paused = false
    }

    private func frame(at time: CMTime) -> Int64 {
        Int64((time - startTime).seconds * Self.sampleRate) - shift
    }

    private func drain(final: Bool) {
        let end = baseFrame + Int64(timelines.map(\.count).max()!)
        var ready = end
        if !final {
            ready = cursors.map { $0 ?? baseFrame }.min()!
            ready = min(max(ready, end - maxLag), end)
        }
        let n = Int(ready - baseFrame)
        guard n > 0 else { return }
        // A source that is behind (or silent) is padded with silence so both stay aligned.
        var chunks: [[Float]] = [[], []]
        for i in timelines.indices {
            if timelines[i].count < n {
                timelines[i].append(contentsOf: repeatElement(0, count: n - timelines[i].count))
            }
            chunks[i] = timelines[i][0..<n].map { min(max($0, -1), 1) }
            timelines[i].removeFirst(n)
        }
        baseFrame = ready
        emit(chunks[AudioSource.mic.rawValue], chunks[AudioSource.system.rawValue])
    }
}

/// Converts a source's sample buffers to the mixer format. Not thread-safe; use one per source queue.
/// A buffer it cannot read gives nil, never a crash.
final class SampleExtractor {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = sampleBuffer.formatDescription,
              let format = Self.format(of: description),
              let count = Int32(exactly: sampleBuffer.numSamples), count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: count, into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }

        // AVAudioConverter's downmix turns a discrete layout into silence, so more than two channels
        // (a microphone in voice processing can give three or more) are averaged here first.
        guard let input = format.channelCount > 2 ? Self.average(buffer) : buffer else { return nil }

        if input.format == AudioMixer.format {
            guard let data = input.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(input.frameLength)))
        }

        if sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: AudioMixer.format)
            converter?.downmix = true
            sourceFormat = input.format
        }
        guard let converter else { return nil }

        let capacity = Double(input.frameLength) * AudioMixer.sampleRate / input.format.sampleRate
        guard capacity < Double(Int32.max),
              let output = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(capacity) + 64)
        else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard error == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// The buffer's format, built only through initialisers that can fail. In Swift,
    /// AVAudioFormat(cmAudioFormatDescription:) cannot, yet it gives nil for more than two channels with
    /// no layout, which crashed the recorder when a call put the microphone into voice processing.
    private static func format(of description: CMAudioFormatDescription) -> AVAudioFormat? {
        guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              fitsPCMBuffer(stream.pointee), stream.pointee.mSampleRate > 0 else { return nil }
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) {
            return AVAudioFormat(streamDescription: stream, channelLayout: AVAudioChannelLayout(layout: layout))
        }
        let channels = stream.pointee.mChannelsPerFrame
        if channels > 2 {
            guard let discrete = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
            else { return nil }
            return AVAudioFormat(streamDescription: stream, channelLayout: discrete)
        }
        return AVAudioFormat(streamDescription: stream)
    }

    /// Whether AVAudioPCMBuffer takes the description as PCM. For one it does not, it raises an
    /// Objective-C exception, which Swift cannot catch: anything but linear PCM, no channels, or sizes
    /// that do not add up. Tried on 12,096 combinations of flags, sample sizes, frame sizes and channel
    /// counts and on 900,000 random descriptions, it raised for none that pass these checks.
    private static func fitsPCMBuffer(_ a: AudioStreamBasicDescription) -> Bool {
        let floatAndInteger = kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger
        let interleaved = a.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard a.mFormatID == kAudioFormatLinearPCM, a.mFormatFlags & floatAndInteger != floatAndInteger,
              a.mChannelsPerFrame > 0, a.mFramesPerPacket == 1, a.mBytesPerPacket == a.mBytesPerFrame,
              !interleaved || a.mBytesPerFrame % a.mChannelsPerFrame == 0 else { return false }
        let sampleBytes = interleaved ? a.mBytesPerFrame / a.mChannelsPerFrame : a.mBytesPerFrame
        return UInt64(a.mBitsPerChannel) <= 8 * UInt64(sampleBytes)
    }

    /// The mean of the buffer's channels, as one Float32 channel at the buffer's own rate.
    /// Nil for a sample type other than Float32 or Int16.
    private static func average(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        let sample: (_ channel: Int, _ frame: Int) -> Float
        if let data = buffer.floatChannelData {
            sample = { data[$0][$1 * stride] }
        } else if let data = buffer.int16ChannelData {
            sample = { Float(data[$0][$1 * stride]) / 32768 }
        } else {
            return nil
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let out = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        for frame in 0..<Int(buffer.frameLength) {
            out[frame] = (0..<channels).reduce(0) { $0 + sample($1, frame) } / Float(channels)
        }
        return mono
    }
}
