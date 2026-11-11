// sources: ../../transcript/Transcript.swift ../../transcript/Voice.swift
// The merge turns two word lists into Me and Them turns, and joinLines into lines that follow
// sentences, with short replies inline. Speakers become labels, and the user's voice is learnt
// from calls (spec 6.2). Pure functions and a temporary folder, no audio.
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

// Echo through the speakers, as whisper times it on a real call: the same words in the
// same order, but each side's timings drift by up to a few seconds.
func timed(_ text: String, from start: Double, step: Double = 0.4, jitter: [Double] = [0]) -> [Word] {
    text.split(separator: " ").enumerated().map { k, t in
        let s = start + Double(k) * step + jitter[k % jitter.count]
        return w(s, s + 0.3, String(t))
    }
}
let farSide = timed("it trains you to organise your thoughts before you speak", from: 10)
let echoed = timed("it trains you to organise your thoughts before you speak", from: 11.2, step: 0.65)
let mine = timed("really nine minutes is that what you are saying", from: 20)
let drift = removeEcho(mic: echoed + mine, call: farSide)
check(drift.map(\.text) == mine.map(\.text), "removeEcho: a run of echo drifting 1 to 3.5 s is all dropped, my own words kept (\(drift.map(\.text)))")

let saidNine = timed("nine minutes", from: 30)
let nineEcho = timed("nine minutes", from: 30.3)
let nineMine = timed("nine minutes", from: 32.5)
let nine = removeEcho(mic: nineEcho + nineMine, call: saidNine)
check(nine == nineMine, "removeEcho: repeating what they said keeps my copy, each of theirs cancels one")

let heard = timed("so we are gonna need four aces", from: 40)
let misheard = timed("so we are going to need four aces", from: 41)
check(removeEcho(mic: misheard, call: heard).isEmpty, "removeEcho: one or two misheard words inside the echo go too")

// One side hears one word where the other hears two ("chitchat" and "chit chat").
let joined = timed("most people think communication is just chitchat", from: 60)
let split = timed("most people think communication is just chit chat.", from: 60.3) + timed("really just chitty bing bong", from: 64)
check(removeEcho(mic: split, call: joined).map(\.text) == ["really", "just", "chitty", "bing", "bong"],
      "removeEcho: two mic words matching one call word are echo")
let apart = timed("no setup card trick", from: 70)
let together = timed("no-setup card trick", from: 70.4)
check(removeEcho(mic: together, call: apart).isEmpty, "removeEcho: one mic word matching two call words is echo")

let around = timed("every promotion every raise", from: 50) + timed("and every room", from: 55)
let between = timed("every promotion every raise", from: 50.5) + [w(52.5, 52.8, "yes")] + timed("and every room", from: 55.5)
check(removeEcho(mic: between, call: around).map(\.text) == ["yes"], "removeEcho: my 'yes' in a pause between echoes is kept")

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

// capEnds: the 1.2 s cap on word ends, which applies with tidying on or off
check(capEnds([w(0, 15, "Hello."), w(2, 2.5, "x")]) == [w(0, 1.2, "Hello."), w(2, 2.5, "x")],
      "capEnds: a word ends at most 1.2 s after its start")
check(mergeTurns([("Me", capEnds([w(0, 15, "Hello."), w(10, 10.5, "Again.")]))]).count == 2,
      "capEnds: with tidying off too, a stretched word does not join the next turn")

// joinLines: lines follow sentences, short replies go inline, fillers go (spec 6.3).
// The words of `text`, end to end, spread evenly from `from` to `to`.
func spread(_ text: String, _ from: Double, _ to: Double) -> [Word] {
    let parts = text.split(separator: " ").map(String.init)
    let d = (to - from) / Double(parts.count)
    return parts.enumerated().map { k, t in w(from + Double(k) * d, from + Double(k + 1) * d, t) }
}
func labels(_ turns: [Turn]) -> [String] { turns.map(\.label) }

// asides and utterances: Me's sentence has a pause from 1.6 s to 2.0 s
let park = spread("I think we should", 0, 1.6) + spread("go to the park today.", 2.0, 4.0)
let yeah = joinLines([("Me", park), ("Them", [w(1.7, 1.9, "yeah")])])
check(yeah == [Turn(label: "Me", start: 0, text: "I think we should (Them: yeah) go to the park today.")],
      "joinLines: Them's 'yeah' inside a Me sentence is one Me line, the reply at its time (\(yeah))")
let rather = joinLines([("Me", spread("so here is the plan for the quarter", 0, 5) + spread("then we can talk about it.", 6.4, 9)),
                        ("Them", spread("I would rather not", 5.2, 6.0))])
check(labels(rather) == ["Me", "Them", "Me"] && rather.map(\.start) == [0, 5.2, 6.4],
      "joinLines: Me 0 to 5 s, Them 'I would rather not', Me from 6.4 s are three lines in order (\(rather))")
let no = joinLines([("Me", park), ("Them", [w(1.7, 1.9, "No.")])])
check(labels(no) == ["Me", "Them", "Me"] && !no.contains { $0.text.contains("(") },
      "joinLines: Them's 'no' is never an aside, and said in Me's pause it splits the line (\(no))")
let over = joinLines([("Me", spread("I was saying that we should all go", 0, 4)), ("Them", spread("but what about the budget", 3.0, 5.0))])
check(over == [Turn(label: "Me", start: 0, text: "I was saying that we should all go"),
               Turn(label: "Them", start: 3.0, text: "but what about the budget")],
      "joinLines: talking over Me while Me is still speaking does not cut Me's line into pieces (\(over))")
let carriesOver = joinLines([("Me", park), ("Them", spread("but what about the budget", 1.7, 3.5))])
check(labels(carriesOver) == ["Me", "Them"] && carriesOver[0].text == "I think we should go to the park today.",
      "joinLines: nor does starting in Me's pause and still talking when Me carries on (\(carriesOver))")
let three = joinLines([("Me", park), ("Them", spread("Oh, okay, sure.", 1.4, 1.75))])
check(three.count == 1 && three[0].text == "I think we should (Them: Oh, okay, sure) go to the park today.",
      "joinLines: three words from the list are a short reply, without its closing full stop (\(three))")
let four = joinLines([("Me", park), ("Them", spread("yes yes yes yes", 1.62, 1.98))])
check(labels(four) == ["Me", "Them", "Me"], "joinLines: four words are not a short reply (\(four))")
let twoAsides = joinLines([("Me", park), ("Them", [w(0.5, 0.7, "mm")]), ("Them 2", [w(3.2, 3.4, "right")])])
check(twoAsides.map(\.text) == ["I think (Them: mm) we should go to the park (Them 2: right) today."],
      "joinLines: two short replies sit in time order (\(twoAsides))")
