// sources: ../../recorder/AudioMixer.swift
// The mixer keeps the mic and the call on two aligned timelines.
// Time is driven by a fake clock, so these run instantly and never touch audio hardware.
import Foundation
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

exit(failures == 0 ? 0 : 1)
