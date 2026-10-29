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

exit(failures == 0 ? 0 : 1)