// The host is an utterance: Me's sentences split at 50 s by the 45 s rule, Room 1 talking over
// them from 20 s to 56 s, and Them's "yeah" at 52.5 s, inside both.
let sixty = (0..<6).flatMap { k in spread("a b c d e f g h i end.", Double(10 * k), Double(10 * k + 10)) }
let talker = spread(Array(repeating: "talk", count: 36).joined(separator: " "), 20, 56)
let hosted = joinLines([("Me", sixty), ("Room 1", talker), ("Them", [w(52.5, 52.8, "yeah")])])
let holders = hosted.filter { $0.text.contains("(Them: yeah)") }
check(holders.count == 1 && holders[0].label == "Me" && holders[0].start == 50,
      "joinLines: a reply's host is the latest-starting utterance, Me's from 50 s, not Room 1's (\(hosted.map { ($0.label, $0.start) }))")
// A reply with no host is never somebody in between: Them's "yeah" 0.7 s after Me stopped goes
// inline in the Me line around it.
let gapReply = joinLines([("Me", spread("I think we should", 0, 1.6) + spread("go to the park today.", 4.0, 6.0)),
                          ("Them", [w(2.3, 2.6, "yeah")])])
check(gapReply == [Turn(label: "Me", start: 0, text: "I think we should (Them: yeah) go to the park today.")],
      "joinLines: a reply with no host does not split a line, and goes inline in the line around it (\(gapReply))")
let unhosted = joinLines([("Them", [w(10, 10.4, "Okay.")]), ("Me", [w(10.6, 10.9, "Yeah.")])])
check(unhosted == [Turn(label: "Them", start: 10, text: "Okay."), Turn(label: "Me", start: 10.6, text: "Yeah.")],
      "joinLines: a reply with no host and no line around it is a line of its own, and hosts nothing (\(unhosted))")

// continuing and splitting lines
let hello = spread("Hello there.", 0, 2)
let pause3 = joinLines([("Me", hello + spread("Again.", 5, 6))])
check(pause3 == [Turn(label: "Me", start: 0, text: "Hello there. Again.")],
      "joinLines: Me after a 3 s pause with nobody between carries on the line (\(pause3))")
let pause5 = joinLines([("Me", hello + spread("Again.", 7, 8))])
check(pause5.map(\.start) == [0, 7], "joinLines: after a 5 s pause Me starts a new line (\(pause5))")
let asideBetween = joinLines([("Me", hello + spread("Again.", 5, 6)), ("Them", [w(2.3, 2.6, "Yeah.")])])
check(asideBetween == [Turn(label: "Me", start: 0, text: "Hello there. (Them: Yeah) Again.")],
      "joinLines: a short reply between is not somebody between (\(asideBetween))")
let tenWords = "one two three four five six seven eight nine ten."
let minute = joinLines([("Me", (0..<7).flatMap { k in spread(tenWords, Double(12 * k), Double(12 * k + 10)) })])
check(minute.map(\.start) == [0, 72], "joinLines: a line takes in no further utterance once it spans 60 s (\(minute.map(\.start)))")
let sentences = joinLines([("Me", (0..<13).flatMap { k in spread("a b c d e f g h i end.", Double(10 * k), Double(10 * k + 10)) })])
check(sentences.map(\.start) == [0, 100],
      "joinLines: an utterance over 45 s splits at the next sentence end (\(sentences.map(\.start)))")

// cleaning
let ums = joinLines([("Me", spread("Uh so we um, should go.", 0, 3))])
check(ums.map(\.text) == ["so we should go."], "joinLines: 'um,' and 'Uh' vanish (\(ums.map(\.text)))")
let commas = joinLines([("Me", spread("Well um , I think, um. Then we go.", 0, 4))])
check(commas.map(\.text) == ["Well I think. Then we go."],
      "joinLines: no double spaces or orphaned commas, and a filler's full stop stays (\(commas.map(\.text)))")
let stretched = joinLines([("Me", [w(0, 15, "Hello."), w(10, 10.5, "Again.")])])
check(stretched.count == 2, "joinLines: a word ending 15 s after its start does not hold a line open (\(stretched))")
let stretchedHost = joinLines([("Me", [w(0, 15, "Hello.")]), ("Them", [w(8, 8.3, "yeah")])])
check(labels(stretchedHost) == ["Me", "Them"], "joinLines: nor does it make a reply 8 s later an aside (\(stretchedHost))")
let hashes = joinLines([("Me", spread("hello # there #noise", 0, 2))])
check(hashes.map(\.text) == ["hello there"], "joinLines: tokens starting with # are dropped (\(hashes.map(\.text)))")
// Punctuation written as a token of its own joins the speaker's word before it, and is never a word.
let dotted = joinLines([("Me", park), ("Them", [w(1.7, 1.8, "yeah"), w(1.8, 1.85, ".")])])
check(dotted.map(\.text) == ["I think we should (Them: yeah) go to the park today."],
      "joinLines: 'yeah' then '.' on its own is still a short reply (\(dotted.map(\.text)))")
let lone = joinLines([("Me", park), ("Them", [w(1.7, 1.75, "?")])])
let joinedOn = joinLines([("Them", [w(0, 0.4, "Really"), w(2.5, 2.55, "?")])])
check(lone.map(\.text) == ["I think we should go to the park today."] && joinedOn.map(\.text) == ["Really?"],
      "joinLines: a lone '?' in Me's pause splits nothing; with no word before it, it is dropped (\(lone.map(\.text)) \(joinedOn.map(\.text)))")
let leading = joinLines([("Me", spread("# , so we go.", 0, 2))])
check(leading.map(\.text) == ["so we go."], "joinLines: a ',' with no word before it leaves no orphan (\(leading.map(\.text)))")

// labels and edge cases
let named = joinLines([("Room 1", spread("we start now.", 0, 2)), ("Them 2", [w(1.0, 1.2, "yeah")]),
                       ("Unknown", spread("who said that?", 4, 5)), ("Sam", spread("I did.", 6, 7))])
check(named == [Turn(label: "Room 1", start: 0, text: "we start (Them 2: yeah) now."),
                Turn(label: "Unknown", start: 4, text: "who said that?"),
                Turn(label: "Sam", start: 6, text: "I did.")],
      "joinLines: Room 1, Them 2, Unknown and a first name work like any label (\(named))")
check(render(named).hasSuffix("[00:00:06] Sam: I did.\n"), "render: any label is written as it is")
check(joinLines([]).isEmpty && joinLines([("Me", []), ("Them", [])]).isEmpty, "joinLines: no streams or no words, no lines")
check(joinLines([("Me", spread("Um, uh. erm er umm uhm", 0, 3))]).isEmpty, "joinLines: a stream of only fillers gives no line")

