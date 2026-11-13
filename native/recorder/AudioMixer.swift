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

    func samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = sampleBuffer.formatDescription,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let count = Int32(exactly: sampleBuffer.numSamples), count > 0,
              Self.fitsPCMBuffer(stream.pointee, frames: count),
              let format = Self.format(of: description, stream),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: count, into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }

        // AVAudioConverter's downmix silences discrete, Unknown and Unused channels, so anything but
        // mono and left and right stereo is averaged here first. A microphone in voice processing can
        // give three or more channels.
        let averaged = !Self.keepsConverter(channels: format.channelCount, layout: format.channelLayout)
        guard let input = averaged ? Self.average(buffer) : buffer else { return nil }

        if input.format == AudioMixer.format {
            guard let data = input.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(input.frameLength)))
        }

        // The converter is kept while the stream description stays the same. AVAudioFormat's equality
        // also compares layouts, and an Unknown layout never equals its twin, which rebuilt the
        // converter on every buffer. A kept converter takes only its own format object, so a buffer of
        // the same stream under another is passed in its format, over the same memory.
        let inputStream = input.format.streamDescription.pointee
        if converter.map({ !Self.same($0.inputFormat.streamDescription.pointee, inputStream) }) ?? true {
            converter = AVAudioConverter(from: input.format, to: AudioMixer.format)
            converter?.downmix = true
        }
        guard let converter,
              let source = input.format == converter.inputFormat ? input : AVAudioPCMBuffer(
                  pcmFormat: converter.inputFormat, bufferListNoCopy: input.audioBufferList, deallocator: nil)
        else { return nil }

        let capacity = Double(source.frameLength) * AudioMixer.sampleRate / source.format.sampleRate
        guard capacity < Double(Int32.max),
              let output = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(capacity) + 64)
        else { return nil }
        var fed = false
        var error: NSError?
        // A relabelled buffer borrows the input's memory, so the input lives until the conversion ends.
        withExtendedLifetime(input) {
            _ = converter.convert(to: output, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return source
            }
        }
        guard error == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    private static let leftAndRight = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)

    /// Mono, and stereo with no layout or a left and right one (as a tag, as labels or as a bitmap:
    /// AVAudioChannelLayout's equality takes them as one), keep AVAudioConverter's downmix exactly as
    /// before. Every other layout is averaged.
    private static func keepsConverter(channels: AVAudioChannelCount, layout: AVAudioChannelLayout?) -> Bool {
        channels == 1 || (channels == 2 && (layout == nil || layout == leftAndRight))
    }

    /// The buffer's format, built only through initialisers that can fail. In Swift,
    /// AVAudioFormat(cmAudioFormatDescription:) cannot, yet it gives nil for more than two channels with
    /// no layout, which crashed the recorder when a call put the microphone into voice processing.
    private static func format(of description: CMAudioFormatDescription,
                               _ stream: UnsafePointer<AudioStreamBasicDescription>) -> AVAudioFormat? {
        guard stream.pointee.mSampleRate > 0 else { return nil }
        let channels = stream.pointee.mChannelsPerFrame
        var layoutSize = 0
        let given = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
            .map { AVAudioChannelLayout(layout: $0) }
        if keepsConverter(channels: channels, layout: given) {
            if let given { return AVAudioFormat(streamDescription: stream, channelLayout: given) }
            return AVAudioFormat(streamDescription: stream)
        }
        // Averaged, where the layout plays no part, so one AVAudioFormat refuses gives way to a discrete one.
        if let given, let format = AVAudioFormat(streamDescription: stream, channelLayout: given) { return format }
        guard let discrete = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        else { return nil }
        return AVAudioFormat(streamDescription: stream, channelLayout: discrete)
    }

    /// Whether AVAudioPCMBuffer can hold `frames` of the description. It raises an Objective-C
    /// exception, which Swift cannot catch, for a description it does not take as PCM: anything but
    /// linear PCM, no channels, or sizes that do not add up. Tried on 12,096 combinations of flags,
    /// sample sizes, frame sizes and channel counts and on 900,000 random descriptions, it raised for
    /// none that pass these checks. Its size arithmetic also overflows and aborts once the buffers
    /// reach 2^32 bytes in all, so anything from 2^31 bytes is refused: over 90 minutes of stereo.
    private static func fitsPCMBuffer(_ a: AudioStreamBasicDescription, frames: Int32) -> Bool {
        let floatAndInteger = kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger
        let interleaved = a.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard a.mFormatID == kAudioFormatLinearPCM, a.mFormatFlags & floatAndInteger != floatAndInteger,
              a.mChannelsPerFrame > 0, a.mFramesPerPacket == 1, a.mBytesPerPacket == a.mBytesPerFrame,
              !interleaved || a.mBytesPerFrame % a.mChannelsPerFrame == 0 else { return false }
        let sampleBytes = interleaved ? a.mBytesPerFrame / a.mChannelsPerFrame : a.mBytesPerFrame
        let buffers = UInt64(interleaved ? 1 : a.mChannelsPerFrame)
        let (bytes, overflow) = (UInt64(frames) * UInt64(a.mBytesPerFrame)).multipliedReportingOverflow(by: buffers)
        return UInt64(a.mBitsPerChannel) <= 8 * UInt64(sampleBytes) && !overflow && bytes < 1 << 31
    }

    /// The mean of the buffer's channels, as one Float32 channel at the buffer's own rate. Nil unless
    /// the samples are native-endian Float32 or Int16: AVAudioPCMBuffer offers the same pointers for
    /// big-endian, unsigned or padded samples, which would be read as noise.
    private static func average(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        let sample: (_ channel: Int, _ frame: Int) -> Float
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            sample = { data[$0][$1 * stride] }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            sample = { Float(data[$0][$1 * stride]) / 32768 }
        default:
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

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
    }
}
