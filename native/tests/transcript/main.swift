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
// Gate A, 13 November: a word with no candidate takes its sentence's label when the sentence's words with
// exactly one candidate label all hold the same label (spec 6.2, step 4); otherwise the fallback, as before.
// Checked before smoothing, and with the words that have no candidate as a run too long to smooth.
let fillWords = spread("so we will look at the numbers tomorrow.", 0, 8)
check(resolve(fillWords, [["A"], ["A"], ["A"], ["A"], [], [], [], []], names: ab, fallback: "Unknown") == Array(repeating: "Me", count: 8),
      "resolve: words with no candidate in a sentence whose single-label words are all Me are Me, on a side with Me and Room 1")
check(resolve(fillWords, [["A"], ["A"], ["B"], ["B"], [], [], [], []], names: ab, fallback: "Unknown")
      == ["Me", "Me", "Room 1", "Room 1", "Unknown", "Unknown", "Unknown", "Unknown"],
      "resolve: words with no candidate in a sentence whose single-label words hold Me and Room 1 keep the fallback")
check(resolve(fillWords, [[], [], ["A", "B"], [], [], [], [], []], names: ab, fallback: "Unknown")
      == ["Unknown", "Unknown", "Room 1", "Unknown", "Unknown", "Unknown", "Unknown", "Unknown"],
      "resolve: words with no candidate in a sentence with no single-label word keep the fallback")
check(resolve(fillWords, [["T2"], ["T2"], ["T2"], ["T2"], [], [], [], []], names: ["T1": "Them 1", "T2": "Them 2"], fallback: "Them")
      == Array(repeating: "Them 2", count: 8),
      "resolve: on the call side, words with no candidate in a sentence held by Them 2 are Them 2, not plain Them")

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
check(nameCall([sp("P", seconds: 300, median: 4, vector: at(0.5)), t1, t3], keptWords: ["P": 30, "T1": 40, "T3": 30],
               firstWord: ["P": 0, "T1": 9, "T3": 5], userVoice: [], print: usable, counted: true)
      == ["P": "Them", "T1": "Them 2", "T3": "Them 1"],
      "nameCall: with a call count, the 0.45 print test still applies (review finding 3)")

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
// Gate A, 13 November: on the microphone side only a share under 5% makes a voice Unknown for size; the
// call side's median segment test is not used there, as people in a room talk in quick turns.
check(micNamed([sp("A", vector: e1), sp("B", median: 2.4, vector: e2), sp("C", vector: e3)], ["A": 90, "B": 6, "C": 4])
      == ["A": "Room 1", "B": "Room 2", "C": "Unknown"],
      "nameMic: without a count, under 5% is Unknown, and a median under 2.5 s is still numbered")
let quickTurns = sp("Q", median: 1.8, vector: e2)
check(micNamed([sp("A", vector: e1), quickTurns], ["A": 19, "Q": 1]) == ["A": "Room 1", "Q": "Room 2"],
      "nameMic: without a count, exactly 5% of the kept words with a 1.8 s median is numbered (the share test is inclusive)")
check(micNamed([sp("A", vector: e1), quickTurns], ["A": 20, "Q": 1]) == ["A": "Room 1", "Q": "Unknown"],
      "nameMic: without a count, under 5% of the kept words is still Unknown")
check(nameCall([t1, sp("T2", seconds: 60, median: 1.8, vector: e4)], keptWords: ["T1": 80, "T2": 20], firstWord: ["T1": 0, "T2": 30],
               userVoice: [], print: nil, counted: false) == ["T1": "Them", "T2": "Them"],
      "nameCall: the call side keeps the median test: 20% with a 1.8 s median is plain Them")

// --- the voice print ---
check(usablePrint(vp(seconds: 59.9), model: model) == nil && usablePrint(vp(meetings: 1), model: model) == nil
      && usablePrint(vp(model: "other@1"), model: model) == nil,
      "usablePrint: under 60 s, from 1 meeting without a sample, or from another model is unusable")
check(usablePrint(vp(seconds: 75, meetings: 1, sources: [], sample: true), model: model) != nil && usablePrint(vp(seconds: 60), model: model) != nil,
      "usablePrint: 75 s from 1 meeting with sample true is usable, and so is 60 s from 2")
let oldPrint = try? decodePrint(fixtureData("voice-old.json"))
check(oldPrint?.sample == false && oldPrint?.refusals == 0 && oldPrint?.meetings == 2 && oldPrint?.seconds == 75,
      "decodePrint: a voice.json without sample or refusals reads them as false and 0")
check(oldPrint?.refused == [], "decodePrint: a voice.json without refused reads it as no refused meetings")
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
// A tie: as many shared words later on each side, so the microphone speaker cannot be told.
let tieMic = [shared[0], shared[1], sharedLater[2], sharedLater[3]], tieCall = [sharedLater[0], sharedLater[1], shared[2], shared[3]]
let tie = pairVoices(mic: [micE], call: [callC], pairs: (0..<4).map { (micWord: $0, callWord: $0) }, micWords: tieMic, callWords: tieCall,
                     micCandidates: Array(repeating: ["E"], count: 4), callCandidates: Array(repeating: ["C"], count: 4), print: nil)
check(tie.micUnknown == ["E"] && tie.micEcho.isEmpty && tie.callEcho.isEmpty,
      "pairVoices: as many shared words later on each side makes the microphone speaker Unknown")
// A weaker pairing never makes Unknown a speaker another pairing shows to be echo, or the source of the
// call side's echo: C2 is like E and U too, but shares no words with either.
let callC2 = sp("C2", vector: [0, 0, 0.8, 0.6])
let echoAndNone = pairVoices(mic: [sp("E", vector: e3)], call: [callC, callC2], pairs: fivePairs, micWords: sharedLater, callWords: shared,
                             micCandidates: micE5, callCandidates: callC5, print: nil)
check(echoAndNone.micEcho == ["E"] && echoAndNone.micUnknown.isEmpty,
      "pairVoices: a speaker shown to be echo is not made Unknown by a pairing with no shared words")
let sourceAndNone = pairVoices(mic: [sp("E", vector: e3)], call: [callC, callC2], pairs: fivePairs, micWords: shared, callWords: sharedLater,
                               micCandidates: micE5, callCandidates: callC5, print: nil)
check(sourceAndNone.callEcho == ["C"] && sourceAndNone.micUnknown.isEmpty && sourceAndNone.micEcho.isEmpty,
      "pairVoices: the source of the call side's echo is not made Unknown by a pairing with no shared words")
// The share test's clauses (Gate A, 13 November): a copy is a microphone word whose copy counts as the
// later, the share is over the words whose sole candidate is the speaker, and a speaker with no such
// words passes. E and C are one voice (e3); microphone word k is "m<k>" at k s, paired with call word k.
let shareE = sp("E", vector: e3), shareC = sp("C", vector: e3), shareU = sp("U", vector: e1)
func shareVote(_ micCandidates: [[String]], callShift: [Double]) -> Set<String> {
    let micWords = micCandidates.indices.map { w(Double($0), Double($0) + 0.3, "m\($0)") }
    let callWords = callShift.enumerated().map { k, d in w(Double(k) + d, Double(k) + d + 0.3, "m\(k)") }
    return pairVoices(mic: [shareU, shareE], call: [shareC], pairs: callShift.indices.map { (micWord: $0, callWord: $0) },
                      micWords: micWords, callWords: callWords, micCandidates: micCandidates,
                      callCandidates: Array(repeating: ["C"], count: callShift.count), print: nil).micEcho
}
check(shareVote(Array(repeating: ["E"], count: 10), callShift: [-0.3, -0.3, -0.3, -0.3, 0.3, 0.3]).isEmpty,
      "pairVoices: a shared word whose call copy is later by a round trip is no copy: with a vote of 4 to 2, only 4 of E's 10 "
      + "words are copies, so E is no leak")
check(shareVote(Array(repeating: ["E"], count: 10) + Array(repeating: ["U", "E"], count: 4), callShift: Array(repeating: -0.3, count: 5)) == ["E"],
      "pairVoices: the share is over the words whose sole candidate is E: 5 copies of its 10, not of 14 with the 4 it shares "
      + "with U, so E is the leak")