// tidying off: mergeTurns, as mb-transcript --plain uses it
let plainUm = mergeTurns([("Me", spread("I think um we should go.", 0, 3)), ("Them", [w(1.4, 1.45, "yeah")])])
check(labels(plainUm) == ["Me", "Them", "Me"] && plainUm[0].text == "I think um",
      "mergeTurns (--plain): 'um' stays, and a change of label always starts a line (\(plainUm))")

// spokeBetween skips short replies: Me talks for 65 s with no sentence end, so the line can take in
// no further utterance, and Them's "yeah" sits in a 1.2 s pause. Counted as somebody in between, it
// would split Me's utterance at the pause and leave two Me lines.
let longRun = spread(Array(repeating: "word", count: 130).joined(separator: " "), 0, 65)
let afterPause = spread("and then more of it.", 66.2, 68)
let pausedReply = joinLines([("Me", longRun + afterPause), ("Them", [w(65.4, 65.7, "yeah")])])
check(pausedReply.count == 1 && pausedReply[0].label == "Me" && pausedReply[0].text.contains("(Them: yeah) and then more of it."),
      "joinLines: a short reply in a pause of 1.5 s or less never splits a speaker who has run past 60 s (\(pausedReply.map { ($0.label, $0.start) }))")

// ======================================================================= speakers to labels (6.2)

let model = "FluidInference/speaker-diarization-coreml@df2625ac79a7ac6b65ad868fee6d80f320da4232"
let e1: [Double] = [1, 0, 0, 0], e2: [Double] = [0, 1, 0, 0], e3: [Double] = [0, 0, 1, 0], e4: [Double] = [0, 0, 0, 1]
/// A unit vector whose cosine with e1 (the voice print in these tests) is `c`.
func at(_ c: Double) -> [Double] { [c, (1 - c * c).squareRoot(), 0, 0] }
func sp(_ id: String, seconds: Double = 60, median: Double = 4, vector: [Double], first: Double = 0) -> SpeakerInfo {
    SpeakerInfo(id: id, seconds: seconds, median: median, vector: vector, first: first)
}
func vp(seconds: Double = 120, meetings: Int = 2, sources: [String] = ["m-a", "m-b"], sample: Bool = false, refusals: Int = 0,
        vector: [Double] = [1, 0, 0, 0], model m: String = model, updated: String = "2026-11-10T18:00:00Z") -> VoicePrint {
    VoicePrint(model: m, seconds: seconds, meetings: meetings, sources: sources, sample: sample, refusals: refusals, vector: vector, updated: updated)
}
func close(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 } }
let usable = vp()

// --- loading the speakers file ---
func fixtureData(_ name: String) -> Data { (try? Data(contentsOf: fixtures.appendingPathComponent(name))) ?? Data() }
let loadedMic = try? loadSpeakers(fixtureData("speakers-mic.json"))
check(loadedMic?.model == model && loadedMic?.segments.count == 2 && loadedMic?.speakers.map(\.id) == ["S1", "S2"]
      && loadedMic?.speakers[1].first == 10.3 && loadedMic?.speakers[1].vector == [0.1, 0.9, 0.1, 0.0],
      "loadSpeakers: reads the model, segments and speakers, and fills each speaker's first segment start")
let twoSegments = try? loadSpeakers(Data("""
{"model": "m", "segments": [{"speaker": "A", "start": 7, "end": 9}, {"speaker": "A", "start": 2, "end": 3}],
 "speakers": [{"id": "A", "seconds": 3, "median": 1.5, "vector": [1]}]}
""".utf8))
check(twoSegments?.speakers.first?.first == 2, "loadSpeakers: first is the earliest segment start, whatever the order")
check((try? loadSpeakers(Data("{\"model\": \"m\"}".utf8))) == nil && (try? loadSpeakers(Data("garbage".utf8))) == nil,
      "loadSpeakers: a file without segments and speakers, or not JSON, throws")

// --- candidates: which speakers a word can belong to ---
let abSegments = [Segment(speaker: "A", start: 1, end: 2), Segment(speaker: "B", start: 2, end: 3)]
check(candidates([w(1.5, 2.5, "x"), w(0.5, 1.5, "y")], abSegments) == [["B"], ["A"]],
      "candidates: a midpoint belongs to a segment from its start (inclusive) to its end (exclusive)")
let oneSegment = [Segment(speaker: "A", start: 5, end: 6)]
check(candidates([w(6.5, 7.5, "x"), w(3.5, 4.5, "y")], oneSegment) == [["A"], ["A"]],
      "candidates: with no segment around it, a word 1.0 s from a segment's nearer edge takes that speaker")
check(candidates([w(7.0, 7.2, "x"), w(3.8, 4.0, "y")], oneSegment) == [[], []],
      "candidates: 1.1 s from the nearer edge, a word has no candidate")
check(candidates([w(6, 6.4, "x")], [Segment(speaker: "A", start: 0, end: 10), Segment(speaker: "B", start: 5, end: 8)]) == [["A", "B"]],
      "candidates: overlapping speakers come in order of their segment's start, the latest-starting last")

// --- words with no candidate, or several ---
check(fallbackLabel(["S1": "Me"], side: .mic) == "Me" && fallbackLabel(["T1": "Them"], side: .call) == "Them",
      "fallbackLabel: on a side where every speaker has one label, a word with no candidate takes it")
check(fallbackLabel(["S1": "Me", "S2": "Room 1"], side: .mic) == "Unknown" && fallbackLabel(["T1": "Them 1", "T2": "Them 2"], side: .call) == "Them",
      "fallbackLabel: otherwise Unknown on the microphone side and Them on the call side")
check(fallbackLabel([:], side: .mic) == "Me" && fallbackLabel([:], side: .call) == "Them",
      "fallbackLabel: a side with no speakers is Me or Them")
check(resolve([w(20, 20.3, "far.")], [[]], names: ["S1": "Me"], fallback: fallbackLabel(["S1": "Me"], side: .mic)) == ["Me"],
      "resolve: a word with no candidate on a one-speaker side is that speaker's label (Me)")
let sentenceWords = [w(0, 0.3, "we"), w(0.4, 0.6, "all"), w(0.7, 0.9, "went"), w(1.0, 1.3, "there.")]
let ab = ["A": "Me", "B": "Room 1"]
check(resolve(sentenceWords, [["A"], ["A", "B"], ["A"], ["B"]], names: ab, fallback: "Unknown") == ["Me", "Me", "Me", "Room 1"],
      "resolve: two candidate labels go to the label most single-candidate words of the sentence hold")
