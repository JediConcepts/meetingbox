// sources: ../../recorder/AudioMixer.swift
// The mixer keeps the mic and the call on two aligned timelines, and SampleExtractor turns each
// source's sample buffers into the mixer's format. Time is driven by a fake clock and the sample
// buffers are made here, so these run instantly and never touch audio hardware.
import Foundation
import AVFoundation
import CoreMedia

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - Child mode: one SampleExtractor case in a process of its own

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--extract" {
    // Line by line, so the checks that passed before a crash still reach the parent.
    setvbuf(stdout, nil, _IOLBF, 0)
    extractorCase(CommandLine.arguments[2])
    exit(failures == 0 ? 0 : 1)
}

let rate = 48000
let chunk = 480 // 10 ms
var t = 0.0
func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48000) }

/// A mixer on the fake clock, started at the current fake time, recording everything it emits.
final class Capture {
    var mic: [Float] = []
    var system: [Float] = []
    var unequal = false
    var mixer: AudioMixer!
    init() {
        mixer = AudioMixer(now: { at(t) }) { [unowned self] m, s in
            if m.count != s.count { unequal = true }
            mic += m
            system += s
        }
    }
}

// Both sources, same host time, one second each.
do {
    t = 0
    let c = Capture()
    for k in 0..<(rate / chunk) {
        let when = Double(k * chunk) / Double(rate)
        t = when + 0.01
        c.mixer.append([Float](repeating: 0.1, count: chunk), from: .mic, at: at(when))
        c.mixer.append([Float](repeating: 0.2, count: chunk), from: .system, at: at(when))
    }
    c.mixer.finish()
    check(c.mic.count == rate && c.system.count == rate, "both sources: 48000 frames each")
    check(!c.unequal, "both sources: every emit has equal-length slices")
    check(c.mic.allSatisfy { $0 == Float(0.1) }, "both sources: mic is 0.1 throughout")
    check(c.system.allSatisfy { $0 == Float(0.2) }, "both sources: system is 0.2 throughout")
}

// The call never sends anything: the mic still comes out, with silence beside it.
do {
    t = 0
    let c = Capture()
    for k in 0..<(rate / chunk) {
        let when = Double(k * chunk) / Double(rate)
        t = when + 0.01
        c.mixer.append([Float](repeating: 0.1, count: chunk), from: .mic, at: at(when))
    }
    c.mixer.finish()
    check(c.mic.count == rate && c.system.count == rate, "silent system: 48000 frames each")
    check(c.system.allSatisfy { $0 == 0 }, "silent system: system is all zero")
    check(c.mic.allSatisfy { $0 == Float(0.1) }, "silent system: mic is 0.1 throughout")
}

// The mic's buffers arrive 0.25 s late but carry the same timestamps: still aligned.
do {
    t = 0
    let c = Capture()
    let chunks = rate / chunk
    let late = 25 // 0.25 s in 10 ms chunks
    func block(_ k: Int, _ value: Float) -> [Float] {
        // first half second silent, then sound
        [Float](repeating: k < chunks / 2 ? 0 : value, count: chunk)
    }
    for k in 0..<(chunks + late) {
        t = Double(k * chunk) / Double(rate) + 0.01
        if k < chunks {
            c.mixer.append(block(k, 0.2), from: .system, at: at(Double(k * chunk) / Double(rate)))
        }
        let m = k - late
        if m >= 0 {
            c.mixer.append(block(m, 0.1), from: .mic, at: at(Double(m * chunk) / Double(rate)))
        }
    }
    c.mixer.finish()
    let firstMic = c.mic.firstIndex { $0 != 0 }
    let firstSystem = c.system.firstIndex { $0 != 0 }
    check(firstMic != nil && firstMic == firstSystem, "late mic: first sound at the same frame (\(String(describing: firstMic)) vs \(String(describing: firstSystem)))")
    check(c.mic.count == c.system.count && !c.unequal, "late mic: equal lengths")
}

