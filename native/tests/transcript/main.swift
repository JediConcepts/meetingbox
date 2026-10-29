// sources: ../../transcript/Transcript.swift
// The merge turns two word lists into Me and Them turns. Pure functions, no audio.
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("tests/fixtures")
func fixture(_ name: String) -> [Word] {
    guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)),
          let words = try? loadWords(data) else { return [] }
    return words
}
func w(_ start: Double, _ end: Double, _ text: String) -> Word { Word(start: start, end: end, text: text) }

// loadWords
let mic = fixture("sa-mic.json")
let call = fixture("sa-call.json")
let whisper = fixture("whisper.json")
check(mic.count == 8, "loadWords: speech-analyzer mic fixture has 8 words")
check(call.count == 6, "loadWords: speech-analyzer call fixture has 6 words")
check(mic.first == w(0.0, 0.3, "Hi"), "loadWords: speech-analyzer fields are read")
check(whisper.count == 5, "loadWords: whisper skips blank and bracketed entries")
check(whisper.first == w(0.0, 0.4, "Hello"), "loadWords: whisper text is trimmed")
check(whisper.last == w(3.25, 3.6, "coming"), "loadWords: whisper offsets come out in seconds")
check((try? loadWords(Data())) == [], "loadWords: empty data gives no words")
check((try? loadWords(Data("{}".utf8))) == [], "loadWords: {} gives no words")
check((try? loadWords(Data("not json".utf8))) == nil, "loadWords: garbage throws")

// removeEcho
let kept = removeEcho(mic: mic, call: call)
check(kept.count == 6, "removeEcho: drops exactly the two echoed words")
check(!kept.contains { $0.text == "sounds" || $0.text == "good" }, "removeEcho: the echoed words are the ones dropped")
let yes = removeEcho(mic: [w(5.0, 5.3, "yes")], call: [w(3.0, 3.3, "Yes")])
check(yes.count == 1, "removeEcho: keeps a 'yes' 2 s from a call 'yes'")
let oks = removeEcho(mic: [w(1.0, 1.2, "ok"), w(1.3, 1.5, "OK.")], call: [w(1.1, 1.3, "ok")])
check(oks.count == 1, "removeEcho: one call 'ok' cancels only one of two mic 'ok's")
check(removeEcho(mic: [w(1, 1, ",")], call: [w(1, 1, ",")]).count == 1, "removeEcho: empty normalised text never matches")

// mergeTurns
let alt = mergeTurns([("Me", [w(0, 1, "Hello"), w(1.2, 2, "there")]), ("Them", [w(2.5, 3, "Hi"), w(3, 3.5, "back")])])
check(alt == [Turn(label: "Me", start: 0, text: "Hello there"), Turn(label: "Them", start: 2.5, text: "Hi back")], "mergeTurns: alternates by label")
let gapped = mergeTurns([("Me", [w(0, 1, "One"), w(3, 4, "two")])])
check(gapped.count == 2 && gapped[1].start == 3, "mergeTurns: a 2 s gap splits one speaker's run")
let punct = mergeTurns([("Me", [w(0, 0.3, "Hello"), w(0.3, 0.3, ","), w(0.4, 0.8, "world")])])
check(punct.first?.text == "Hello, world", "mergeTurns: joins Hello , world as 'Hello, world'")
let brackets = mergeTurns([("Me", [w(0, 0.3, "see"), w(0.4, 0.5, "("), w(0.5, 0.8, "this"), w(0.8, 0.9, ")")])])
check(brackets.first?.text == "see (this)", "mergeTurns: no space after an opening bracket or before a closing one")
check(mergeTurns([]).isEmpty, "mergeTurns: no streams, no turns")

// render
let line = render([Turn(label: "Them", start: 3725.9, text: "Hello")])
check(line == "[01:02:05] Them: Hello\n", "render: 3725.9 s is [01:02:05]")
check(render([]) == "", "render: no turns, empty string")

// mic only
let solo = mergeTurns([("Me", removeEcho(mic: mic, call: [])), ("Them", [])])
check(!solo.isEmpty && solo.allSatisfy { $0.label == "Me" }, "mic only: every turn is Me")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