check(resolve(sentenceWords, [["A"], ["A", "B"], ["B"], []], names: ab, fallback: "Unknown") == ["Me", "Room 1", "Room 1", "Unknown"]
      && resolve(sentenceWords, [["A"], ["B", "A"], ["B"], []], names: ab, fallback: "Unknown") == ["Me", "Me", "Room 1", "Unknown"],
      "resolve: a tie goes to the label of the latest-starting segment")
let twoSentences = [w(0, 0.3, "Yes."), w(0.4, 0.6, "Yes."), w(0.7, 0.9, "we"), w(1.0, 1.3, "go."), w(1.4, 1.6, "Now.")]
check(resolve(twoSentences, [["A"], ["A"], ["A", "B"], ["B"], ["A"]], names: ab, fallback: "Unknown")[2] == "Room 1",
      "resolve: only the word's own sentence votes")
check(resolve([w(0, 0.3, "so."), w(0.4, 0.6, "and.")], [["A", "C"], ["A", "B"]], names: ["A": "Me", "C": "Me", "B": "Room 1"], fallback: "Unknown")
      == ["Me", "Room 1"], "resolve: candidates with the same label are one candidate label")

// --- smoothing, on labels after naming ---
let six = spread("one two three four five six.", 0, 6)
check(smooth(["Me", "Me", "Me", "Unknown", "Me", "Me"], six) == Array(repeating: "Me", count: 6),
      "smooth: one Unknown word between two Me runs (two Me clusters) becomes Me")
check(smooth(["A", "B", "B", "A", "A", "A"], six) == Array(repeating: "A", count: 6),
      "smooth: a run of two between runs of one label takes that label")
check(smooth(["A", "B", "B", "B", "A", "A"], six) == ["B", "B", "B", "B", "A", "A"],
      "smooth: a run of three stays, and a single word at a sentence's start takes a neighbouring run of three")
check(smooth(["A", "A", "A", "B"], spread("one two three four.", 0, 4)) == ["A", "A", "A", "A"]
      && smooth(["A", "A", "B"], spread("one two three.", 0, 3)) == ["A", "A", "B"],
      "smooth: a single word at a sentence's end takes its neighbouring run only when that run has three or more words")
check(smooth(["A", "B", "A", "B", "A"], spread("a b c d e.", 0, 5)) == ["A", "A", "B", "A", "A"],
      "smooth: the runs are computed once, and one pass changes them")
check(smooth(["A", "A", "A", "B", "A", "A"], spread("a b c. d e f.", 0, 6)) == ["A", "A", "A", "B", "A", "A"],
      "smooth: runs never cross a sentence end")

// --- naming the call side ---
let t1 = sp("T1", seconds: 500, median: 5.2, vector: e3), t2 = sp("T2", seconds: 40, median: 1.92, vector: e4)
check(nameCall([t1, t2], keptWords: ["T1": 92, "T2": 8], firstWord: ["T1": 0, "T2": 30], userVoice: [], print: nil, counted: false)
      == ["T1": "Them", "T2": "Them"], "nameCall: 92% and 8% with a 1.9 s median (17:54's over-split) is plain Them only")
let small = sp("T2", seconds: 20, median: 3, vector: e4)
check(nameCall([t1, small], keptWords: ["T1": 96, "T2": 4], firstWord: ["T1": 0, "T2": 30], userVoice: [], print: nil, counted: true)
      == ["T1": "Them 1", "T2": "Them 2"], "nameCall: with a call count, a 4% speaker is still Them 2")
check(nameCall([t1, small], keptWords: ["T1": 96, "T2": 4], firstWord: ["T1": 0, "T2": 30], userVoice: [], print: nil, counted: false)
      == ["T1": "Them", "T2": "Them"], "nameCall: without a count, a 4% speaker is plain Them")
let quietA = sp("A", seconds: 30, median: 3, vector: e3, first: 10), talkerB = sp("B", seconds: 300, median: 5, vector: e4, first: 20)
check(nameCall([quietA, talkerB], keptWords: ["B": 50], firstWord: ["B": 21], userVoice: [], print: nil, counted: true) == ["A": "Them", "B": "Them"]
      && nameCall([quietA, talkerB], keptWords: ["B": 50], firstWord: ["B": 21], userVoice: [], print: nil, counted: false) == ["A": "Them", "B": "Them"],
      "nameCall: A (first segment at 10 s, no words of its own) and B give plain Them, never Them 2")
let echoOfMe = sp("U", seconds: 8, median: 2, vector: at(0.75))
check(nameCall([echoOfMe, t1], keptWords: ["U": 5, "T1": 90], firstWord: ["U": 1, "T1": 0], userVoice: [], print: usable, counted: false)
      == ["U": "Unknown", "T1": "Them"], "nameCall: a print match of 0.75 with only 8 s is Unknown")
check(nameCall([sp("C", vector: e2), t1], keptWords: ["C": 50, "T1": 50], firstWord: ["C": 1, "T1": 0], userVoice: ["C"], print: nil, counted: false)
      == ["C": "Unknown", "T1": "Them"], "nameCall: a call speaker that is the user's voice come back is Unknown")
let t3 = sp("T3", seconds: 300, median: 4, vector: e4)
check(nameCall([sp("P", seconds: 300, median: 4, vector: at(0.5)), t1, t3], keptWords: ["P": 30, "T1": 40, "T3": 30],
               firstWord: ["P": 0, "T1": 9, "T3": 5], userVoice: [], print: usable, counted: false)
      == ["P": "Them", "T1": "Them 2", "T3": "Them 1"],
      "nameCall: a cosine of 0.45 or more with the print is plain Them; the rest are numbered by first word")

// --- naming the microphone side ---
let roomR = sp("R", seconds: 100, median: 4, vector: e3)
func micNamed(_ speakers: [SpeakerInfo], _ kept: [String: Int], first: [String: Double]? = nil, echo: Set<String> = [],
              unknown: Set<String> = [], print: VoicePrint? = nil, isCall: Bool = false, counted: Bool = false) -> [String: String] {
    let firsts = first ?? Dictionary(uniqueKeysWithValues: speakers.enumerated().map { ($1.id, Double($0)) })
    return nameMic(speakers, keptWords: kept, firstWord: firsts, echo: echo, unknown: unknown, print: print, isCall: isCall, counted: counted)
}
check(micNamed([sp("U", seconds: 10, median: 3, vector: at(0.6)), roomR], ["U": 50, "R": 50], print: usable)["U"] == "Me",
      "nameMic: a print match of 0.60 with 10 s is Me")
check(micNamed([sp("U", seconds: 10, median: 3, vector: at(0.59)), roomR], ["U": 50, "R": 50], print: usable)["U"] == "Unknown"
      && micNamed([sp("U", seconds: 9, median: 3, vector: at(0.6)), roomR], ["U": 50, "R": 50], print: usable)["U"] == "Unknown",
      "nameMic: at 0.59, or with 9 s, it is Unknown")