// Pause drops what arrives while paused, and resume lands the next audio straight after the last
// emitted frame, so the join has no gap. Pausing or resuming twice changes nothing.
for twice in [false, true] {
    t = 0
    let c = Capture()
    func second(from start: Double, _ value: Float) {
        for k in 0..<(rate / chunk) {
            let when = start + Double(k * chunk) / Double(rate)
            t = when + 0.01
            c.mixer.append([Float](repeating: value, count: chunk), from: .mic, at: at(when))
            c.mixer.append([Float](repeating: value, count: chunk), from: .system, at: at(when))
        }
    }
    let label = twice ? "pause and resume twice" : "pause and resume"
    second(from: 0, 0.1)
    t = 1
    c.mixer.pause()
    if twice { c.mixer.pause() }
    c.mixer.append([Float](repeating: 0.9, count: chunk), from: .mic, at: at(1.5))
    c.mixer.append([Float](repeating: 0.9, count: chunk), from: .system, at: at(1.5))
    t = 3
    c.mixer.resume()
    if twice { c.mixer.resume() }
    second(from: 3, 0.2)
    c.mixer.finish()
    check(c.mic.count == 2 * rate && c.system.count == 2 * rate, "\(label): 96000 frames per channel")
    check(!c.unequal, "\(label): every emit has equal-length slices")
    check(c.mic[rate - 1] != 0 && c.mic[rate] != 0 && c.system[rate] != 0, "\(label): no zero gap at the join")
    check(c.mic.allSatisfy { $0 == Float(0.1) || $0 == Float(0.2) }, "\(label): nothing from the paused stretch")
}

// Two pauses: each resume adds to the time skipped, so the second join has no gap either.
do {
    t = 0
    let c = Capture()
    func second(from start: Double, _ value: Float) {
        for k in 0..<(rate / chunk) {
            let when = start + Double(k * chunk) / Double(rate)
            t = when + 0.01
            c.mixer.append([Float](repeating: value, count: chunk), from: .mic, at: at(when))
            c.mixer.append([Float](repeating: value, count: chunk), from: .system, at: at(when))
        }
    }
    second(from: 0, 0.1)
    t = 1; c.mixer.pause(); t = 3; c.mixer.resume()
    second(from: 3, 0.2)
    t = 4; c.mixer.pause(); t = 7; c.mixer.resume()
    second(from: 7, 0.3)
    c.mixer.finish()
    check(c.mic.count == 3 * rate && c.system.count == 3 * rate, "two pauses: 144000 frames per channel (\(c.mic.count))")
    check(c.mic[2 * rate - 1] == Float(0.2) && c.mic[2 * rate] == Float(0.3), "two pauses: no gap at the second join")
}

// MARK: - SampleExtractor (task R1)
// A WhatsApp call put the MacBook microphone into Apple's voice processing, which delivered a format
// with three channels and no channel layout, and the recorder crashed inside the extractor (SIGSEGV).
// Each case runs in a child process, so a case that crashes the extractor shows as a FAIL here
// instead of ending the suite.

/// A sample buffer as a capture callback gets one: a format description, with a channel layout only
/// when `layout` names one (the voice-processing microphone gave none), over a block holding `bytes`,
/// or over no data at all when `bytes` is nil. `packets` describes compressed data.
func sampleBuffer(_ asbd: AudioStreamBasicDescription, frames: Int, bytes: [UInt8]?,
                  layout: AudioChannelLayoutTag? = nil,
                  packets: [AudioStreamPacketDescription]? = nil) -> CMSampleBuffer? {
    var asbd = asbd
    var channelLayout = AudioChannelLayout()
    channelLayout.mChannelLayoutTag = layout ?? 0
    var description: CMAudioFormatDescription?
    let made = withUnsafePointer(to: &channelLayout) { pointer in
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: layout == nil ? 0 : MemoryLayout<AudioChannelLayout>.size,
            layout: layout == nil ? nil : pointer,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    }
    guard made == noErr, let description else { return nil }
    var buffer: CMSampleBuffer?
    guard let bytes, !bytes.isEmpty else {
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: frames, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &buffer)
        return status == noErr ? buffer : nil
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
              allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
              customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
              flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
          let block,
          bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(
              with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }) == noErr,
          CMAudioSampleBufferCreateReadyWithPacketDescriptions(
              allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: frames,
              presentationTimeStamp: .zero, packetDescriptions: packets, sampleBufferOut: &buffer) == noErr
    else { return nil }
    return buffer
}

/// Linear PCM, Float32 or Int16, interleaved or not.
func pcmDescription(channels: Int, rate: Double, int16: Bool, interleaved: Bool) -> AudioStreamBasicDescription {
    let sampleBytes: UInt32 = int16 ? 2 : 4
    let frameBytes = interleaved ? sampleBytes * UInt32(channels) : sampleBytes
    return AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: (int16 ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked
            | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
        mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: sampleBytes * 8, mReserved: 0)
}