check(shareVote(Array(repeating: ["U", "E"], count: 5), callShift: Array(repeating: -0.3, count: 5)) == ["E"],
      "pairVoices: a speaker with no word whose sole candidate it is passes the share test, so the vote alone makes E the leak")

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
// The same, with the far side's segment overlapping the user's voice coming back (review finding 1): a
// call word with both candidates that repeats a microphone word later is the user's voice, so no word
// of the user's is cancelled, and none moves to the call side as Them or Unknown.
for farStart in [12.0, 10.0] {
    let overlap = labelWords(mic: mineToShip, call: Array(repeated.prefix(8)) + farReply,
                             micSpeakers: side([Segment(speaker: "U", start: 9.8, end: 13.5), Segment(speaker: "U", start: 39.8, end: 42)],
                                               [sp("U", seconds: 45, vector: at(0.9))]),
                             callSpeakers: side([Segment(speaker: "P", start: 10.1, end: 13.8), Segment(speaker: "T", start: farStart, end: 22)],
                                                [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                             print: usable)
    check(overlap.mic.count == 13 && overlap.micLabels.allSatisfy { $0 == "Me" } && overlap.call.map(\.text) == farReply.map(\.text)
          && overlap.callLabels.allSatisfy { $0 == "Them" } && overlap.log.contains { $0.hasPrefix("Your voice was heard on the call side") },
          "labelWords: with a far-side segment from \(farStart) s overlapping the user's voice coming back, all 13 Me words stay Me "
          + "and nothing moves to Them or Unknown (\(overlap.mic.count) \(overlap.call.map(\.text)) \(overlap.callLabels) \(overlap.log))")
}
// Real echo is still dropped where the segments overlap: the far side's words leak into the microphone
// (the microphone copy is later) while the user's voice coming back overlaps them on the call side.
let farTalk = said("we should look at the numbers again before friday.", from: 20)
let leakedIntoMic = farTalk.map { w($0.start + 0.3, $0.end + 0.3, $0.text) }
let overlapLeak = labelWords(mic: mineFirst + leakedIntoMic + mineLast, call: farTalk,
                             micSpeakers: side([Segment(speaker: "U", start: 0, end: 32.5)], [sp("U", seconds: 30, vector: at(0.9))]),
                             callSpeakers: side([Segment(speaker: "P", start: 19.5, end: 24), Segment(speaker: "T", start: 19.8, end: 24)],
                                                [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                             print: usable)
check(overlapLeak.mic.count == 10 && overlapLeak.micLabels.allSatisfy { $0 == "Me" } && overlapLeak.call.count == 9,
      "labelWords: where the user's voice and the far side overlap on the call side, far-side words heard later on the microphone "
      + "are still dropped as echo (\(overlapLeak.mic.count) \(overlapLeak.call.count))")

// Fix rounds 2 and 3: "later" means later by a real round trip (Rule.returnLag), judged word by word on
// each call word's own pair in the alignment of both whole sides. A leak through the speakers lags its
// call copy by tens of milliseconds, inside a transcriber's timing jitter; a voice coming back lags by
// 150 ms or more.
func heardLine(_ l: LabelledWords) -> Bool { l.log.contains { $0.hasPrefix("Your voice was heard on the call side") } }
let overlapCall = side([Segment(speaker: "P", start: 19.5, end: 24), Segment(speaker: "T", start: 19.8, end: 24)],
                       [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)])
let userMic = side([Segment(speaker: "U", start: 0, end: 32.5)], [sp("U", seconds: 45, vector: at(0.9))])
// Case G: the far side leaks into the microphone a few hundredths of a second either side of its call copy.
for shiftOnMic in [-0.08, -0.03, -0.01, 0, 0.03, 0.08] {
    let leak = farTalk.map { w($0.start + shiftOnMic, $0.end + shiftOnMic, $0.text) }
    let g = labelWords(mic: mineFirst + leak + mineLast, call: farTalk, micSpeakers: userMic, callSpeakers: overlapCall, print: usable)
    check(g.mic.count == 10 && g.micLabels.allSatisfy { $0 == "Me" } && g.call.map(\.text) == farTalk.map(\.text)
          && g.callLabels.allSatisfy { $0 == "Them" } && !heardLine(g),
          "labelWords (case G): a far-side leak \(shiftOnMic) s from its call copy, inside a P and T overlap, is dropped, the far side "
          + "stays Them, and no 'voice was heard' line (\(g.mic.count) \(g.call.count) \(g.callLabels) \(g.log))")
}
// The same far side with leak lags alternating +0.03 and -0.03 s, word by word: no false log line.
let alternating = farTalk.enumerated().map { k, x in w(x.start + (k % 2 == 0 ? 0.03 : -0.03), x.end + (k % 2 == 0 ? 0.03 : -0.03), x.text) }
let g2 = labelWords(mic: mineFirst + alternating + mineLast, call: farTalk, micSpeakers: userMic, callSpeakers: overlapCall, print: usable)
check(g2.mic.count == 10 && g2.callLabels == Array(repeating: "Them", count: 9) && !heardLine(g2),
      "labelWords: a leak with lags alternating +0.03 and -0.03 s logs no 'voice was heard' line, as none was (\(g2.log))")
// Case B: the far side says "yes yes", the second "yes" overlapping the user's voice coming back; both leak
// into the microphone 0.3 s later.
let micYes = said("hello everyone thanks for joining.", from: 0) + [w(19.8, 20.1, "yes"), w(20.5, 20.8, "yes")] + said("right let us go on.", from: 30)
let callYes = said("hello everyone thanks for joining.", from: 0.3) + [w(19.5, 19.8, "yes"), w(20.2, 20.5, "yes")]
let yesYes = labelWords(mic: micYes, call: callYes, micSpeakers: side([Segment(speaker: "U", start: 0, end: 33)], [sp("U", seconds: 40, vector: at(0.9))]),
                        callSpeakers: side([Segment(speaker: "P", start: 0.2, end: 2.5), Segment(speaker: "P", start: 20.0, end: 20.6),
                                            Segment(speaker: "T", start: 19.4, end: 24)],
                                           [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                        print: usable)
check(yesYes.mic.count == micYes.count - 2 && !yesYes.mic.contains { $0.text == "yes" } && yesYes.micLabels.allSatisfy { $0 == "Me" }
      && yesYes.call.map(\.text) == ["yes", "yes"] && yesYes.callLabels == ["Them", "Them"],
      "labelWords (case B): the far side's leaked 'yes yes' is dropped, and both its 'yes' words stay Them (\(yesYes.call.map(\.text)) \(yesYes.callLabels))")
// The user's voice coming back about 0.15 s and 0.3 s later inside a P and T overlap, each copy jittered
// on its own but none stamped under Rule.returnLag: every user word stays Me, and the copies are dropped
// as repeats. (Fix round 3: these checks used to stamp two copies 0.05 s early, which only a median over
// runs could carry; a copy stamped under the margin is now the documented boundary below.)
let jitterLags = [0.15, 0.13, 0.20, 0.12, 0.17, 0.14, 0.15, 0.12]
func returningOverlap(_ lags: [Double], pEnd: Double) -> LabelledWords {
    let back = said("I think we can ship it on monday.", from: 10).enumerated().map { k, x in w(x.start + lags[k], x.end + lags[k], x.text) }
    return labelWords(mic: mineToShip, call: back + farReply,
                      micSpeakers: side([Segment(speaker: "U", start: 9.8, end: 13.5), Segment(speaker: "U", start: 39.8, end: 42)],
                                        [sp("U", seconds: 45, vector: at(0.9))]),
                      callSpeakers: side([Segment(speaker: "P", start: 9.9, end: pEnd), Segment(speaker: "T", start: 9.5, end: 22)],
                                         [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                      print: usable)
}
for (returning, lags) in [(0.15, jitterLags), (0.3, jitterLags.map { $0 + 0.15 })] {
    let jittered = returningOverlap(lags, pEnd: 13.8 + returning)
    check(jittered.mic.count == 13 && jittered.micLabels.allSatisfy { $0 == "Me" } && jittered.call.map(\.text) == farReply.map(\.text)
          && jittered.callLabels.allSatisfy { $0 == "Them" },
          "labelWords: a voice coming back about \(returning) s later, every copy jittered but none under the margin, leaves every "
          + "user word Me and the far reply Them (\(jittered.mic.count) \(jittered.call.map(\.text)))")
}
// The margin is judged per word (fix round 3). In the same layout, with every other copy 0.3 s later, a
// copy stamped exactly Rule.returnLag later is the user's voice; one stamped 0.10 s later stays in echo
// removal and cancels its microphone word, which is the documented boundary (a returning voice stamped
// under the margin counts as leakage). That word's call copy stays on the call side, and no other word
// moves.
let atMargin = returningOverlap([0.3, 0.3, 0.3, 0.3, Rule.returnLag, 0.3, 0.3, 0.3], pEnd: 14.1)
check(atMargin.mic.count == 13 && atMargin.micLabels.allSatisfy { $0 == "Me" } && atMargin.call.map(\.text) == farReply.map(\.text)
      && atMargin.callLabels.allSatisfy { $0 == "Them" },
      "labelWords: a returning copy stamped exactly Rule.returnLag after its microphone word is the user's voice, so all 13 stay Me "
      + "(\(atMargin.mic.count) \(atMargin.call.map(\.text)))")
let underMargin = returningOverlap([0.3, 0.3, 0.3, 0.3, 0.10, 0.3, 0.3, 0.3], pEnd: 14.1)
check(underMargin.mic.count == 12 && !underMargin.mic.contains { $0.text == "ship" } && underMargin.micLabels.allSatisfy { $0 == "Me" }
      && underMargin.call.map(\.text) == ["ship"] + farReply.map(\.text),
      "labelWords (documented boundary): a returning copy stamped 0.10 s after its microphone word stays in echo removal and cancels "
      + "only that word, while its neighbours, judged by their own pairs, stay Me (\(underMargin.mic.map(\.text)) \(underMargin.call.map(\.text)))")
// Both say "okay" at once: the user's at 10.0, the far side's at 10.3 on the call side (in the overlap with
// the user's voice coming back), leaking into the microphone at 10.32. A documented boundary (fix round 3):
// the alignment of both whole sides pairs the far side's "okay" with the user's, 0.3 s earlier, so it is
// taken for the user's voice coming back and dropped as a repeat, and its leak at 10.32 stays on the
// microphone as Me. No word of the user's is lost and the far reply stays Them; the log counts that
// "okay" as 1 word repeating the user's, although none came back.
let okays = labelWords(mic: said("okay.", from: 10.0) + said("okay.", from: 10.32) + mineLast, call: said("okay.", from: 10.3) + farReply,
                       micSpeakers: side([Segment(speaker: "U", start: 9.8, end: 11.0), Segment(speaker: "U", start: 29.8, end: 32.5)],
                                         [sp("U", seconds: 45, vector: at(0.9))]),
                       callSpeakers: side([Segment(speaker: "P", start: 10.1, end: 10.9), Segment(speaker: "T", start: 10.2, end: 22)],
                                          [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
check(okays.call.map(\.text) == farReply.map(\.text) && okays.callLabels.allSatisfy { $0 == "Them" }
      && okays.mic.filter { $0.text == "okay." }.map(\.start) == [10.0, 10.32] && okays.micLabels.allSatisfy { $0 == "Me" },
      "labelWords (documented boundary): when both say 'okay' at once, the far side's 'okay' 0.3 s after the user's is taken for the "
      + "user's voice and dropped, both microphone 'okay' words stay Me, and the far reply stays Them (\(okays.call.map(\.text)) "
      + "\(okays.mic.map(\.text)) \(okays.log))")
// pairVoices with a systematic +0.03 s offset between the sides (the microphone stamped early), on a far-side
// leak cluster and no print: still echo, not the user's voice; the user stays Me and the far side Them.
let farLong = said("we should look at the numbers again before friday.", from: 20) + said("and the budget for next quarter too.", from: 26)
let early = farLong.map { w($0.start - 0.03, $0.end - 0.03, $0.text) }
let leakE = sp("E", seconds: 12, vector: [0, 0, 0.9, 0.436])
let offset = labelWords(mic: said("hello everyone thanks for joining.", from: 0) + early + said("yes let us do that.", from: 30), call: farLong,
                        micSpeakers: side([Segment(speaker: "U", start: 0, end: 2.5), Segment(speaker: "E", start: 19.9, end: 29),
                                           Segment(speaker: "U", start: 29.8, end: 32.5)], [sp("U", seconds: 5, vector: e1), leakE]),
                        callSpeakers: side([Segment(speaker: "T", start: 19.8, end: 29)], [sp("T", seconds: 30, vector: e3)]), print: nil)
check(offset.mic.count == 10 && offset.micLabels.allSatisfy { $0 == "Me" } && offset.call.count == farLong.count
      && offset.callLabels.allSatisfy { $0 == "Them" } && !heardLine(offset),
      "labelWords: a far-side leak cluster stamped 0.03 s before its call copy is still echo: the user stays Me, the far side Them "
      + "(\(offset.micLabels) \(offset.call.count) \(offset.log))")
let offsetPairs = (0..<5).map { (micWord: $0, callWord: $0) }
let earlyMic = shared.map { w($0.start - 0.03, $0.end - 0.03, $0.text) }
let offsetVote = pairVoices(mic: [micE], call: [callC], pairs: offsetPairs, micWords: earlyMic, callWords: shared,
                           micCandidates: micE5, callCandidates: callC5, print: nil)
check(offsetVote.micEcho == ["E"] && offsetVote.callEcho.isEmpty,
      "pairVoices: shared words with the call copy only 0.03 s later count as later on the microphone side (echo)")

// Changes of turn with both the user's voice coming back (P, or C found by pairVoices) and the far side
// leaking into the microphone (fix round 3, from the round 3 benchmark's spec cases). The user's returning
// copies lag by 0.3 s and the leak by 0 to 0.03 s, and P's and T's segments overlap where the turn
// changes, so both voices' words are mixed there. Each is judged by its own pair: the user's 13 words stay
// Me, no leaked word is kept on the microphone, and the far side's words stay Them on the call side.
func shifted(_ words: [Word], _ d: Double) -> [Word] { words.map { w($0.start + d, $0.end + d, $0.text) } }
func wordKey(_ x: Word) -> String { "\(x.start.bitPattern)|\(x.text)" }
/// How many of `words` (same start, same text) `out` kept, counting only those whose label is `label` or
/// starts with `prefix` when given.
func keptCount(_ words: [Word], in out: [Word], _ labels: [String], label: String? = nil, prefix: String? = nil) -> Int {
    let want = Set(words.map(wordKey))
    return zip(out, labels).filter { x, l in
        want.contains(wordKey(x)) && (label.map { l == $0 } ?? true) && (prefix.map { l.hasPrefix($0) } ?? true)
    }.count
}
/// N in the log's "Your voice was heard on the call side: N words repeating yours ..." line.
func repeatCount(_ l: LabelledWords) -> Int? {
    guard let line = l.log.first(where: { $0.hasPrefix("Your voice was heard on the call side") }),
          let colon = line.range(of: ": ") else { return nil }
    return Int(line[colon.upperBound...].prefix { $0.isNumber })
}
let userTurn = "I think we can ship it on monday."
let laterTurn = said("and then we test it.", from: 40)
let shortReply = "sounds good to me.", longReply = "sounds good to me but we should check the numbers with finance first."
// T1, T2 and T5: the user's sentence, then the far side's reply `gap` after its last word, leaking `leak`
// later on the microphone; P runs `pAfter` past the last returning copy and T starts `tBefore` before the reply.
func turnChange(_ name: String, reply: String, gap: Double, leak: Double, pAfter: Double, tBefore: Double, noPrint: Bool = false,
                repeats: Int?) {
    let u = said(userTurn, from: 10)
    let replyStart = u.last!.start + gap
    let rw = said(reply, from: replyStart)
    let leaked = shifted(rw, leak)
    let micSp = side([Segment(speaker: "U", start: 9.8, end: rw.last!.start + 2), Segment(speaker: "U", start: 39.8, end: 42)],
                     [sp("U", seconds: 45, vector: noPrint ? e1 : at(0.9))])
    let callSp = side([Segment(speaker: noPrint ? "C" : "P", start: 10.2, end: u.last!.start + 0.3 + pAfter),
                       Segment(speaker: "T", start: replyStart - tBefore, end: rw.last!.start + 2)],
                      [noPrint ? sp("C", seconds: 8, vector: [0.8, 0.6, 0, 0]) : sp("P", seconds: 8, vector: at(0.75)),
                       sp("T", seconds: 30, vector: e3)])
    let r = labelWords(mic: u + leaked + laterTurn, call: shifted(u, 0.3) + rw, micSpeakers: micSp, callSpeakers: callSp,
                       print: noPrint ? nil : usable)
    check(keptCount(u + laterTurn, in: r.mic, r.micLabels, label: "Me") == 13 && keptCount(leaked, in: r.mic, r.micLabels) == 0
          && keptCount(rw, in: r.call, r.callLabels, prefix: "Them") == rw.count && (repeats == nil || repeatCount(r) == repeats),
          "labelWords (\(name)): at a change of turn the user's 13 words stay Me, no leaked word is kept, the far reply's \(rw.count) "
          + "words stay Them\(repeats.map { ", and the log counts \($0) repeats" } ?? "") (\(r.mic.map(\.text)) \(r.call.map(\.text)) "
          + "\(r.callLabels) \(r.log))")
}
for leak in [0.0, 0.03] {
    turnChange("T1, leak +\(leak) s", reply: shortReply, gap: 0.8, leak: leak, pAfter: 1.4, tBefore: 0.1, repeats: 8)
}
turnChange("T2, a long reply 0.4 s after", reply: longReply, gap: 0.4, leak: 0, pAfter: 0.4, tBefore: 0.3, repeats: nil)
turnChange("T5, no print, the returning voice found by pairVoices", reply: shortReply, gap: 0.8, leak: 0, pAfter: 1.4, tBefore: 0.1,
           noPrint: true, repeats: 8)
// T3: a long user sentence with the far side's "yeah sure." inside P's tail, leaking.
do {
    let u = said("I think we can ship it on monday if the tests pass tonight.", from: 10)
    let reply = said("yeah sure.", from: 15.3)
    let r = labelWords(mic: u + reply + laterTurn, call: shifted(u, 0.3) + reply,
                       micSpeakers: side([Segment(speaker: "U", start: 9.8, end: 17), Segment(speaker: "U", start: 39.8, end: 42)],
                                         [sp("U", seconds: 45, vector: at(0.9))]),
                       callSpeakers: side([Segment(speaker: "P", start: 10.2, end: 16.0), Segment(speaker: "T", start: 15.2, end: 17)],
                                          [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
    check(keptCount(u + laterTurn, in: r.mic, r.micLabels, label: "Me") == 18 && keptCount(reply, in: r.mic, r.micLabels) == 0
          && keptCount(reply, in: r.call, r.callLabels, prefix: "Them") == 2 && repeatCount(r) == 13,
          "labelWords (T3): the far side's 'yeah sure.' inside P's tail, leaking, stays Them and is dropped from the microphone, "
          + "the user's 18 words stay Me, and the log counts 13 repeats (\(r.mic.map(\.text)) \(r.call.map(\.text)) \(r.log))")
}
// T4: the user's "yes that works." between two far-side stretches that leak, with T spanning the whole stretch.
for leak in [0.0, 0.03] {
    let far1 = said("we should look at the numbers again before friday", from: 20)
    let user = said("yes that works.", from: 23.8)
    let far2 = said("and then send them to the finance team next week.", from: 25.2)
    let hello = said("hello everyone thanks for joining.", from: 0)
    let leaked = shifted(far1, leak) + shifted(far2, leak)
    let r = labelWords(mic: hello + leaked + user, call: far1 + shifted(user, 0.3) + far2,
                       micSpeakers: side([Segment(speaker: "U", start: 0, end: 30)], [sp("U", seconds: 45, vector: at(0.9))]),
                       callSpeakers: side([Segment(speaker: "T", start: 19.8, end: 29.5), Segment(speaker: "P", start: 24.0, end: 25.2)],
                                          [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
    check(keptCount(hello + user, in: r.mic, r.micLabels, label: "Me") == 8 && keptCount(leaked, in: r.mic, r.micLabels) == 0
          && keptCount(far1 + far2, in: r.call, r.callLabels, prefix: "Them") == 19 && repeatCount(r) == 3,
          "labelWords (T4, leak +\(leak) s): the user's short reply inside a far-side stretch stays Me, the far side's 19 words stay "
          + "Them, no leaked word is kept, and the log counts 3 repeats (\(r.mic.map(\.text)) \(r.call.map(\.text)) \(r.log))")
}
// Round 2's boundary layouts: forward (the user, then the far side's reply) and reverse (the far side, then
// the user), with the user's voice coming back 0.3 s later.
let reverseFar = "sounds good to me but we should check the numbers again first."
for (leak, gap) in [(0.0, 0.8), (0.03, 0.5)] {
    let user = said(userTurn, from: 10)
    let back = shifted(user, 0.3)
    let replyStart = user.last!.start + gap
    let reply = said(shortReply, from: replyStart)
    let leaked = shifted(reply, leak)
    let r = labelWords(mic: user + leaked, call: back + reply,
                       micSpeakers: side([Segment(speaker: "U", start: 9.8, end: replyStart + 6)], [sp("U", seconds: 45, vector: at(0.9))]),
                       callSpeakers: side([Segment(speaker: "P", start: 10.1, end: back.last!.end + 0.6),
                                           Segment(speaker: "T", start: replyStart - 0.1, end: replyStart + 6)],
                                          [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
    check(keptCount(user, in: r.mic, r.micLabels, label: "Me") == 8 && keptCount(leaked, in: r.mic, r.micLabels) == 0
          && keptCount(reply, in: r.call, r.callLabels, prefix: "Them") == reply.count,
          "labelWords (forward, leak +\(leak) s, reply \(gap) s after): the user's 8 words stay Me, no leaked word is kept, and the "
          + "far reply stays Them (\(r.mic.map(\.text)) \(r.call.map(\.text)) \(r.callLabels))")
}
for leak in [0.0, 0.03] {
    let far = said(reverseFar, from: 5)
    let leaked = shifted(far, leak)
    let userStart = far.last!.start + 0.8
    let user = said(userTurn, from: userStart)
    let back = shifted(user, 0.3)
    let r = labelWords(mic: leaked + user, call: far + back,
                       micSpeakers: side([Segment(speaker: "U", start: 4.5, end: userStart + 5)], [sp("U", seconds: 45, vector: at(0.9))]),
                       callSpeakers: side([Segment(speaker: "T", start: 4.8, end: back.first!.start + 0.9),
                                           Segment(speaker: "P", start: back.first!.start - 0.2, end: back.last!.end + 0.3)],
                                          [sp("P", seconds: 8, vector: at(0.75)), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
    check(keptCount(user, in: r.mic, r.micLabels, label: "Me") == 8 && keptCount(leaked, in: r.mic, r.micLabels) == 0
          && keptCount(far, in: r.call, r.callLabels, prefix: "Them") == far.count,
          "labelWords (reverse, a long far turn, leak +\(leak) s): the user's 8 words stay Me, no leaked word is kept, and the far "
          + "side's \(far.count) words stay Them (\(r.mic.map(\.text)) \(r.call.map(\.text)) \(r.callLabels))")
}

// Gate A, 13 November (spec 6.2 as changed in b929871).
func leftOut(_ l: LabelledWords) -> String? { l.log.first { $0.hasPrefix("Left out") } }
let gateUser = said("hello everyone thanks for joining.", from: 0) + said("yes let us do that.", from: 30)
let gateUserSegments = [Segment(speaker: "U", start: 0, end: 2.5), Segment(speaker: "U", start: 29.8, end: 32.5)]
let gateU = sp("U", seconds: 45, vector: at(0.9))
// A person in the room whose voice is like a small far-side voice (R at 0.80 with F2, neither the print's):
// 4 of R's 40 words are echo-paired with F2's, the microphone copy 0.3 s later. Only those 4 go; R is
// named, and nothing is left out as the call heard through the speakers.
do {
    var texts = (0..<40).map { "room\($0)" }
    texts.replaceSubrange(10..<14, with: ["budget", "review", "next", "week"])
    texts[39] += "."
    let rWords = said(texts.joined(separator: " "), from: 5)
    let farSmall = Array(shifted(Array(rWords[10..<14]), -0.3))
    let farMain = said("we should look at the numbers again before friday.", from: 40)
    let r = labelWords(mic: gateUser + rWords, call: farSmall + farMain,
                       micSpeakers: side(gateUserSegments + [Segment(speaker: "R", start: 4.8, end: 21.2)],
                                         [gateU, sp("R", seconds: 16, vector: e4)]),
                       callSpeakers: side([Segment(speaker: "F2", start: 8.6, end: 10.2), Segment(speaker: "T", start: 39.8, end: 44)],
                                          [sp("F2", seconds: 2, vector: [0, 0, 0.6, 0.8]), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
    let others = Array(rWords[0..<10]) + Array(rWords[14...])
    check(keptCount(others, in: r.mic, r.micLabels, label: "Room 1") == 36 && keptCount(Array(rWords[10..<14]), in: r.mic, r.micLabels) == 0
          && keptCount(gateUser, in: r.mic, r.micLabels, label: "Me") == 10 && leftOut(r) == nil,
          "labelWords (Gate A, G): a room voice like a far-side voice, with 4 of its 40 words copies, keeps its other 36 words as "
          + "Room 1, loses only the 4, and nothing is left out as the call (\(r.mic.count) \(Set(r.micLabels)) \(r.log))")
}
// The share boundary (Rule.leakShare, inclusive): a leak cluster L of 10 words whose sole candidate is L,
// k of them copies of the far side's words 0.3 s later. With 5 copies it is the far side leaking, so all
// 10 go and the log counts the 5 left; with 4 it is a person in the room: only the 4 go, and the other 6
// are named.
let farSays10 = said("we should look at the numbers again before friday.", from: 20)
let leakVoice = sp("L", seconds: 6, vector: [0, 0, 0.7, (1 - 0.49).squareRoot()])
for copies in [5, 4] {
    let copied = shifted(Array(farSays10.prefix(copies)), 0.3)
    let own = said(Array(["something", "else", "entirely", "here", "and", "there."].suffix(10 - copies)).joined(separator: " "), from: 23.5)
    let r = labelWords(mic: gateUser + copied + own, call: farSays10,
                       micSpeakers: side(gateUserSegments + [Segment(speaker: "L", start: 20.2, end: 26)], [gateU, leakVoice]),
                       callSpeakers: side([Segment(speaker: "C", start: 19.8, end: 24)], [sp("C", seconds: 30, vector: e3)]),
                       print: usable)
    let userMe = keptCount(gateUser, in: r.mic, r.micLabels, label: "Me") == 10 && r.mic.count == (copies == 5 ? 10 : 16)
    if copies == 5 {
        check(userMe && keptCount(copied + own, in: r.mic, r.micLabels) == 0 && leftOut(r)?.hasPrefix("Left out 5 microphone words") == true,
              "labelWords: a paired voice with 5 of its 10 words copies is the far side leaking: all 10 go and the log counts the "
              + "5 left (\(r.mic.map(\.text)) \(r.log))")
    } else {
        check(userMe && keptCount(copied, in: r.mic, r.micLabels) == 0 && keptCount(own, in: r.mic, r.micLabels, label: "Room 1") == 6
              && leftOut(r) == nil,
              "labelWords: a paired voice with 4 of its 10 words copies is a person in the room: only the 4 go, the other 6 are "
              + "Room 1, and nothing is left out (\(r.mic.map(\.text)) \(r.micLabels) \(r.log))")
    }
}
// The copies count against any call word: L's 6 copies are of two far voices, C1 (at 0.70 with L, so
// paired) and C2 (unlike L). 6 of 10 is the leak, though only 3 are shared with the voice it is paired with.
do {
    let c1 = said("we should look at the numbers again before friday.", from: 20)
    let c2 = said("and the budget for next quarter too.", from: 26)
    let copied = shifted(Array(c1.prefix(3)), 0.3) + shifted(Array(c2.prefix(3)), 0.3)
    let own = said("something else entirely here.", from: 28.0)
    let r = labelWords(mic: gateUser + copied + own, call: c1 + c2,
                       micSpeakers: side(gateUserSegments + [Segment(speaker: "L", start: 20.2, end: 29.6)], [gateU, leakVoice]),
                       callSpeakers: side([Segment(speaker: "C1", start: 19.8, end: 24), Segment(speaker: "C2", start: 25.8, end: 29)],
                                          [sp("C1", seconds: 30, vector: e3), sp("C2", seconds: 10, vector: e2)]),
                       print: usable)
    check(keptCount(gateUser, in: r.mic, r.micLabels, label: "Me") == 10 && r.mic.count == 10
          && leftOut(r)?.hasPrefix("Left out 4 microphone words") == true,
          "labelWords: a voice's copies of any call speaker's words count towards its share, so 6 of 10 (3 of them of a far voice "
          + "it is not paired with) is the leak (\(r.mic.map(\.text)) \(r.log))")
}
// The leak itself still goes: see "an echo cluster's 3 remaining words are dropped" above (9 of its 12
// words are copies) and the leak cluster stamped 0.03 s early (all 16 are).

// A room recording without a count: the other person talks in quick turns (a 1.8 s median) and holds 20%
// of the kept words. Room 1, not Unknown.
do {
    let mine = said("hello everyone thanks for joining.", from: 0) + said("we can begin with the numbers now.", from: 6)
        + said("yes let us go.", from: 14)
    let theirs = said("shall we start then.", from: 3)
    let r = labelWords(mic: mine + theirs, call: [],
                       micSpeakers: side([Segment(speaker: "U", start: 0, end: 2.2), Segment(speaker: "A", start: 2.8, end: 4.8),
                                          Segment(speaker: "U", start: 5.8, end: 9), Segment(speaker: "U", start: 13.8, end: 16)],
                                         [sp("U", seconds: 45, vector: at(0.9)), sp("A", seconds: 8, median: 1.8, vector: e3)]),
                       callSpeakers: nil, print: usable)
    check(keptCount(mine, in: r.mic, r.micLabels, label: "Me") == 16 && keptCount(theirs, in: r.mic, r.micLabels, label: "Room 1") == 4,
          "labelWords (Gate A, I and F): a room voice with 20% of the words and a 1.8 s median is Room 1 (\(r.micLabels))")
}

// Words with no candidate (more than 1.0 s from every segment) take their sentence's label when its
// single-label words hold one. The runs of them after single-label words are four words long, so smoothing
// cannot give the label; "okay then." is a sentence of its own, which smoothing leaves as it is.
do {
    let s1Me = said("so we will look at", from: 0), s1Gap = said("the numbers again tomorrow.", from: 3.5)
    let s2Me = said("we can", from: 10), s2Room = said("do that", from: 11.2), s2Gap = said("later on this week.", from: 13.5)
    let s3Room = said("I think that works for me.", from: 20)
    let s4Gap = said("okay then.", from: 30)
    let r = labelWords(mic: s1Me + s1Gap + s2Me + s2Room + s2Gap + s3Room + s4Gap, call: [],
                       micSpeakers: side([Segment(speaker: "U", start: 0, end: 2), Segment(speaker: "U", start: 9.8, end: 10.8),
                                          Segment(speaker: "R", start: 11.0, end: 12.0), Segment(speaker: "R", start: 19.8, end: 22.5)],
                                         [sp("U", seconds: 45, vector: at(0.9)), sp("R", seconds: 20, vector: e3)]),
                       callSpeakers: nil, print: usable)
    check(keptCount(s1Me + s1Gap, in: r.mic, r.micLabels, label: "Me") == 9,
          "labelWords: words with no candidate in a sentence whose single-label words are all Me are Me, though the side "
          + "also has Room 1 (\(r.micLabels))")
    check(keptCount(s2Gap, in: r.mic, r.micLabels, label: "Unknown") == 4 && keptCount(s4Gap, in: r.mic, r.micLabels, label: "Unknown") == 2
          && keptCount(s3Room, in: r.mic, r.micLabels, label: "Room 1") == 6,
          "labelWords: words with no candidate stay Unknown in a sentence held by Me and Room 1, and in one with no "
          + "single-label word (\(r.micLabels))")
}
do {
    let far1 = said("we should look at the numbers again before friday.", from: 20)
    let far2 = said("and then send them", from: 25), far2Gap = said("to the finance team.", from: 28)
    let r = labelWords(mic: said("hello everyone thanks for joining.", from: 0), call: far1 + far2 + far2Gap, micSpeakers: nil,
                       callSpeakers: side([Segment(speaker: "T1", start: 19.8, end: 23.6), Segment(speaker: "T2", start: 24.8, end: 26.6)],
                                          [sp("T1", seconds: 30, vector: e3), sp("T2", seconds: 30, vector: e4)]),
                       print: nil)
    check(keptCount(far1, in: r.call, r.callLabels, label: "Them 1") == 9 && keptCount(far2 + far2Gap, in: r.call, r.callLabels, label: "Them 2") == 8,
          "labelWords: on the call side, words with no candidate in a sentence held by Them 2 are Them 2 (\(r.callLabels))")
}
// The log's "marked Unknown" count is the call-side words labelled Unknown: here the user's voice (P, a
// print match) says 4 words, and the 4 with no candidate in the same sentence take its label too.
do {
    let r = labelWords(mic: said("hello everyone thanks for joining.", from: 0),
                       call: said("can you hear me", from: 10) + said("now okay then fine.", from: 13)
                           + said("we should look at the numbers again before friday.", from: 20),
                       micSpeakers: side([Segment(speaker: "U", start: 0, end: 2.5)], [sp("U", seconds: 45, vector: at(0.9))]),
                       callSpeakers: side([Segment(speaker: "P", start: 9.8, end: 11.5), Segment(speaker: "T", start: 19.8, end: 23.6)],
                                          [sp("P", seconds: 10, vector: at(0.9)), sp("T", seconds: 30, vector: e3)]),
                       print: usable)
    check(r.callLabels.filter { $0 == "Unknown" }.count == 8
          && r.log.contains("Your voice was heard on the call side: 0 words repeating yours were left out, and 8 are marked Unknown"),
          "labelWords: the log's 'marked Unknown' count is every call-side word labelled Unknown, those its sentence gave the "
          + "user's voice included (\(r.callLabels) \(r.log))")
}

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

// --- a recording kept as one file (mb-transcript --one, Task 11A) ---
// U is the user (0.9 with the print). B and A are two other people: A's first segment (5 s) holds no words, so
// by first segment or by id A would come first, but B says the first kept word. X's one segment lies inside a
// word of A's, so X keeps no word of its own. "anyway." at 40 s is more than 1.0 s from every segment.
let oneU = sp("U", seconds: 30, vector: at(0.9)), oneB = sp("B", seconds: 30, vector: e3)
let oneA = sp("A", seconds: 30, vector: e4, first: 5), oneX = sp("X", seconds: 2, vector: e2, first: 21)
let oneWords = said("Right, so the plan is simple.", from: 0) + said("what about the budget?", from: 10)
    + said("I have the numbers here.", from: 20) + [w(40, 40.3, "anyway.")]
let oneSegments = [Segment(speaker: "U", start: 0, end: 3), Segment(speaker: "A", start: 5, end: 6), Segment(speaker: "B", start: 10, end: 12),
                   Segment(speaker: "A", start: 20, end: 22), Segment(speaker: "X", start: 21.0, end: 21.5)]
let oneSide = side(oneSegments, [oneU, oneB, oneA, oneX])
let oneKept: [String: Int] = ["U": 6, "B": 4, "A": 4], oneFirst: [String: Double] = ["U": 0, "B": 10, "A": 20]
check(nameOne([oneU, oneB, oneA, oneX], keptWords: oneKept, firstWord: oneFirst, print: usable, onePerson: false)
      == ["U": "Me", "B": "Speaker 1", "A": "Speaker 2", "X": "Unknown"],
      "nameOne: the print's match is Me; the others are Speaker 1 and 2 by first kept word, with no gap for one that keeps none")
check(nameOne([oneU, oneB, oneA, oneX], keptWords: oneKept, firstWord: oneFirst, print: nil, onePerson: false)
      == ["U": "Speaker 1", "B": "Speaker 2", "A": "Speaker 3", "X": "Unknown"],
      "nameOne: with no usable print, nobody is Me and everyone who keeps a word is numbered from Speaker 1")
func named(_ u: SpeakerInfo) -> String? {
    nameOne([u, oneB], keptWords: ["U": 30, "B": 30], firstWord: ["U": 0, "B": 10], print: usable, onePerson: false)["U"]
}
check(named(sp("U", seconds: 3, vector: at(0.62))) == "Unknown" && named(sp("U", seconds: 9, vector: at(0.62))) == "Unknown",
      "nameOne: a print match of 0.62 with 3 s, or 9 s, of talk is Unknown, never Me (the microphone side's 10 s rule)")
check(named(sp("U", seconds: 10, vector: at(0.62))) == "Me" && named(sp("U", seconds: 10, vector: at(0.6))) == "Me",
      "nameOne: a print match of 0.62, or 0.60, with 10 s of talk is Me")
check(named(sp("U", seconds: 30, vector: at(0.5))) == "Unknown" && named(sp("U", seconds: 30, vector: at(0.59))) == "Unknown"
      && named(sp("U", seconds: 30, vector: at(0.44))) == "Speaker 1",
      "nameOne: a cosine of 0.45 to 0.59 with the print is too near to be anyone else: Unknown; 0.44 is someone else")
check(nameOne([sp("U", seconds: 30, vector: at(0.9)), sp("V", seconds: 12, vector: at(0.7)), oneB], keptWords: ["U": 20, "V": 10, "B": 20],
              firstWord: ["U": 0, "V": 5, "B": 10], print: usable, onePerson: false) == ["U": "Me", "V": "Me", "B": "Speaker 1"],
      "nameOne: two clusters that are both print matches with 10 s or more are both Me, as on the microphone side")
check(nameOne([oneU, oneB, sp("T", seconds: 30, vector: e2)], keptWords: ["U": 60, "B": 37, "T": 3], firstWord: ["U": 0, "B": 10, "T": 20],
              print: usable, onePerson: false) == ["U": "Me", "B": "Speaker 1", "T": "Unknown"]
      && nameOne([oneU, oneB, sp("T", seconds: 30, vector: e2)], keptWords: ["U": 60, "B": 37, "T": 3], firstWord: ["U": 0, "B": 10, "T": 20],
                 print: usable, onePerson: false, counted: true) == ["U": "Me", "B": "Speaker 1", "T": "Speaker 2"],
      "nameOne: without a count, a speaker under 5% of the kept words is Unknown; a count turns that test off, as on a side")
check(nameOne([sp("U", seconds: 5, vector: at(0.9)), oneB], keptWords: oneKept, firstWord: oneFirst, print: usable, onePerson: true)
      == ["U": "Speaker 1", "B": "Speaker 1"],
      "nameOne: one person whose only print match has 5 s of talk is Speaker 1, not Me")
check(nameOne([oneB, oneX, oneU], keptWords: oneKept, firstWord: oneFirst, print: usable, onePerson: true) == ["B": "Me", "X": "Me", "U": "Me"]
      && nameOne([oneB, oneA], keptWords: oneKept, firstWord: oneFirst, print: usable, onePerson: true) == ["B": "Speaker 1", "A": "Speaker 1"]
      && nameOne([oneB, oneU], keptWords: oneKept, firstWord: oneFirst, print: nil, onePerson: true) == ["B": "Speaker 1", "U": "Speaker 1"],
      "nameOne: with one person, everyone found is Me when the print matches any of them, else Speaker 1")

let oneMe = labelOne(oneWords, speakers: oneSide, print: usable)
let oneMeLines = render(transcriptLines(oneMe, plain: false))
check(oneMeLines == "[00:00:00] Me: Right, so the plan is simple.\n[00:00:10] Speaker 1: what about the budget?\n"
      + "[00:00:20] Speaker 2: I have the numbers here.\n[00:00:40] Unknown: anyway.\n" && oneMe.log.isEmpty,
      "labelOne: with a matching print, Me and Speaker lines with their times, and a word no speaker covers is Unknown with its own time (\(oneMeLines))")
let oneNoPrint = labelOne(oneWords, speakers: oneSide, print: nil)
check(transcriptLines(oneNoPrint, plain: false).map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3", "Unknown"]
      && oneNoPrint.log == ["Your voice is not learnt yet, so nobody in this recording is labelled Me"],
      "labelOne: with no print, Speaker 1, 2 and 3, and the log says the voice is not learnt yet (\(oneNoPrint.log))")
let oneUnusable = labelOne(oneWords, speakers: oneSide, print: vp(meetings: 1))
check(transcriptLines(oneUnusable, plain: false).map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3", "Unknown"],
      "labelOne: a print that is not usable (one meeting, no sample) makes nobody Me")
let oneNotMe = labelOne(oneWords, speakers: side(oneSegments, [sp("U", seconds: 30, vector: at(0.5)), oneB, oneA, oneX]), print: usable)
check(transcriptLines(oneNotMe, plain: false).map(\.label) == ["Unknown", "Speaker 1", "Speaker 2", "Unknown"]
      && oneNotMe.log == ["Your voice was not recognised in this recording (best match 0.50)"],
      "labelOne: a usable print matching nobody logs 'not recognised' with the best match; at 0.50 that voice is Unknown (\(oneNotMe.log))")
let oneBare = labelOne(oneWords, speakers: nil, print: usable)
let oneBareLines = render(transcriptLines(oneBare, plain: false))
check(oneBare.micLabels.allSatisfy { $0 == "Unknown" } && oneBare.micLabels.count == oneWords.count && oneBare.call.isEmpty && oneBare.log.isEmpty
      && oneBareLines == "[00:00:00] Unknown: Right, so the plan is simple.\n[00:00:10] Unknown: what about the budget?\n"
      + "[00:00:20] Unknown: I have the numbers here.\n[00:00:40] Unknown: anyway.\n",
      "labelOne: with no speakers file every word is Unknown, and every line keeps its time (\(oneBareLines))")
let oneOne = labelOne(oneWords, speakers: oneSide, print: usable, onePerson: true)
let oneOneOff = labelOne(oneWords, speakers: oneSide, print: nil, onePerson: true)
check(oneOne.micLabels.count == oneWords.count && oneOne.micLabels.allSatisfy { $0 == "Me" }
      && oneOneOff.micLabels.allSatisfy { $0 == "Speaker 1" } && transcriptLines(oneOneOff, plain: false).map(\.start) == [0, 10, 20, 40],
      "labelOne: one person gives one label to every word, covered or not: Me with a matching print, else Speaker 1, with each line's time")
let oneOneBare = labelOne(oneWords, speakers: nil, print: usable, onePerson: true).micLabels
check(oneOneBare.count == oneWords.count && oneOneBare.allSatisfy { $0 == "Unknown" },
      "labelOne: one person with no speakers file is still Unknown: nobody's voice was heard to match")
let oneOneNobody = labelOne(oneWords, speakers: side([], []), print: usable, onePerson: true).micLabels
check(oneOneNobody.count == oneWords.count && oneOneNobody.allSatisfy { $0 == "Speaker 1" },
      "labelOne: one person, the finder having found nobody: Speaker 1, since no voice matched the print")
// An acknowledgement between two of the user's sentences: inline when tidied, a line of its own at every change of label with --plain.
let replyWords = said("so we should.", from: 0) + [w(1.3, 1.5, "yeah")] + said("go now.", from: 1.7)
let replySide = side([Segment(speaker: "U", start: 0, end: 1.2), Segment(speaker: "B", start: 1.25, end: 1.55), Segment(speaker: "U", start: 1.6, end: 3)],
                     [oneU, oneB])
let replyRun = labelOne(replyWords, speakers: replySide, print: usable)
check(render(transcriptLines(replyRun, plain: false)) == "[00:00:00] Me: so we should. (Speaker 1: yeah) go now.\n"
      && render(transcriptLines(replyRun, plain: true)) == "[00:00:00] Me: so we should.\n[00:00:01] Speaker 1: yeah\n[00:00:01] Me: go now.\n",
      "labelOne: tidied, a short reply goes inline; with --plain a new line starts at every change of label (\(transcriptLines(replyRun, plain: true)))")

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
        check(reset.refused == [], "learn: a learnt call in between clears the refused meetings, which count only in a row")
    } else { check(false, "learn: a learnt call in between resets refusals to 0") }
    // Review finding 2: the same refused call processed again (Try again, a Finder duplicate) is not a second refusal.
    check(once.refused == ["m-1"] && learnFrom(once, voiceB, kept: keptB, source: "m-1") == .unchanged,
          "learn: the same refused call processed twice counts once: refusals stays 1, not a discard")
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

// ======================================================================= the voice sample (6.2)
// "Record a voice sample…": the speakers in the sample, found without a count, become the print.

func fromSample(_ speakers: [SpeakerInfo]) -> Result<VoicePrint, SampleRefusal> { sampleToPrint(speakers, model: model, now: now) }
if case .success(let p) = fromSample([sp("S1", seconds: 75, median: 6, vector: [3, 4, 0, 0])]) {
    check(p.model == model && p.seconds == 75 && p.meetings == 1 && p.sources == [] && p.sample && p.refusals == 0 && p.refused == []
          && close(p.vector, [0.6, 0.8, 0, 0]) && p.updated == stamp && usablePrint(p, model: model) == p,
          "sampleToPrint: 75 s of one voice is a usable print: meetings 1, no sources, sample true, its vector scaled to length 1 (\(p))")
} else { check(false, "sampleToPrint: 75 s of one voice is a usable print: meetings 1, no sources, sample true, its vector scaled to length 1") }
check(fromSample([sp("S1", seconds: 40, median: 6, vector: e1)]) == .failure(.tooShort(40)), "sampleToPrint: 40 s gives tooShort(40)")
check(fromSample([]) == .failure(.tooShort(0)), "sampleToPrint: no speakers gives tooShort(0)")
check(fromSample([sp("S1", seconds: 59.6, median: 6, vector: e1)]) == .failure(.tooShort(59)),
      "sampleToPrint: the seconds a refusal gives are whole seconds, rounded down (59.6 s is 59, not the 60 needed)")
if case .success(let p) = fromSample([sp("S1", seconds: 60, median: 6, vector: e1)]) {
    check(p.seconds == 60, "sampleToPrint: exactly 60 s is enough")
} else { check(false, "sampleToPrint: exactly 60 s is enough") }
check(fromSample([sp("S1", seconds: 80, median: 5, vector: e1), sp("S2", seconds: 20, median: 4, vector: at(0.3))]) == .failure(.moreThanOneVoice),
      "sampleToPrint: a second speaker with 20% of the talk, a 4 s median and a cosine of 0.3 gives moreThanOneVoice")
if case .success(let p) = fromSample([sp("S1", seconds: 92, median: 5, vector: e1), sp("S2", seconds: 8, median: 3, vector: at(0.7))]) {
    let unit = at(0.7)
    check(p.seconds == 100 && close(p.vector, zip(e1, unit).map { ($0 * 92 + $1 * 8) / 100 }) && p.meetings == 1 && p.sample,
          "sampleToPrint: one voice split 92% and 8% at a cosine of 0.7 is accepted, with the seconds of both, talk-weighted (\(p.vector))")
} else { check(false, "sampleToPrint: one voice split 92% and 8% at a cosine of 0.7 is accepted, with the seconds of both, talk-weighted") }
if case .success(let p) = fromSample([sp("S1", seconds: 96, median: 5, vector: [5, 0, 0, 0]), sp("S2", seconds: 4, median: 3, vector: at(0.2))]) {
    check(p.seconds == 96 && close(p.vector, e1), "sampleToPrint: a 4% speaker at a cosine of 0.2 is ignored, and the print is the main speaker's vector alone, unit-scaled")
} else { check(false, "sampleToPrint: a 4% speaker at a cosine of 0.2 is ignored, and the print is the main speaker's vector alone, unit-scaled") }
if case .success(let p) = fromSample([sp("S1", seconds: 90, median: 5, vector: e1), sp("S2", seconds: 10, median: 1.9, vector: e3)]) {
    check(p.seconds == 90 && close(p.vector, e1), "sampleToPrint: a 10% speaker with a 1.9 s median is ignored and not added")
} else { check(false, "sampleToPrint: a 10% speaker with a 1.9 s median is ignored and not added") }
// The edges and the order of the rules.
check(fromSample([sp("S1", seconds: 95, median: 5, vector: e1), sp("S2", seconds: 5, median: 2.5, vector: e3)]) == .failure(.moreThanOneVoice),
      "sampleToPrint: exactly 5% of the talk with exactly a 2.5 s median is not small: another voice")
if case .success(let p) = fromSample([sp("S1", seconds: 97, median: 5, vector: e1), sp("S2", seconds: 3, median: 1, vector: at(0.65))]) {
    check(p.seconds == 100, "sampleToPrint: the same voice is added in even when it is small: the cosine rule comes first")
} else { check(false, "sampleToPrint: the same voice is added in even when it is small: the cosine rule comes first") }
if case .success(let p) = fromSample([sp("S1", seconds: 50, median: 5, vector: e1), sp("S2", seconds: 15, median: 4, vector: at(0.65))]) {
    check(p.seconds == 65, "sampleToPrint: the same voice split in two counts towards the 60 s")
} else { check(false, "sampleToPrint: the same voice split in two counts towards the 60 s") }
check(fromSample([sp("S1", seconds: 40, median: 5, vector: e1), sp("S2", seconds: 20, median: 4, vector: e3)]) == .failure(.moreThanOneVoice),
      "sampleToPrint: a short sample with a second voice is refused for the second voice, which recording longer would not cure")
if case .success(let p) = fromSample([sp("S2", seconds: 10, median: 1, vector: e3), sp("S1", seconds: 70, median: 5, vector: e2)]) {
    check(p.seconds == 70 && close(p.vector, e2), "sampleToPrint: the user is the speaker with the most speech, wherever it is listed")
} else { check(false, "sampleToPrint: the user is the speaker with the most speech, wherever it is listed") }
check(sampleRefusalLine(.tooShort(40)) == "Not enough speech: 40 seconds of the 60 needed. Record again and read for the whole 90 seconds."
      && sampleRefusalLine(.moreThanOneVoice) == "More than one voice was heard. Record again with only you speaking.",
      "sampleRefusalLine: the two refusals, word for word")
check(sampleRefusalLine(.tooShort(1)) == "Not enough speech: 1 second of the 60 needed. Record again and read for the whole 90 seconds.",
      "sampleRefusalLine: 1 second, singular")

// --- mb-transcript --voice-sample F --voice V (saveSample is what main.swift runs) ---
let sampleFolder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-sample-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
let sampleVoice = sampleFolder.appendingPathComponent("voice.json"), sampleTmp = sampleFolder.appendingPathComponent("voice.json.tmp")
func speakersFile(_ speakers: [(String, Double, Double, [Double])]) -> Data {
    let list = speakers.map { "{\"id\": \"\($0.0)\", \"seconds\": \($0.1), \"median\": \($0.2), \"vector\": \($0.3)}" }.joined(separator: ", ")
    let segments = speakers.map { "{\"speaker\": \"\($0.0)\", \"start\": 0, \"end\": \($0.1)}" }.joined(separator: ", ")
    return Data("{\"model\": \"\(model)\", \"segments\": [\(segments)], \"speakers\": [\(list)]}".utf8)
}
let oneVoice = speakersFile([("S1", 75.4, 6, [3, 4, 0, 0])])
let learnt = vp(seconds: 391, meetings: 3, sources: ["m-a", "m-b", "m-c"], vector: e3)
try? encodePrint(learnt).write(to: sampleVoice)
let saved = saveSample(speakers: oneVoice, from: "sample.speakers.json", voice: sampleVoice, now: now)
let savedPrint = try? decodePrint(contents(sampleVoice) ?? Data())
check(saved == .saved(seconds: 75) && savedPrint?.sample == true && savedPrint?.meetings == 1 && savedPrint?.sources == []
      && savedPrint?.seconds == 75.4 && close(savedPrint?.vector ?? [], [0.6, 0.8, 0, 0]) && savedPrint?.model == model,
      "saveSample: replaces a learnt print, without comparing, and answers sample 75 (\(saved))")
check(mode(sampleVoice) == 0o600 && !FileManager.default.fileExists(atPath: sampleTmp.path),
      "saveSample: voice.json is 0600 and no voice.json.tmp is left")
check(saveSample(speakers: speakersFile([("S1", 75.6, 6, [3, 4, 0, 0])]), from: "x", voice: sampleVoice, now: now) == .saved(seconds: 75)
      && (try? decodePrint(contents(sampleVoice) ?? Data()))?.seconds == 75.6,
      "saveSample: sample <seconds> is whole seconds, rounded down (75.6 s answers sample 75), and the print keeps 75.6")
try? FileManager.default.createDirectory(at: sampleTmp, withIntermediateDirectories: true)
let blockedBefore = contents(sampleVoice)
if case .failed = saveSample(speakers: speakersFile([("S1", 80, 6, [0, 0, 1, 0])]), from: "x", voice: sampleVoice, now: now) {
    check(contents(sampleVoice) == blockedBefore, "saveSample: it writes through voice.json.tmp, so when that cannot be made voice.json is left as it was")
} else { check(false, "saveSample: it writes through voice.json.tmp, so when that cannot be made voice.json is left as it was") }
try? FileManager.default.removeItem(at: sampleTmp)
let refusedBefore = contents(sampleVoice)
let refusedShort = saveSample(speakers: speakersFile([("S1", 40.7, 6, [1, 0, 0, 0])]), from: "x", voice: sampleVoice, now: now)
let refusedTwo = saveSample(speakers: speakersFile([("S1", 80, 5, [1, 0, 0, 0]), ("S2", 20, 4, [0, 0, 1, 0])]), from: "x", voice: sampleVoice, now: now)
check(refusedShort == .refused("Not enough speech: 40 seconds of the 60 needed. Record again and read for the whole 90 seconds.")
      && refusedTwo == .refused("More than one voice was heard. Record again with only you speaking.")
      && contents(sampleVoice) == refusedBefore && !FileManager.default.fileExists(atPath: sampleTmp.path),
      "saveSample: a refusal gives its one line and leaves voice.json byte-identical")
let noSpeakers = saveSample(speakers: Data("{\"model\": \"\(model)\", \"segments\": [], \"speakers\": []}".utf8), from: "x", voice: sampleVoice, now: now)
check(noSpeakers == .refused("Not enough speech: 0 seconds of the 60 needed. Record again and read for the whole 90 seconds."),
      "saveSample: a sample with no speech found is too short")
if case .failed = saveSample(speakers: nil, from: "gone.json", voice: sampleVoice, now: now),
   case .failed = saveSample(speakers: Data("garbage".utf8), from: "bad.json", voice: sampleVoice, now: now) {
    check(contents(sampleVoice) == refusedBefore, "saveSample: a missing or unreadable speakers file fails and changes nothing")
} else { check(false, "saveSample: a missing or unreadable speakers file fails and changes nothing") }
try? FileManager.default.removeItem(at: sampleFolder)

// --- one lock for every writer of the voice print ---
// <voice.json>.lock: mb-transcript takes flock(LOCK_EX) on it around each save and discard, and the
// engine's `voice forget` takes the same lock with BSD lockf. Never held across a whole run.
let lockFolder = FileManager.default.temporaryDirectory.appendingPathComponent("mb-lock-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: lockFolder, withIntermediateDirectories: true)
let lVoice = lockFolder.appendingPathComponent("voice.json"), lTmp = lockFolder.appendingPathComponent("voice.json.tmp")
let lLock = lockFolder.appendingPathComponent("voice.json.lock")
func exists(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == 0 }
func regular(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG }
/// Holds the lock as another writer does: its own open file, flock'd.
func holdLock() -> Int32 {
    let fd = open(lLock.path, O_RDWR | O_CREAT, 0o600)
    flock(fd, LOCK_EX)
    return fd
}
func release(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
/// Runs a tool and gives its exit status.
func tool(_ path: String, _ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}
/// Runs `work` on another thread; `wait` gives what it returned, or nil if it has not finished in time.
final class Background<T> {
    private let done = DispatchSemaphore(value: 0)
    private var value: T?
    init(_ work: @escaping () -> T) {
        DispatchQueue.global().async { self.value = work(); self.done.signal() }
    }
    func wait(_ seconds: Double) -> T? { done.wait(timeout: .now() + seconds) == .success ? value : nil }
}
func printAt(_ url: URL) -> VoicePrint? { try? decodePrint(contents(url) ?? Data()) }

try? encodePrint(usable).write(to: lVoice)
check((try? savePrintIfUnchanged(newPrint, at: lVoice, readState: fileState(at: lVoice))) == true && regular(lLock) && mode(lLock) == 0o600,
      "lock: a save makes <voice.json>.lock beside the print, a plain file, 0600, and leaves it there")

// A held lock makes a second save wait, and it then checks and writes under the lock.
var held = holdLock()
let waitingSave = Background { (try? savePrintIfUnchanged(usable, at: lVoice, readState: fileState(at: lVoice), lockWait: 10)) ?? false }
check(waitingSave.wait(0.4) == nil && printAt(lVoice) == newPrint, "lock: a save waits while another writer holds the lock, writing nothing")
release(held)
check(waitingSave.wait(10) == true && printAt(lVoice) == usable, "lock: and saves once the lock is free")

// Or it times out, writing nothing; so does a discard and a sample save.
held = holdLock()
let heldBefore = contents(lVoice)
var timedOut = false
do { _ = try savePrintIfUnchanged(newPrint, at: lVoice, readState: fileState(at: lVoice), lockWait: 0.3) } catch { timedOut = true }
check(timedOut && contents(lVoice) == heldBefore && !exists(lTmp), "lock: a save that cannot get the lock in time fails and writes nothing")
var discardTimedOut = false
do { _ = try discardPrintIfUnchanged(at: lVoice, readState: fileState(at: lVoice), lockWait: 0.3) } catch { discardTimedOut = true }
check(discardTimedOut && contents(lVoice) == heldBefore, "lock: a discard waits for the lock too, and removes nothing when it times out")
var sampleTimedOut = false
do { try savePrint(newPrint, at: lVoice, lockWait: 0.3) } catch { sampleTimedOut = true }
let busySample = saveSample(speakers: oneVoice, from: "x", voice: lVoice, now: now, lockWait: 0.3)
if case .failed = busySample {
    check(sampleTimedOut && contents(lVoice) == heldBefore && !exists(lTmp),
          "lock: a sample save (--voice-sample) waits for the lock too, and fails with voice.json byte-identical when it times out")
} else { check(false, "lock: a sample save (--voice-sample) waits for the lock too, and fails with voice.json byte-identical when it times out") }
release(held)

// A learn whose read was made before a forget saves nothing. The forget is the engine's: lockf, then rm.
let readBeforeForget = fileState(at: lVoice)
check(tool("/usr/bin/lockf", ["-s", "-k", "-t", "5", lLock.path, "/bin/rm", "-f", "--", lVoice.path]) == 0
      && (try? savePrintIfUnchanged(newPrint, at: lVoice, readState: readBeforeForget)) == false && !exists(lVoice) && regular(lLock),
      "lock: a learn whose read was made before a forget writes nothing, and the print stays forgotten")
// Interleaved: the forget holds the lock when the learn comes to save; the learn waits, then checks.
try? encodePrint(usable).write(to: lVoice)
let readMid = fileState(at: lVoice)
held = holdLock()
let learnDuringForget = Background { (try? savePrintIfUnchanged(newPrint, at: lVoice, readState: readMid, lockWait: 10)) ?? true }
usleep(300_000)
unlink(lVoice.path) // the forget's rm, under its lock
release(held)
check(learnDuringForget.wait(10) == false && !exists(lVoice), "lock: a learn that comes to save during a forget waits for it, then writes nothing")

// Two writers never rename each other's voice.json.tmp: many saves at once, every one whole.
try? encodePrint(usable).write(to: lVoice)
let errorsLock = NSLock()
var writerErrors: [String] = []
var written: Set<String> = []
DispatchQueue.concurrentPerform(iterations: 8) { i in
    for k in 0..<40 {
        let p = vp(seconds: Double(100 + i), sources: ["w\(i)-\(k)"])
        do {
            if k % 2 == 0 {
                try savePrint(p, at: lVoice)
                errorsLock.lock(); written.insert("w\(i)-\(k)"); errorsLock.unlock()
            } else if try savePrintIfUnchanged(p, at: lVoice, readState: fileState(at: lVoice)) {
                errorsLock.lock(); written.insert("w\(i)-\(k)"); errorsLock.unlock()
            }
        } catch {
            errorsLock.lock(); writerErrors.append("\(error)"); errorsLock.unlock()
        }
    }
}
let lastWritten = printAt(lVoice)
check(writerErrors.isEmpty && lastWritten.map { written.contains($0.sources.first ?? "") } == true && !exists(lTmp),
      "lock: 320 saves from 8 writers at once: none fails, voice.json is one whole print one of them wrote, no voice.json.tmp left (\(writerErrors.prefix(3)))")

// Two processes: lockf (BSD, O_EXLOCK) and this process's flock are the same lock.
held = holdLock()
let lockfStart = Date()
let lockfBusy = tool("/usr/bin/lockf", ["-s", "-k", "-t", "1", lLock.path, "/usr/bin/true"])
check(lockfBusy == 75 && Date().timeIntervalSince(lockfStart) >= 0.9,
      "lock, two processes: while this process holds the flock, lockf waits and times out with EX_TEMPFAIL (\(lockfBusy))")
release(held)
check(tool("/usr/bin/lockf", ["-s", "-k", "-t", "1", lLock.path, "/usr/bin/true"]) == 0, "lock, two processes: and lockf takes it once it is free")
let lockfReady = lockFolder.appendingPathComponent("ready")
let holder = Process()
holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
holder.arguments = ["-k", lLock.path, "/bin/sh", "-c", "touch \"$0\"; sleep 2", lockfReady.path]
try? holder.run()
var readyWait = 0
while !exists(lockfReady) && readyWait < 200 { usleep(20_000); readyWait += 1 }
let beforeLockf = contents(lVoice)
var blockedByLockf = false
do { try savePrint(newPrint, at: lVoice, lockWait: 0.3) } catch { blockedByLockf = true }
check(exists(lockfReady) && blockedByLockf && contents(lVoice) == beforeLockf,
      "lock, two processes: while lockf holds the lock, a save here waits and times out, writing nothing")
let afterLockf = Background { () -> Bool in (try? savePrint(newPrint, at: lVoice, lockWait: 10)) != nil }
holder.waitUntilExit()
check(afterLockf.wait(10) == true && printAt(lVoice) == newPrint && regular(lLock),
      "lock, two processes: the save goes ahead once lockf is done, and lockf -k left the lock file")

// A link at the lock's path is never followed.
let elsewhere = lockFolder.appendingPathComponent("elsewhere")
unlink(lLock.path)
symlink(elsewhere.path, lLock.path)
let beforeLink = contents(lVoice)
var linkRefused = false
do { try savePrint(usable, at: lVoice, lockWait: 0.3) } catch { linkRefused = true }
check(linkRefused && !exists(elsewhere) && contents(lVoice) == beforeLink, "lock: a link at the lock's path is not followed: the save fails and changes nothing")
try? FileManager.default.removeItem(at: lockFolder)

// --- --me-name NAME: the label Me becomes the user's name, and nothing else changes (Task 11B) ---
do {
    var l = LabelledWords()
    l.mic = said("So we should go.", from: 0) + said("Fine.", from: 6)
    l.micLabels = ["Me", "Me", "Me", "Me", "Room 1"]
    l.call = [w(1.0, 1.2, "yeah")] + said("Later then.", from: 9)
    l.callLabels = ["Them 1", "Unknown", "Unknown"]
    l.log = ["a log line"]
    let named = renameMe(l, to: "Sam")
    check(named.micLabels == ["Sam", "Sam", "Sam", "Sam", "Room 1"] && named.callLabels == l.callLabels,
          "renameMe: every Me is Sam, and Room 1, Them 1 and Unknown stay as they are")
    check(named.mic.map(\.text) == l.mic.map(\.text) && named.call.map(\.text) == l.call.map(\.text) && named.log == l.log,
          "renameMe: the words and the log are unchanged")
    let lines = render(transcriptLines(named, plain: false))
    check(lines.contains("Sam: So we should") && !lines.contains("Me:") && lines.contains("(Them 1: yeah)"),
          "renameMe: the lines say Sam where they said Me, short replies too (\(lines))")
    check(render(transcriptLines(renameMe(l, to: nil), plain: false)) == render(transcriptLines(l, plain: false))
          && render(transcriptLines(renameMe(l, to: nil), plain: true)) == render(transcriptLines(l, plain: true)),
          "renameMe: with no name the lines are unchanged, tidied or plain")
    var me = LabelledWords()
    me.call = said("Hello there.", from: 0)
    me.callLabels = ["Me", "Me"]
    check(renameMe(me, to: "Sam").callLabels == ["Sam", "Sam"], "renameMe: a Me on the call side is Sam too")
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