check(micNamed([sp("U", seconds: 12, median: 2.4, vector: at(0.7)), roomR], ["U": 4, "R": 96], print: usable)["U"] == "Me",
      "nameMic: a print match with a 2.4 s median and a 4% share is Me")
check(micNamed([sp("U", seconds: 9, median: 4, vector: at(0.8)), roomR], ["U": 20, "R": 80], print: usable, isCall: true)["U"] == "Unknown",
      "nameMic: 0.80 with 9 s, 20% and a 4 s median is Unknown, never Room")
let echoCluster = [sp("U", seconds: 300, median: 4, vector: e1), sp("E", seconds: 175, median: 4, vector: e2), sp("R", seconds: 25, median: 3, vector: e3)]
check(micNamed(echoCluster, ["U": 95, "E": 60, "R": 5], echo: ["E"], isCall: true) == ["U": "Me", "R": "Room 1"],
      "nameMic: with no print on a call, 95% of kept words is Me though an echo cluster held 35% of the talk")
var mixedWords: [Word] = [], mixedCandidates: [[String]] = []
for k in 0..<121 {
    mixedWords.append(w(Double(k), Double(k) + 0.3, "w"))
    mixedCandidates.append(k < 85 ? ["A"] : k < 100 ? ["B"] : ["A", "B"])
}
let mixedKept = keptCounts(mixedWords, mixedCandidates)
check(mixedKept.counts == ["A": 85, "B": 15] && mixedKept.first == ["A": 0, "B": 85],
      "keptCounts: only words whose one candidate is the speaker count, and the first such word starts the order")
check(micNamed([sp("A", vector: e1), sp("B", vector: e2)], mixedKept.counts, first: mixedKept.first, isCall: true)["A"] == "Me",
      "nameMic: 85% of single-candidate words (70% of all words) is Me on a call")
check(micNamed([sp("A", vector: e1), sp("B", vector: e2)], ["A": 79, "B": 21], isCall: true)["A"] == "Room 1",
      "nameMic: 79% on a call with no print is not Me")
check(micNamed([sp("A", vector: e2), roomR], ["A": 90, "R": 10], print: usable, isCall: true)["A"] == "Room 1"
      && micNamed([sp("A", vector: at(0.5)), roomR], ["A": 90, "R": 10], print: usable, isCall: true)["A"] == "Me",
      "nameMic: 80% on a call is Me only with no usable print or a cosine of 0.45 or more with it")
check(micNamed([sp("A", vector: e2), roomR], ["A": 50, "R": 50], unknown: ["A"]) == ["A": "Unknown", "R": "Room 1"],
      "nameMic: a speaker paired with a call voice but sharing no words is Unknown")
let rooms = [sp("S1", vector: e1, first: 0), sp("S2", vector: e2, first: 5), sp("S3", vector: e3, first: 1), sp("S4", vector: e4, first: 2)]
check(micNamed(rooms, ["S1": 10, "S2": 10, "S4": 10], first: ["S1": 30, "S2": 10, "S4": 20], counted: true)
      == ["S2": "Room 1", "S4": "Room 2", "S1": "Room 3", "S3": "Unknown"],
      "nameMic: Room numbers follow the first kept word, with no gaps for a speaker without one")
check(micNamed([sp("A", vector: e1), sp("B", vector: e2), sp("C", vector: e3)], ["A": 85, "B": 10, "C": 5])
      == ["A": "Room 1", "B": "Room 2", "C": "Room 3"], "nameMic: with no usable print in a room recording, Room 1 to N and no Me")
check(micNamed([sp("A", vector: e1), sp("B", median: 2.4, vector: e2), sp("C", vector: e3)], ["A": 90, "B": 6, "C": 4])
      == ["A": "Room 1", "B": "Unknown", "C": "Unknown"], "nameMic: without a count, under 5% or a median under 2.5 s is Unknown")

// --- the voice print ---
check(usablePrint(vp(seconds: 59.9), model: model) == nil && usablePrint(vp(meetings: 1), model: model) == nil
      && usablePrint(vp(model: "other@1"), model: model) == nil,
      "usablePrint: under 60 s, from 1 meeting without a sample, or from another model is unusable")
check(usablePrint(vp(seconds: 75, meetings: 1, sources: [], sample: true), model: model) != nil && usablePrint(vp(seconds: 60), model: model) != nil,
      "usablePrint: 75 s from 1 meeting with sample true is usable, and so is 60 s from 2")
let oldPrint = try? decodePrint(fixtureData("voice-old.json"))
check(oldPrint?.sample == false && oldPrint?.refusals == 0 && oldPrint?.meetings == 2 && oldPrint?.seconds == 75,
      "decodePrint: a voice.json without sample or refusals reads them as false and 0")
check((try? decodePrint(fixtureData("voice-sample.json")))?.sample == true, "decodePrint: sample is read")
if let encoded = try? encodePrint(usable), let back = try? decodePrint(encoded) {
    check(back == usable, "encodePrint: a print reads back as it was written")
} else { check(false, "encodePrint: a print reads back as it was written") }
check(abs(cosine([1, 1, 0, 0], [1, 0, 0, 0]) - 0.5.squareRoot()) < 1e-12 && cosine([0, 0], [1, 0]) == 0 && cosine([1], [1, 0]) == 0,
      "cosine: of two vectors, 0 for a zero vector or different lengths")

// --- isCall ---
check(!isCall(callWords: (0..<10).map { w(Double($0), Double($0) + 0.5, "x") }, callSpeakers: nil),
      "isCall: 5 s of call words is not a call")
check(isCall(callWords: [], callSpeakers: [sp("T1", seconds: 300, vector: e3)]), "isCall: no call words but 300 s of call speakers is a call")
check(!isCall(callWords: (0..<300).map { w(Double($0), Double($0) + 1, "x") }, callSpeakers: [sp("T1", seconds: 19, vector: e3)])
      && isCall(callWords: (0..<40).map { w(Double($0), Double($0) + 0.5, "x") }, callSpeakers: []),
      "isCall: the speakers' talk when there are speakers, else the words' (20 s or more)")

// --- one voice heard on both sides ---
let micU = sp("U", vector: e1), micE = sp("E", vector: [0, 0, 0.7, (1 - 0.49).squareRoot()]), callC = sp("C", vector: e3)
let shared = (0..<5).map { w(20 + Double($0), 20.3 + Double($0), "word\($0)") }
let sharedLater = shared.map { w($0.start + 0.3, $0.end + 0.3, $0.text) }
let fivePairs = (0..<5).map { (micWord: $0, callWord: $0) }
let micE5 = Array(repeating: ["E"], count: 5), callC5 = Array(repeating: ["C"], count: 5)
let micEcho = pairVoices(mic: [micU, micE], call: [callC], pairs: fivePairs, micWords: sharedLater, callWords: shared,
                         micCandidates: micE5, callCandidates: callC5, print: nil)