/// A PCM sample buffer holding these channels' samples.
func pcmBuffer(_ channels: [[Float]], rate: Double, int16: Bool = false, interleaved: Bool = false,
               layout: AudioChannelLayoutTag? = nil) -> CMSampleBuffer? {
    let frames = channels[0].count
    let ordered = interleaved ? (0..<frames).flatMap { f in channels.map { $0[f] } } : channels.flatMap { $0 }
    let bytes = ordered.flatMap { v -> [UInt8] in
        int16 ? withUnsafeBytes(of: Int16((v * 32767).rounded()).littleEndian, Array.init)
              : withUnsafeBytes(of: v.bitPattern.littleEndian, Array.init)
    }
    let description = pcmDescription(channels: channels.count, rate: rate, int16: int16, interleaved: interleaved)
    return sampleBuffer(description, frames: frames, bytes: bytes, layout: layout)
}

/// 0.1 s of a 440 Hz tone at 0.3, at the given rate.
func tone(_ rate: Double) -> [Float] {
    (0..<Int(rate / 10)).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
}

func rms(_ x: ArraySlice<Float>) -> Double {
    x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count))
}

/// The output after the resampler has settled.
func settled(_ x: [Float]) -> ArraySlice<Float> { x.dropFirst(min(256, x.count / 4)) }

func decibels(_ level: Double, _ reference: Double) -> Double { 20 * log10(level / reference) }

func show(_ x: Double) -> String { String(format: "%.4f", x) }

/// One extractor per run, as each source has its own, so no run hears another's leftovers.
func extract(_ buffer: CMSampleBuffer?, _ name: String) -> [Float]? {
    guard let buffer else {
        check(false, "\(name): the test could not make its sample buffer")
        return nil
    }
    return SampleExtractor().samples(from: buffer)
}

/// A multichannel buffer three ways: the same tone on every channel, then on the first channel
/// only, then on the last only. Each comes out as mono at 48 kHz carrying the tone.
func multichannel(_ name: String, channels n: Int, rate: Double, int16: Bool, interleaved: Bool,
                  layout: AudioChannelLayoutTag? = nil) {
    let signal = tone(rate)
    let silence = [Float](repeating: 0, count: signal.count)
    let one = rms(signal[...])
    let expected = Int(Double(signal.count) * AudioMixer.sampleRate / rate)
    func run(_ channels: [[Float]]) -> [Float] {
        extract(pcmBuffer(channels, rate: rate, int16: int16, interleaved: interleaved, layout: layout), name) ?? []
    }
    let all = run(Array(repeating: signal, count: n))
    let level = rms(settled(all))
    check(all.count > expected / 2 && all.count <= expected + 64 && abs(decibels(level, one)) <= 1,
          "\(name): the same tone on every channel comes out at 48 kHz within 1 dB of one channel (\(all.count) frames, rms \(show(level)) against \(show(one)))")
    for (which, index) in [("first", 0), ("last", n - 1)] {
        var channels = Array(repeating: silence, count: n)
        channels[index] = signal
        let level = rms(settled(run(channels)))
        check(level > one / 20, "\(name): a tone on the \(which) channel only is not silent (rms \(show(level)))")
    }
}

/// A buffer the extractor cannot read gives nil, and nothing crashes.
func unreadable(_ name: String, _ buffer: CMSampleBuffer?) {
    guard let buffer else {
        check(false, "\(name): the test could not make its sample buffer")
        return
    }
    check(SampleExtractor().samples(from: buffer) == nil, "\(name): gives nil")
}

func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }

func extractorCase(_ name: String) {
    switch name {
    case "3 channels, Float32, planar, 48 kHz, no layout":
        multichannel(name, channels: 3, rate: 48000, int16: false, interleaved: false)
    case "4 channels, Int16, interleaved, 16 kHz, no layout":
        multichannel(name, channels: 4, rate: 16000, int16: true, interleaved: true)
    case "8 channels, Int16, planar, 44.1 kHz, no layout":
        multichannel(name, channels: 8, rate: 44100, int16: true, interleaved: false)
    case "3 channels, Float32, interleaved, 96 kHz, an explicit discrete layout":
        multichannel(name, channels: 3, rate: 96000, int16: false, interleaved: true,
                     layout: kAudioChannelLayoutTag_DiscreteInOrder | 3)
    case "3 channels, Float32, planar, 48 kHz, an explicit 3.0 layout":
        multichannel(name, channels: 3, rate: 48000, int16: false, interleaved: false,
                     layout: kAudioChannelLayoutTag_MPEG_3_0_A)
    case "mono, Float32, 48 kHz":
        // The path every recording so far has taken: the mixer's own format, returned as it is.
        let signal = tone(48000)
        let out = extract(pcmBuffer([signal], rate: 48000), name)
        check(out == signal, "\(name): comes back unchanged (\(out?.count ?? 0) of \(signal.count) frames)")
    case "stereo, Float32, interleaved, 44.1 kHz":
        // The converter's own downmix, as before: the mean of left and right.
        let signal = tone(44100)
        let silence = [Float](repeating: 0, count: signal.count)
        let one = rms(signal[...])
        let both = extract(pcmBuffer([signal, signal], rate: 44100, interleaved: true), name) ?? []
        let left = extract(pcmBuffer([signal, silence], rate: 44100, interleaved: true), name) ?? []
        let bothLevel = rms(settled(both))
        let leftLevel = rms(settled(left))
        check(both.count > 2400 && both.count <= 4864 && abs(decibels(bothLevel, one)) <= 1,
              "\(name): the same tone on both channels comes out at 48 kHz within 1 dB of one channel (\(both.count) frames, rms \(show(bothLevel)))")
        check(abs(decibels(leftLevel, one / 2)) <= 1,
              "\(name): a tone on the left only comes out at half its level (rms \(show(leftLevel)))")
    case "no channels":
        var asbd = pcmDescription(channels: 1, rate: 48000, int16: false, interleaved: false)
        asbd.mChannelsPerFrame = 0
        unreadable(name, sampleBuffer(asbd, frames: 480, bytes: zeros(480 * 4)))
    case "AAC, not linear PCM":
        // One packet of compressed audio.
        let asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 64)
        unreadable(name, sampleBuffer(asbd, frames: 1, bytes: zeros(64), packets: [packet]))
    case "PCM whose sizes do not add up":
        // 32-bit samples in 2-byte frames.
        var asbd = pcmDescription(channels: 1, rate: 48000, int16: false, interleaved: false)
        asbd.mBytesPerFrame = 2
        asbd.mBytesPerPacket = 2
        unreadable(name, sampleBuffer(asbd, frames: 480, bytes: zeros(480 * 2)))
    case "PCM with no data behind it":
        let asbd = pcmDescription(channels: 1, rate: 48000, int16: false, interleaved: false)
        unreadable(name, sampleBuffer(asbd, frames: 480, bytes: nil))
    default:
        check(false, "no extractor case called \(name)")
    }
}

let extractorCases = [
    "3 channels, Float32, planar, 48 kHz, no layout",
    "4 channels, Int16, interleaved, 16 kHz, no layout",
    "8 channels, Int16, planar, 44.1 kHz, no layout",
    "3 channels, Float32, interleaved, 96 kHz, an explicit discrete layout",
    "3 channels, Float32, planar, 48 kHz, an explicit 3.0 layout",
    "mono, Float32, 48 kHz",
    "stereo, Float32, interleaved, 44.1 kHz",
    "no channels",
    "AAC, not linear PCM",
    "PCM whose sizes do not add up",
    "PCM with no data behind it",
]
for name in extractorCases {
    let child = Process()
    child.executableURL = Bundle.main.executableURL
    child.arguments = ["--extract", name]
    let out = Pipe()
    child.standardOutput = out
    do {
        try child.run()
    } catch {
        check(false, "extractor \(name): the child did not start (\(error))")
        continue
    }
    let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    child.waitUntilExit()
    lines.forEach { print("\($0.prefix(5))extractor \($0.dropFirst(5))") }
    failures += lines.filter { $0.hasPrefix("FAIL ") }.count
    if child.terminationReason == .uncaughtSignal {
        check(false, "extractor \(name): crashed (signal \(child.terminationStatus))")
    } else if child.terminationStatus != 0 && !lines.contains(where: { $0.hasPrefix("FAIL ") }) {
        check(false, "extractor \(name): exited \(child.terminationStatus) without a FAIL")
    }
}

exit(failures == 0 ? 0 : 1)