check(micEcho.micEcho == ["E"] && micEcho.callEcho.isEmpty && micEcho.micUnknown.isEmpty,
      "pairVoices: a microphone cluster at 0.7 with a call speaker, its shared words 0.3 s later, is echo")
let callBack = pairVoices(mic: [micE], call: [callC], pairs: fivePairs, micWords: shared, callWords: sharedLater,
                          micCandidates: micE5, callCandidates: callC5, print: nil)
check(callBack.callEcho == ["C"] && callBack.micEcho.isEmpty && callBack.micUnknown.isEmpty,
      "pairVoices: when the call side's copies come later, the call speaker is the echo")
let noShared = pairVoices(mic: [micU, micE], call: [callC], pairs: [], micWords: sharedLater, callWords: shared,
                          micCandidates: micE5, callCandidates: callC5, print: nil)
check(noShared.micUnknown == ["E"] && noShared.micEcho.isEmpty && noShared.callEcho.isEmpty,
      "pairVoices: a pair with no shared words makes the microphone speaker Unknown")
let below = sp("E", vector: [0, 0, 0.59, (1 - 0.59 * 0.59).squareRoot()])
func nothing(_ v: (micEcho: Set<String>, callEcho: Set<String>, micUnknown: Set<String>)) -> Bool {
    v.micEcho.isEmpty && v.callEcho.isEmpty && v.micUnknown.isEmpty
}
check(nothing(pairVoices(mic: [below], call: [callC], pairs: [], micWords: [], callWords: [], micCandidates: [], callCandidates: [], print: nil)),
      "pairVoices: a cosine of 0.59 is two voices")
check(nothing(pairVoices(mic: [sp("E", vector: e1)], call: [sp("C", vector: e1)], pairs: [], micWords: [], callWords: [], micCandidates: [],
                         callCandidates: [], print: usable)),
      "pairVoices: a pair that matches the print is not one voice heard twice")

// --- words to labels, end to end on synthetic speakers ---
/// The words of `text`, `step` apart from `from`, each 0.3 s long.
func said(_ text: String, from: Double, step: Double = 0.4) -> [Word] {
    text.split(separator: " ").enumerated().map { k, t in w(from + Double(k) * step, from + Double(k) * step + 0.3, String(t)) }
}
func side(_ segments: [Segment], _ speakers: [SpeakerInfo]) -> SideSpeakers { SideSpeakers(model: model, segments: segments, speakers: speakers) }

// The far side leaks into the microphone: its echo there is a cluster of its own, at 0.7 with the call speaker.
let farSays = said("we should look at the numbers again before friday.", from: 20)
let leak = farSays.map { w($0.start + 0.3, $0.end + 0.3, $0.text) } + said("something else entirely", from: 26)
let mineFirst = said("hello everyone thanks for joining.", from: 0), mineLast = said("yes let us do that.", from: 30)
let leakRun = labelWords(mic: mineFirst + leak + mineLast, call: farSays,
                         micSpeakers: side([Segment(speaker: "U", start: 0, end: 2.5), Segment(speaker: "E", start: 20.2, end: 27.5),
                                            Segment(speaker: "U", start: 29.8, end: 32.5)],
                                           [sp("U", seconds: 5, vector: e1), micE]),
                         callSpeakers: side([Segment(speaker: "C", start: 19.8, end: 24)], [sp("C", seconds: 30, vector: e3)]),
                         print: nil)
let leakLines = transcriptLines(leakRun, plain: false)
check(leakRun.mic.count == 10 && leakRun.micLabels.allSatisfy { $0 == "Me" } && !leakLines.contains { $0.label.hasPrefix("Room") }
      && !leakLines.contains { $0.text.contains("entirely") } && leakRun.log.contains { $0.contains("3 microphone words") },
      "labelWords: an echo cluster's 3 remaining words are dropped, the log gives the count, and there is no Room line (\(leakLines) \(leakRun.log))")

// The user's voice comes back on the call side, with no usable print: a call speaker at 0.8 with the
// microphone speaker, repeating its words 0.3 s later.
let mineToShip = said("I think we can ship it on monday.", from: 10) + said("and then we test it.", from: 40)
let repeated = said("I think we can ship it on monday.", from: 10.3) + said("pardon sorry", from: 15)
let farReply = said("sounds good to me.", from: 20)
let backRun = labelWords(mic: mineToShip, call: repeated + farReply,
                         micSpeakers: side([Segment(speaker: "U", start: 9.8, end: 13.5), Segment(speaker: "U", start: 39.8, end: 42),
                                            Segment(speaker: "V", start: 50, end: 55)],
                                           [sp("U", seconds: 45, vector: e1), sp("V", seconds: 5, vector: e4)]),
                         callSpeakers: side([Segment(speaker: "C", start: 10.1, end: 13.8), Segment(speaker: "C", start: 14.9, end: 15.8),
                                             Segment(speaker: "T", start: 19.8, end: 22)],
                                            [sp("C", seconds: 6, vector: [0.8, 0.6, 0, 0]), sp("T", seconds: 30, vector: e3)]),
                         print: nil)
check(backRun.mic.count == 13 && backRun.micLabels.allSatisfy { $0 == "Me" },
      "labelWords: with no usable print, the user's voice come back on the call side leaves every microphone word Me (\(backRun.micLabels))")
check(backRun.call.map(\.text) == ["pardon", "sorry", "sounds", "good", "to", "me."]
      && backRun.callLabels == ["Unknown", "Unknown", "Them", "Them", "Them", "Them"]
      && backRun.log.contains { $0.hasPrefix("Your voice was heard on the call side") },
      "labelWords: its repeats are dropped, the rest is Unknown, and the log says so (\(backRun.call.map(\.text)) \(backRun.callLabels) \(backRun.log))")

// A usable print: a call speaker matching it at 0.75 with 8 s repeats the user's words 0.3 s later.
let printRun = labelWords(mic: mineToShip, call: Array(repeated.prefix(8)) + farReply,
                          micSpeakers: side([Segment(speaker: "U", start: 9.8, end: 13.5), Segment(speaker: "U", start: 39.8, end: 42)],
                                            [sp("U", seconds: 45, vector: at(0.9))]),
                          callSpeakers: side([Segment(speaker: "P", start: 10.1, end: 13.8), Segment(speaker: "T", start: 19.8, end: 22)],
                                             [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                          print: usable)
let printLines = transcriptLines(printRun, plain: false)
check(printRun.mic.count == 13 && printRun.micLabels.allSatisfy { $0 == "Me" },
      "labelWords: the user's voice on the call side does not cancel the user's own microphone words")
check(!printLines.contains { $0.label == "Unknown" } && printLines.map(\.label) == ["Me", "Them", "Me"],
      "labelWords: a print match of 0.75 with 8 s whose words repeat the user's 0.3 s later adds no line (\(printLines))")
check(removeEcho(mic: mineToShip, call: Array(repeated.prefix(8))).count == 5,
      "removeEcho: against every call word, the call-side repeat would have cancelled the user's own words")

// A usable print that matches nobody on the microphone side.
let notMe = labelWords(mic: said("shall we start then.", from: 0) + said("yes let us begin now.", from: 5), call: [],
                       micSpeakers: side([Segment(speaker: "A", start: 0, end: 2), Segment(speaker: "B", start: 5, end: 7.5)],
                                         [sp("A", seconds: 30, vector: at(0.52)), sp("B", seconds: 30, vector: e3)]),
                       callSpeakers: nil, print: usable)
check(notMe.log.contains("Your voice was not recognised on the microphone side (best match 0.52)") && notMe.micLabels.contains("Unknown"),
      "labelWords: a usable print matching nobody logs 'not recognised' with the best match (\(notMe.log))")
let notYet = labelWords(mic: said("shall we start then.", from: 0) + said("yes let us begin now.", from: 5), call: [],
                        micSpeakers: side([Segment(speaker: "A", start: 0, end: 2), Segment(speaker: "B", start: 5, end: 7.5)],
                                          [sp("A", seconds: 30, vector: e1), sp("B", seconds: 30, vector: e3)]),
                        callSpeakers: nil, print: vp(meetings: 1))
check(Set(notYet.micLabels) == ["Room 1", "Room 2"] && notYet.log.contains { $0.contains("not learnt yet") },
      "labelWords: with no usable print, a room recording is Room 1 and Room 2 and the log says the voice is not learnt yet (\(notYet.log))")
let unlabelled = labelWords(mic: mineToShip, call: farReply, micSpeakers: nil, callSpeakers: nil, print: usable)
check(unlabelled.micLabels.count == 13 && unlabelled.micLabels.allSatisfy { $0 == "Me" } && unlabelled.callLabels == ["Them", "Them", "Them", "Them"]
      && unlabelled.log.isEmpty && transcriptLines(unlabelled, plain: false).map(\.label) == ["Me", "Them", "Me"],
      "labelWords: without speakers files, Me and Them as before")

// The fixtures, with tidying off: Room 1 and Them lines, "um" kept, a line at every change of label.
let fxMic = fixture("labelled-mic.json"), fxCall = fixture("labelled-call.json")
let fxMicSp = try? loadSpeakers(fixtureData("speakers-mic.json")), fxCallSp = try? loadSpeakers(fixtureData("speakers-call.json"))
let fxRun = labelWords(mic: capEnds(fxMic), call: capEnds(fxCall),
                       micSpeakers: fxMicSp.map { SideSpeakers(model: $0.model, segments: $0.segments, speakers: $0.speakers) },
                       callSpeakers: fxCallSp.map { SideSpeakers(model: $0.model, segments: $0.segments, speakers: $0.speakers) },
                       print: nil)
let fxPlain = transcriptLines(fxRun, plain: true)
check(fxPlain.map(\.label) == ["Me", "Room 1", "Them", "Room 1", "Them"] && fxPlain[1].text == "Um, what"
      && fxPlain[2].text == "yeah" && fxPlain[3].text == "about the budget?",
      "--plain with the speaker fixtures: Room 1 and Them lines, 'um' kept, a new line at every change of label (\(fxPlain))")
let fxTidy = transcriptLines(fxRun, plain: false)
check(fxTidy.map(\.label) == ["Me", "Room 1", "Them"] && fxTidy[1].text == "what (Them: yeah) about the budget?",
      "tidied, the speaker fixtures give Me, Room 1 and Them lines (\(fxTidy))")

// --- learning the voice from calls ---
let now = Date(timeIntervalSince1970: 1_800_000_000)
let stamp = ISO8601DateFormatter().string(from: now)
let userA = sp("A", seconds: 40, median: 4, vector: [3, 4, 0, 0]), otherB = sp("B", seconds: 5, median: 3, vector: e3)
let farT = sp("T", seconds: 200, median: 5, vector: e4)
func learnFrom(_ print: VoicePrint?, _ mic: [SpeakerInfo] = [userA, otherB], kept: [String: Int] = ["A": 95, "B": 5],
               call: [SpeakerInfo] = [farT], isCall: Bool = true, source: String = "m-new", m: String = model) -> LearnOutcome {
    learn(print, mic: mic, keptWords: kept, call: call, isCall: isCall, model: m, source: source, now: now)
}
if case .write(let fresh) = learnFrom(nil) {
    check(fresh.model == model && fresh.seconds == 40 && fresh.meetings == 1 && fresh.sources == ["m-new"] && !fresh.sample
          && fresh.refusals == 0 && close(fresh.vector, [0.6, 0.8, 0, 0]) && fresh.updated == stamp,
          "learn: a qualifying call starts a print, its vector scaled to length 1 (\(fresh))")
} else { check(false, "learn: a qualifying call starts a print, its vector scaled to length 1") }
check(learnFrom(nil, isCall: false) == .unchanged && learnFrom(usable, isCall: false) == .unchanged,
      "learn: a room recording at 95% never changes the print")
check(learnFrom(nil, call: []) == .unchanged && learnFrom(vp(seconds: 30, meetings: 1), call: []) == .unchanged,
      "learn: a call with call words but no call speakers never changes it")
check(learnFrom(nil, kept: ["A": 79, "B": 21]) == .unchanged, "learn: 79% does not qualify")
let near40 = sp("T", vector: [0.24, 0.32, (1 - 0.16).squareRoot(), 0])
check(learnFrom(nil, call: [near40]) == .unchanged && learnFrom(nil, call: [farT, near40]) == .unchanged,
      "learn: a call-side cosine of 0.40 does not qualify")
let fiveSeconds = vp(seconds: 5, meetings: 1, sources: ["m-0"], vector: e1)
if case .write(let refusedOnce) = learnFrom(fiveSeconds, [sp("A", seconds: 40, vector: at(0.59)), otherB]) {
    check(refusedOnce.refusals == 1 && refusedOnce.seconds == 5 && refusedOnce.sources == ["m-0"] && refusedOnce.vector == e1,
          "learn: any print speech plus 0.59 is refused, and while unusable the refusal is counted")
} else { check(false, "learn: any print speech plus 0.59 is refused, and while unusable the refusal is counted") }
check(learnFrom(vp(sources: ["m-a", "m-new"], vector: [0.6, 0.8, 0, 0])) == .unchanged, "learn: the same source twice is refused")
check(learnFrom(vp(vector: e3)) == .unchanged, "learn: a call refused against a usable print is unchanged")
if case .write(let merged) = learnFrom(vp(seconds: 30, meetings: 1, sources: ["m-0"], vector: [2, 0, 0, 0]),
                                       [sp("A", seconds: 10, vector: [3, 3, 0, 0]), otherB]) {
    let half = 0.5.squareRoot()
    check(merged.seconds == 40 && merged.meetings == 2 && merged.sources == ["m-0", "m-new"] && merged.refusals == 0
          && close(merged.vector, [(30 + 10 * half) / 40, 10 * half / 40, 0, 0]),
          "learn: vectors are scaled to length 1 and averaged by talk (\(merged.vector))")
} else { check(false, "learn: vectors are scaled to length 1 and averaged by talk") }
if case .write(let replaced) = learnFrom(vp(seconds: 500, meetings: 5, vector: e3, model: "other@1")) {
    check(replaced.model == model && replaced.seconds == 40 && replaced.meetings == 1 && replaced.sources == ["m-new"]
          && close(replaced.vector, [0.6, 0.8, 0, 0]), "learn: another model's print is replaced")
} else { check(false, "learn: another model's print is replaced") }
let samplePrint = vp(seconds: 75, meetings: 1, sources: [], sample: true, vector: [0.6, 0.8, 0, 0])
if case .write(let fromSample) = learnFrom(samplePrint) {
    check(fromSample.sample && fromSample.meetings == 2 && fromSample.sources == ["m-new"] && fromSample.seconds == 115,
          "learn: a call adds to a sample print, keeps sample true and raises meetings")
} else { check(false, "learn: a call adds to a sample print, keeps sample true and raises meetings") }
// Refusals while the print is not usable: two in a row discard it, and a learnt call resets the count.
let voiceA = vp(seconds: 30, meetings: 1, sources: ["m-0"], vector: [0.6, 0.8, 0, 0])
let voiceB = [sp("B", seconds: 40, vector: e3), sp("X", seconds: 2, vector: e2)]
let keptB = ["B": 95, "X": 5]
let firstRefusal = learnFrom(voiceA, voiceB, kept: keptB, source: "m-1")
if case .write(let once) = firstRefusal {
    check(once.refusals == 1 && learnFrom(once, voiceB, kept: keptB, source: "m-2") == .discard,
          "learn: while unusable, one refused call writes refusals 1 and a second discards the print")
    if case .write(let reset) = learnFrom(once, source: "m-2") {
        check(reset.refusals == 0 && reset.meetings == 2, "learn: a learnt call in between resets refusals to 0")
    } else { check(false, "learn: a learnt call in between resets refusals to 0") }
} else { check(false, "learn: while unusable, one refused call writes refusals 1 and a second discards the print") }
if case .write(let startB) = learnFrom(nil, voiceB, kept: keptB, source: "m-3") {
    check(startB.vector == e3 && startB.meetings == 1, "learn: after a discard, voice B's next qualifying call starts a new print")
} else { check(false, "learn: after a discard, voice B's next qualifying call starts a new print") }
check(learnLog(.learnt(seconds: 41.6)) == ["Learnt 42 s of your voice from this call"]
      && learnLog(.refused) == ["This call's microphone voice did not match the voice learnt so far, so it was not learnt"],
      "learnLog: the meeting's log says what was learnt, or that the voice did not match")

// --- saving only if unchanged ---
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-voice-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let voiceURL = folder.appendingPathComponent("voice.json"), tmpURL = folder.appendingPathComponent("voice.json.tmp")
func contents(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }
func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
let newPrint = vp(seconds: 61, vector: e2)
check((try? savePrintIfUnchanged(newPrint, at: voiceURL, readState: nil)) == true && (try? decodePrint(contents(voiceURL) ?? Data())) == newPrint
      && mode(voiceURL) == 0o600 && !FileManager.default.fileExists(atPath: tmpURL.path),
      "savePrintIfUnchanged: with no file read and none there, writes it, 0600, with no voice.json.tmp left")
let readNow = fileState(at: voiceURL)
try? Data("{\"changed\": true}".utf8).write(to: voiceURL)
check((try? savePrintIfUnchanged(usable, at: voiceURL, readState: readNow)) == false && contents(voiceURL) == Data("{\"changed\": true}".utf8),
      "savePrintIfUnchanged: a file changed after it was read is not written over")
let readAgain = fileState(at: voiceURL)
try? FileManager.default.removeItem(at: voiceURL)
check((try? savePrintIfUnchanged(usable, at: voiceURL, readState: readAgain)) == false && !FileManager.default.fileExists(atPath: voiceURL.path),
      "savePrintIfUnchanged: a file that vanished after it was read (Forget my voice) is not written")
try? Data("{}".utf8).write(to: voiceURL)
check((try? savePrintIfUnchanged(usable, at: voiceURL, readState: nil)) == false, "savePrintIfUnchanged: nor one that appeared after none was read")
let readThird = fileState(at: voiceURL)
try? Data("stale".utf8).write(to: tmpURL)
check((try? savePrintIfUnchanged(usable, at: voiceURL, readState: readThird)) == true && (try? decodePrint(contents(voiceURL) ?? Data())) == usable
      && !FileManager.default.fileExists(atPath: tmpURL.path), "savePrintIfUnchanged: an old voice.json.tmp is replaced, and none is left")
let readFourth = fileState(at: voiceURL)
try? FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
var threw = false
do { _ = try savePrintIfUnchanged(newPrint, at: voiceURL, readState: readFourth) } catch { threw = true }
check(threw && (try? decodePrint(contents(voiceURL) ?? Data())) == usable,
      "savePrintIfUnchanged: it writes through voice.json.tmp, so when that cannot be made voice.json is left as it was")
try? FileManager.default.removeItem(at: tmpURL)
let readFifth = fileState(at: voiceURL)
try? Data("{\"other\": 1}".utf8).write(to: voiceURL)
check((try? discardPrintIfUnchanged(at: voiceURL, readState: readFifth)) == false && FileManager.default.fileExists(atPath: voiceURL.path),
      "discardPrintIfUnchanged: a print changed since it was read is kept")
let readSixth = fileState(at: voiceURL)
check((try? discardPrintIfUnchanged(at: voiceURL, readState: readSixth)) == true && !FileManager.default.fileExists(atPath: voiceURL.path),
      "discardPrintIfUnchanged: an unchanged print is removed")
try? FileManager.default.removeItem(at: folder)

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
