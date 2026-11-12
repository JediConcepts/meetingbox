// Merges the mic and call transcripts into labelled lines: tidy lines that follow sentences,
// or with tidying off, a line per turn. The speakers found on each side become the labels.
import Foundation

struct Word: Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct Turn: Equatable {
    let label: String
    let start: Double
    let text: String
}

struct TranscriptError: Error, CustomStringConvertible {
    let description: String
}

/// Reads speech-analyzer JSON ({"words":[{start,end,text}]}) or whisper-cli -oj JSON
/// ({"transcription":[{offsets:{from,to} in ms, text}]}). Empty data or {} gives no words.
func loadWords(_ data: Data) throws -> [Word] {
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TranscriptError(description: "not a JSON object")
    }
    var words: [Word] = []
    func add(_ start: Double, _ end: Double, _ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        if text.hasPrefix("[") && text.hasSuffix("]") && text.count > 1 { return } // [BLANK_AUDIO] and friends
        words.append(Word(start: start, end: end, text: text))
    }
    if let list = root["words"] as? [[String: Any]] {
        for item in list {
            guard let s = (item["start"] as? NSNumber)?.doubleValue,
                  let e = (item["end"] as? NSNumber)?.doubleValue,
                  let t = item["text"] as? String else { continue }
            add(s, e, t)
        }
    }
    if let list = root["transcription"] as? [[String: Any]] {
        for item in list {
            guard let offsets = item["offsets"] as? [String: Any],
                  let from = (offsets["from"] as? NSNumber)?.doubleValue,
                  let to = (offsets["to"] as? NSNumber)?.doubleValue,
                  let t = item["text"] as? String else { continue }
            add(from / 1000, to / 1000, t)
        }
    }
    return words
}

/// Lowercased, letters and digits only.
func normalised(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

/// Drops the mic words that are the call coming back through the speakers.
///
/// Echo is the far side's words again, in the same order, but the transcriber times each
/// side separately and the two drift by a few seconds. So the mic and call words are lined
/// up as the longest common sequence of equal words (each call word cancels at most one mic
/// word), pairing only words that start within `runWindow` seconds of each other. A pair in
/// a run of two or more mic words counts as echo; a pair on its own only within `window`
/// seconds, so a lone "yes" just after theirs is kept. Then a gap of one or two mic words
/// with echo on both sides, each no more than `bridge` seconds away, counts as echo too:
/// that is the transcriber hearing the echo slightly differently ("going to" for "gonna").
/// One word on one side matching two on the other ("chitchat", "chit chat") is echo too.
func removeEcho(mic: [Word], call: [Word], window: Double = 0.6,
                runWindow: Double = 4.0, bridge: Double = 1.5) -> [Word] {
    let echo = matchEcho(mic: mic, call: call, window: window, runWindow: runWindow, bridge: bridge).echo
    return mic.indices.filter { !echo.contains($0) }.map { mic[$0] }
}

/// removeEcho's matching: the indices of the mic words it drops, and the (mic, call) word pairs it
/// counted as echo, as indices into `mic` and `call`. A mic word dropped only to bridge a gap has no
/// pair. Who said the pairs, and which copy came first, is how one voice heard on both sides is told.
func matchEcho(mic: [Word], call: [Word], window: Double = 0.6, runWindow: Double = 4.0, bridge: Double = 1.5)
    -> (echo: Set<Int>, pairs: [(micWord: Int, callWord: Int)]) {
    let m = mic.indices.sorted { mic[$0].start != mic[$1].start ? mic[$0].start < mic[$1].start : $0 < $1 }
    let c = call.indices.sorted { call[$0].start != call[$1].start ? call[$0].start < call[$1].start : $0 < $1 }
    let mk = m.map { normalised(mic[$0].text) }
    let ck = c.map { normalised(call[$0].text) }

    // Candidate pairs (position in m, position in c): for each mic word, the call words
    // with the same text in reach. Built from the last mic word back, so that among equally
    // long chains the earliest words win: echo comes straight away, a repeat comes later.
    var pairs: [(i: Int, j: Int)] = []
    var hi = c.count
    for i in m.indices.reversed() where !mk[i].isEmpty {
        let t = mic[m[i]].start
        while hi > 0 && call[c[hi - 1]].start > t + runWindow { hi -= 1 }
        var j = hi - 1
        var found: [Int] = []
        while j >= 0 && call[c[j]].start >= t - runWindow {
            if ck[j] == mk[i] { found.append(j) }
            j -= 1
        }
        // lowest j first, so the chain below can take only one per mic word
        for j in found.reversed() { pairs.append((i, j)) }
    }

    // Longest chain falling in both i and j as built (rising in time): patience sorting on -j.
    var tails: [Int] = []          // index into pairs ending the best chain of each length
    var parent = [Int](repeating: -1, count: pairs.count)
    for (p, pair) in pairs.enumerated() {
        var a = 0, b = tails.count
        while a < b {
            let mid = (a + b) / 2
            if pairs[tails[mid]].j > pair.j { a = mid + 1 } else { b = mid }
        }
        if a > 0 { parent[p] = tails[a - 1] }
        if a == tails.count { tails.append(p) } else { tails[a] = p }
    }
    var chain: [(i: Int, j: Int)] = []
    var p = tails.last ?? -1
    while p >= 0 { chain.append(pairs[p]); p = parent[p] }   // comes out earliest first

    var echo = [Bool](repeating: false, count: m.count)
    var matched: [(micWord: Int, callWord: Int)] = []
    for (k, pair) in chain.enumerated() {
        let inRun = (k > 0 && chain[k - 1].i == pair.i - 1) || (k + 1 < chain.count && chain[k + 1].i == pair.i + 1)
        let dt = abs(mic[m[pair.i]].start - call[c[pair.j]].start)
        if inRun || dt <= window { echo[pair.i] = true; matched.append((m[pair.i], c[pair.j])) }
    }

    // One side hearing one word where the other hears two ("chitchat" and "chit chat",
    // "no-setup" and "no setup"): matched on the words the chain left, within runWindow.
    var used = Set(chain.filter { echo[$0.i] }.map(\.j))
    func callNear(_ t: Double) -> Range<Int> {
        var a = 0, b = c.count
        while a < b { let mid = (a + b) / 2; if call[c[mid]].start < t - runWindow { a = mid + 1 } else { b = mid } }
        var e = a
        while e < c.count && call[c[e]].start <= t + runWindow { e += 1 }
        return a..<e
    }
    for i in 0..<max(m.count - 1, 0) where !echo[i] && !echo[i + 1] && !mk[i].isEmpty && !mk[i + 1].isEmpty {
        let both = mk[i] + mk[i + 1]
        if let j = callNear(mic[m[i]].start).first(where: { !used.contains($0) && ck[$0] == both }) {
            echo[i] = true; echo[i + 1] = true; used.insert(j)
            matched.append((m[i], c[j])); matched.append((m[i + 1], c[j]))
        }
    }
    for i in m.indices where !echo[i] && !mk[i].isEmpty {
        let near = callNear(mic[m[i]].start)
        if let j = near.first(where: { $0 + 1 < near.upperBound && !used.contains($0) && !used.contains($0 + 1)
                                        && !ck[$0].isEmpty && !ck[$0 + 1].isEmpty && ck[$0] + ck[$0 + 1] == mk[i] }) {
            echo[i] = true; used.insert(j); used.insert(j + 1)
            matched.append((m[i], c[j])); matched.append((m[i], c[j + 1]))
        }
    }

    // Bridge short gaps inside echo.
    var i = 0
    while i < m.count {
        if echo[i] { i += 1; continue }
        var j = i
        while j < m.count && !echo[j] { j += 1 }
        if j - i <= 2, i > 0, j < m.count,
           mic[m[i]].start - mic[m[i - 1]].start <= bridge,
           mic[m[j]].start - mic[m[j - 1]].start <= bridge {
            for k in i..<j { echo[k] = true }
        }
        i = j
    }

    var drop = Set<Int>()
    for (i, e) in echo.enumerated() where e { drop.insert(m[i]) }
    return (drop, matched)
}

/// The one place that decides spacing: none before , . ! ? ; : % ) ] } and closing quotes,
/// none after ( [ and opening quotes.
func joinWords(_ text: String, _ next: String) -> String {
    if text.isEmpty { return next }
    let noSpaceBefore: Set<Character> = [",", ".", "!", "?", ";", ":", "%", ")", "]", "}", "\u{201D}", "\u{2019}"]
    let noSpaceAfter: Set<Character> = ["(", "[", "\u{201C}", "\u{2018}"]
    if let f = next.first, noSpaceBefore.contains(f) { return text + next }
    if let l = text.last, noSpaceAfter.contains(l) { return text + next }
    return text + " " + next
}

/// All words sorted by start (stable), grouped into turns. A new turn starts when the label
/// changes or when a word starts more than `gap` seconds after the previous one ended.
func mergeTurns(_ streams: [(label: String, words: [Word])], gap: Double = 1.5) -> [Turn] {
    var all: [(label: String, word: Word, order: Int)] = []
    for s in streams { for w in s.words { all.append((s.label, w, all.count)) } }
    all.sort { $0.word.start != $1.word.start ? $0.word.start < $1.word.start : $0.order < $1.order }
    var turns: [Turn] = []
    var previous: (label: String, word: Word)?
    for item in all {
        if let p = previous, p.label == item.label, item.word.start - p.word.end <= gap, let last = turns.last {
            turns[turns.count - 1] = Turn(label: last.label, start: last.start, text: joinWords(last.text, item.word.text))
        } else {
            turns.append(Turn(label: item.label, start: item.word.start, text: item.word.text))
        }
        previous = (item.label, item.word)
    }
    return turns
}

/// Each word's end, capped at its start plus `cap` seconds. A transcriber can stretch the word
/// before a pause across the whole pause, which would hold a turn open. Applies with tidying on or off.
func capEnds(_ words: [Word], cap: Double = 1.2) -> [Word] {
    words.map { $0.end > $0.start + cap ? Word(start: $0.start, end: $0.start + cap, text: $0.text) : $0 }
}

/// Lower-case letters and apostrophes only: how fillers and short replies are matched.
func bareWord(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == "'" || $0 == "\u{2019}" })
}

/// Acknowledgements that can be a short reply. "No" is not one: it is an answer.
let shortReplyWords: Set<String> = ["yeah", "yes", "yep", "right", "okay", "ok", "mm", "mhm", "hmm", "sure", "exactly",
                                    "cool", "wow", "oh", "ah", "true", "absolutely", "alright", "totally", "nice", "good", "great"]
let fillerWords: Set<String> = ["um", "uh", "erm", "er", "umm", "uhm"]

/// One speaker's words for tidy lines, in time order: ends capped, and `#` tokens and fillers
/// dropped. A token made only of punctuation (, . ; : ? ! or an ellipsis) is never a word: it
/// joins the speaker's token before it, as if written straight after it, and is dropped when
/// there is none, so no comma is left orphaned. A filler goes with its punctuation; a full stop,
/// question mark or exclamation mark it carried moves to the word before, so no sentence loses
/// its end ("um..." trails off, and ends nothing).
func tidyWords(_ words: [Word]) -> [Word] {
    let ordered = words.indices.sorted { words[$0].start != words[$1].start ? words[$0].start < words[$1].start : $0 < $1 }
    var tokens: [Word] = []
    for w in capEnds(ordered.map { words[$0] }) where !w.text.hasPrefix("#") {
        guard w.text.allSatisfy({ ",.;:?!\u{2026}".contains($0) }) else { tokens.append(w); continue }
        if let last = tokens.last { tokens[tokens.count - 1] = Word(start: last.start, end: last.end, text: last.text + w.text) }
    }
    var kept: [Word] = []
    for w in tokens {
        guard fillerWords.contains(bareWord(w.text)) else { kept.append(w); continue }
        if let stop = w.text.last, ".?!".contains(stop), !w.text.hasSuffix(".."), let last = kept.last,
           let end = last.text.last, !".?!".contains(end) {
            var text = last.text
            while let c = text.last, ",;:".contains(c) { text.removeLast() }
            kept[kept.count - 1] = Word(start: last.start, end: last.end, text: text + String(stop))
        }
    }
    return kept
}

/// One speaker's words, as indices into the words in time order, with the first start and the
/// latest end. Stretches, utterances and lines are each a span.
private struct Span {
    let label: String
    var words: [Int]
    let start: Double
    var end: Double
}

/// Lines that follow sentences (spec 6.3), from labelled word streams. Words with the same label
/// are one speaker's, whichever stream they came from, and are tidied together.
///
/// - A stretch is one speaker's words no more than 1.5 s apart. A stretch of three words or
///   fewer, all acknowledgements, is a short reply, and a short reply is never somebody in between.
/// - Utterances are each speaker's other words, split where a gap exceeds 1.5 s, at a sentence
///   end once the utterance has run over 45 s, and at a pause in which another speaker said a
///   whole stretch that is not a short reply. Speaking over someone who is still going does not
///   split their utterance: cutting both speakers at every overlapping word left most lines of a
///   real call three words or fewer. Overlapping utterances are ordered by their start.
/// - A line takes in the same speaker's next utterance when nobody spoke in between, it starts
///   within 4 s of the line's end, and the line so far spans under 60 s.
/// - A short reply is written inline, "(Label: words)" without a closing comma or full stop, after
///   the last word that started by then of its host: the latest-starting utterance of another
///   speaker that contains the reply's start or ended within 0.5 s before it. With no host, it goes
///   the same way into the latest-starting line of another speaker that spans its start (the first
///   word starts before it, the last ends after it). Otherwise it is a line of its own.
func joinLines(_ streams: [(label: String, words: [Word])]) -> [Turn] {
    // One speaker per label, in the order the labels first come.
    var labels: [String] = []
    var byLabel: [String: [Word]] = [:]
    for s in streams {
        if byLabel[s.label] == nil { labels.append(s.label) }
        byLabel[s.label, default: []] += s.words
    }
    // Every kept word in time order; ties keep the order of the labels.
    var all: [(label: String, word: Word)] = []
    for l in labels { for w in tidyWords(byLabel[l] ?? []) { all.append((l, w)) } }
    let order = all.indices.sorted { all[$0].word.start != all[$1].word.start ? all[$0].word.start < all[$1].word.start : $0 < $1 }
    all = order.map { all[$0] }

    // Each speaker's stretches, in order of their first word, and which are short replies.
    var stretches: [Span] = []
    var latest: [String: Int] = [:]
    for (i, item) in all.enumerated() {
        if let k = latest[item.label], item.word.start - stretches[k].end <= 1.5 {
            stretches[k].words.append(i)
            stretches[k].end = max(stretches[k].end, item.word.end)
        } else {
            latest[item.label] = stretches.count
            stretches.append(Span(label: item.label, words: [i], start: item.word.start, end: item.word.end))
        }
    }
    let isReply = stretches.map { s in
        s.words.count <= 3 && s.words.allSatisfy { shortReplyWords.contains(bareWord(all[$0].word.text)) }
    }
    var inReply = [Bool](repeating: false, count: all.count)
    for (k, s) in stretches.enumerated() where isReply[k] { for i in s.words { inReply[i] = true } }

    // Whether another speaker said a whole stretch, not a short reply, between `from` and `to`.
    func spokeBetween(_ label: String, _ from: Double, _ to: Double) -> Bool {
        var a = 0, b = stretches.count
        while a < b { let m = (a + b) / 2; if stretches[m].start < from { a = m + 1 } else { b = m } }
        while a < stretches.count && stretches[a].start <= to {
            if !isReply[a] && stretches[a].label != label && stretches[a].end <= to { return true }
            a += 1
        }
        return false
    }

    // The utterances, from the words that are not short replies. They come out in order of
    // their first word, because the words are walked in time order.
    var utterances: [Span] = []
    var open: [String: Int] = [:]   // each speaker's utterance still taking words
    for (i, item) in all.enumerated() where !inReply[i] {
        let w = item.word
        if let k = open[item.label] {
            let u = utterances[k]
            if w.start - u.end <= 1.5 && !spokeBetween(item.label, u.end, w.start) {
                utterances[k].words.append(i)
                utterances[k].end = max(u.end, w.end)
            } else {
                open[item.label] = nil
            }
        }
        if open[item.label] == nil {
            open[item.label] = utterances.count
            utterances.append(Span(label: item.label, words: [i], start: w.start, end: w.end))
        }
        let u = utterances[open[item.label]!]
        if let c = w.text.last, ".?!".contains(c), u.end - u.start > 45 { open[item.label] = nil }
    }

    // Lines: the same speaker's next utterance joins the line when nobody spoke in between,
    // it starts within 4 s of the line's end, and the line so far spans under 60 s.
    var lines: [Span] = []
    for u in utterances {
        if let l = lines.last, l.label == u.label, u.start - l.end <= 4, l.end - l.start < 60 {
            lines[lines.count - 1].words += u.words
            lines[lines.count - 1].end = max(l.end, u.end)
        } else {
            lines.append(u)
        }
    }

    // The short replies, in time order, into their host or the line around them. A speaker's
    // earlier utterances and lines ended before their latest began, so only each other
    // speaker's latest utterance and line so far can take a reply.
    var asidesAfter: [Int: [String]] = [:]   // a word's index, and the replies written after it
    var alone: [Span] = []                    // replies that are lines of their own
    var latestUtterance: [String: Int] = [:], latestLine: [String: Int] = [:]
    var u = 0, l = 0
    for (k, reply) in stretches.enumerated() where isReply[k] {
        while u < utterances.count && utterances[u].start <= reply.start { latestUtterance[utterances[u].label] = u; u += 1 }
        while l < lines.count && lines[l].start < reply.start { latestLine[lines[l].label] = l; l += 1 }
        let host = latestUtterance.filter { $0.key != reply.label && reply.start - utterances[$0.value].end <= 0.5 }.values.max()
        let around = latestLine.filter { $0.key != reply.label && lines[$0.value].end > reply.start }.values.max()
        guard let into = host.map({ utterances[$0] }) ?? around.map({ lines[$0] }),
              let at = into.words.last(where: { all[$0].word.start <= reply.start }) else {
            alone.append(reply)
            continue
        }
        var text = reply.words.reduce("") { joinWords($0, all[$1].word.text) }
        while let c = text.last, ",.".contains(c) { text.removeLast() }
        asidesAfter[at, default: []].append("(\(reply.label): \(text))")
    }

    // The lines, and the replies that are lines of their own, in order of their start.
    func turn(_ s: Span) -> Turn {
        var text = ""
        for i in s.words {
            text = joinWords(text, all[i].word.text)
            for aside in asidesAfter[i] ?? [] { text = joinWords(text, aside) }
        }
        return Turn(label: s.label, start: s.start, text: text)
    }
    var turns: [Turn] = []
    var a = 0
    for line in lines {
        while a < alone.count && alone[a].start < line.start { turns.append(turn(alone[a])); a += 1 }
        turns.append(turn(line))
    }
    return turns + alone[a...].map(turn)
}

/// One line per turn: [HH:MM:SS] Label: text
func render(_ turns: [Turn]) -> String {
    turns.map { t in
        let s = Int(t.start.rounded(.down))
        return String(format: "[%02d:%02d:%02d] %@: %@\n", s / 3600, (s / 60) % 60, s % 60, t.label, t.text)
    }.joined()
}

// ====================================================================== speakers to labels (spec 6.2)

/// The fixed numbers of spec 6.2.
enum Rule {
    static let printMatch = 0.60       // a voice is the print's, or two voices are one
    static let printNear = 0.45        // too like the print to be anyone else
    static let learnCallLimit = 0.40   // learning needs every call voice further from the user's than this
    static let dominantShare = 0.80    // of the microphone's kept words: the user, on a call
    static let smallShare = 0.05       // under this share of a side, without a count, a voice is not numbered
    static let shortMedian = 2.5       // a median segment under this, without a count, is not numbered either
    static let meSeconds = 10.0        // talk a print match needs to be Me
    static let usableSeconds = 60.0    // speech a print needs to be used
    static let callSeconds = 20.0      // call-side speech that makes a meeting a call
    static let nearestEdge = 1.0       // how far a word may be from the nearest segment and still take it
    // How much later a call copy must be for the user's voice to have come back: a real round trip. A
    // leak through the speakers lags its call copy by tens of milliseconds, within the transcribers'
    // timing jitter (Parakeet's frames are 80 ms); a voice coming back lags by 150 ms or more. Set on
    // that physical argument: not yet measured on a recording with speaker leakage.
    static let returnLag = 0.12
}

/// Whether `x` is at least `limit`, allowing for rounding in the arithmetic that made it.
func atLeast(_ x: Double, _ limit: Double) -> Bool { x >= limit - 1e-9 }

/// One stretch of one speaker, as the diariser found it. Segments overlap.
struct Segment: Equatable {
    let speaker: String
    let start: Double
    let end: Double
}

/// One speaker on a side: talk time and median segment length (measured on the exclusive copy of the
/// segments), the diariser's voice vector, and `first`, the start of its earliest segment.
struct SpeakerInfo: Equatable {
    let id: String
    let seconds: Double
    let median: Double
    let vector: [Double]
    var first: Double = 0
}

enum Side { case mic, call }

/// One side's speakers file, as loadSpeakers reads it.
struct SideSpeakers {
    let model: String
    let segments: [Segment]
    let speakers: [SpeakerInfo]
}

/// Reads mb-speech's speakers JSON: {"model", "segments": [{speaker, start, end}], "speakers": [{id, seconds,
/// median, vector}]}. Each speaker's `first` is its earliest segment's start (infinity with none).
func loadSpeakers(_ data: Data) throws -> (model: String, segments: [Segment], speakers: [SpeakerInfo]) {
    func number(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return nil }
        return d
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let model = root["model"] as? String,
          let segmentList = root["segments"] as? [[String: Any]],
          let speakerList = root["speakers"] as? [[String: Any]] else {
        throw TranscriptError(description: "not a speakers file")
    }
    var segments: [Segment] = []
    for item in segmentList {
        guard let id = item["speaker"] as? String, let start = number(item["start"]), let end = number(item["end"]) else {
            throw TranscriptError(description: "a segment without a speaker, start and end")
        }
        segments.append(Segment(speaker: id, start: start, end: end))
    }
    var first: [String: Double] = [:]
    for s in segments { first[s.speaker] = min(first[s.speaker] ?? s.start, s.start) }
    var speakers: [SpeakerInfo] = []
    for item in speakerList {
        guard let id = item["id"] as? String, let seconds = number(item["seconds"]), let median = number(item["median"]),
              let list = item["vector"] as? [Any] else {
            throw TranscriptError(description: "a speaker without an id, seconds, median and vector")
        }
        let vector = list.compactMap { number($0) }
        guard vector.count == list.count else { throw TranscriptError(description: "speaker \(id)'s vector is not all numbers") }
        speakers.append(SpeakerInfo(id: id, seconds: seconds, median: median, vector: vector, first: first[id] ?? .infinity))
    }
    return (model, segments, speakers)
}

/// A call: the call side holds 20 s or more of speech, measured from its speakers when it has any,
/// else from its words. A side every transcriber failed on still counts by its speakers.
func isCall(callWords: [Word], callSpeakers: [SpeakerInfo]?) -> Bool {
    if let speakers = callSpeakers, !speakers.isEmpty {
        return atLeast(speakers.reduce(0) { $0 + $1.seconds }, Rule.callSeconds)
    }
    return atLeast(callWords.reduce(0) { $0 + max(0, $1.end - $1.start) }, Rule.callSeconds)
}

/// Each word's candidate speakers: those with a segment that holds the word's midpoint (from the
/// segment's start, inclusive, to its end, exclusive), in order of that segment's start, the
/// latest-starting last. With none, the speaker of the segment whose nearer edge is closest to the
/// midpoint, if that is within 1.0 s.
func candidates(_ words: [Word], _ segments: [Segment]) -> [[String]] {
    let ordered = segments.indices.sorted {
        segments[$0].start != segments[$1].start ? segments[$0].start < segments[$1].start : $0 < $1
    }.map { segments[$0] }
    return words.map { word in
        let mid = (word.start + word.end) / 2
        var holding: [String: Double] = [:]          // speaker, and the latest start of a segment holding the word
        var nearest: (gap: Double, speaker: String)?
        for s in ordered {
            if s.start > mid + Rule.nearestEdge { break }   // no later segment holds it or is near enough
            if s.start <= mid && mid < s.end {
                holding[s.speaker] = max(holding[s.speaker] ?? s.start, s.start)
            } else {
                let gap = mid < s.start ? s.start - mid : mid - s.end
                if nearest.map({ gap < $0.gap }) ?? true { nearest = (gap, s.speaker) }
            }
        }
        if !holding.isEmpty {
            return holding.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }.map(\.key)
        }
        if let n = nearest, atLeast(Rule.nearestEdge, n.gap) { return [n.speaker] }
        return []
    }
}

/// keptWords and firstWord (spec 6.2, "Shares and order"): for each speaker, how many of these words
/// have it as their one candidate, and when the first of them starts. Words with no candidate, or
/// several, count for nobody.
func keptCounts(_ words: [Word], _ candidates: [[String]]) -> (counts: [String: Int], first: [String: Double]) {
    var counts: [String: Int] = [:]
    var first: [String: Double] = [:]
    for (word, c) in zip(words, candidates) where c.count == 1 {
        counts[c[0], default: 0] += 1
        first[c[0]] = min(first[c[0]] ?? word.start, word.start)
    }
    return (counts, first)
}

/// A speaker's cosine with the print, or nil when there is no usable print.
private func likeness(_ speaker: SpeakerInfo, _ print: VoicePrint?) -> Double? {
    print.map { cosine(speaker.vector, $0.vector) }
}

/// Each echo pair's lag (call start minus microphone start), decided over the run it belongs to rather
/// than word by word, since each side's stamps jitter by tens of milliseconds. A run is a sequence of
/// pairs whose microphone words follow one another (the same word, or the next one starting within 1.5 s
/// of it), and it takes the median lag of its pairs. A pair on its own takes the lag to the nearest
/// microphone word with the same text within 4 s, since the alignment's choice among equal words is
/// arbitrary. `mic` and `call` are in time order; the result maps each paired call word to its lag.
func echoLags(mic: [Word], call: [Word], pairs: [(micWord: Int, callWord: Int)], bridge: Double = 1.5,
              runWindow: Double = 4.0) -> [Int: Double] {
    let ordered = pairs.sorted { $0.micWord != $1.micWord ? $0.micWord < $1.micWord : $0.callWord < $1.callWord }
    var runs: [[(micWord: Int, callWord: Int)]] = []
    for p in ordered {
        if let last = runs.last?.last, p.micWord == last.micWord
            || (p.micWord == last.micWord + 1 && mic[p.micWord].start - mic[last.micWord].start <= bridge) {
            runs[runs.count - 1].append(p)
        } else {
            runs.append([p])
        }
    }
    var lags: [Int: Double] = [:]
    for run in runs {
        var lag: Double
        if run.count == 1 {
            let p = run[0], t = call[p.callWord].start, key = normalised(call[p.callWord].text)
            lag = t - mic[p.micWord].start
            var a = 0, b = mic.count
            while a < b { let m = (a + b) / 2; if mic[m].start < t - runWindow { a = m + 1 } else { b = m } }
            while a < mic.count && mic[a].start <= t + runWindow {
                if abs(t - mic[a].start) < abs(lag) && normalised(mic[a].text) == key { lag = t - mic[a].start }
                a += 1
            }
        } else {
            let sorted = run.map { call[$0.callWord].start - mic[$0.micWord].start }.sorted()
            lag = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        for p in run { lags[p.callWord] = lag }
    }
    return lags
}

/// One voice heard on both sides of a call: a microphone speaker and a call speaker at a cosine of 0.60
/// or more, neither matching the (usable) print. Their shared words are the echo pairs whose microphone
/// word has the one and whose call word has the other among its candidates; whichever side's copies
/// mostly come later is the echo. A shared word counts as later on the call side only when its call copy
/// is later by a real round trip (`Rule.returnLag`); otherwise the microphone copy counts as the later,
/// since a leak through the speakers lags by less than the transcribers' timing jitter.
/// - micEcho: the far side leaking into the microphone. Its words are dropped.
/// - callEcho: the user's voice coming back on the call side, treated as a print match there.
/// - micUnknown: no shared words, or as many later on each side, so the microphone speaker cannot be
///   told. A speaker that another pairing shows to be an echo, or the source of the call side's echo,
///   is not made Unknown by this one.
func pairVoices(mic: [SpeakerInfo], call: [SpeakerInfo], pairs: [(micWord: Int, callWord: Int)], micWords: [Word], callWords: [Word],
                micCandidates: [[String]], callCandidates: [[String]], print: VoicePrint?)
    -> (micEcho: Set<String>, callEcho: Set<String>, micUnknown: Set<String>) {
    func matchesPrint(_ s: SpeakerInfo) -> Bool { likeness(s, print).map { atLeast($0, Rule.printMatch) } ?? false }
    var micEcho = Set<String>(), callEcho = Set<String>(), micUnknown = Set<String>(), micSource = Set<String>()
    for m in mic where !matchesPrint(m) {
        for c in call where !matchesPrint(c) && atLeast(cosine(m.vector, c.vector), Rule.printMatch) {
            var micLater = 0, callLater = 0
            for p in pairs where p.micWord < micCandidates.count && p.callWord < callCandidates.count
                && micCandidates[p.micWord].contains(m.id) && callCandidates[p.callWord].contains(c.id) {
                if atLeast(callWords[p.callWord].start - micWords[p.micWord].start, Rule.returnLag) { callLater += 1 } else { micLater += 1 }
            }
            if micLater > callLater { micEcho.insert(m.id) }
            else if callLater > micLater { callEcho.insert(c.id); micSource.insert(m.id) }
            else { micUnknown.insert(m.id) }
        }
    }
    return (micEcho, callEcho, micUnknown.subtracting(micEcho).subtracting(micSource))
}

/// The speakers that keep at least one word, in order of their first such word (then their first
/// segment, then their id), and those that keep none, which get no number.
private func byFirstWord(_ speakers: [SpeakerInfo], _ keptWords: [String: Int], _ firstWord: [String: Double])
    -> (numbered: [SpeakerInfo], unnumbered: [SpeakerInfo]) {
    let keeps = speakers.filter { (keptWords[$0.id] ?? 0) > 0 }
    let numbered = keeps.sorted {
        let a = firstWord[$0.id] ?? .infinity, b = firstWord[$1.id] ?? .infinity
        if a != b { return a < b }
        return $0.first != $1.first ? $0.first < $1.first : $0.id < $1.id
    }
    return (numbered, speakers.filter { (keptWords[$0.id] ?? 0) == 0 })
}

/// A speaker's share of a side: its kept words over all the kept words of the speakers counted.
private func share(_ s: SpeakerInfo, _ keptWords: [String: Int], of speakers: [SpeakerInfo]) -> Double {
    let total = speakers.reduce(0) { $0 + (keptWords[$1.id] ?? 0) }
    return total > 0 ? Double(keptWords[s.id] ?? 0) / Double(total) : 0
}

/// Names on the call side (spec 6.2). `print` is the usable print, or nil. The first rule that matches:
/// 1. the user's voice coming back (in `userVoice`, or a print match): Unknown;
/// 2. a cosine of 0.45 or more with the print, or, without a count, under 5% of the side's kept words or
///    a median segment under 2.5 s: plain Them. A count turns off the share and segment-length tests;
///    the voice print tests still apply ("People counts");
/// 3. the rest: one is Them, several are Them 1, Them 2 in order of their first kept word. One with no
///    kept word gets no number and is plain Them.
/// Shares leave out the user's voice.
func nameCall(_ speakers: [SpeakerInfo], keptWords: [String: Int], firstWord: [String: Double], userVoice: Set<String>,
              print: VoicePrint?, counted: Bool) -> [String: String] {
    func isUser(_ s: SpeakerInfo) -> Bool {
        userVoice.contains(s.id) || likeness(s, print).map { atLeast($0, Rule.printMatch) } == true
    }
    let others = speakers.filter { !isUser($0) }
    var names: [String: String] = [:]
    var rest: [SpeakerInfo] = []
    for s in speakers {
        if isUser(s) {
            names[s.id] = "Unknown"
        } else if likeness(s, print).map({ atLeast($0, Rule.printNear) }) == true
                    || (!counted && (!atLeast(share(s, keptWords, of: others), Rule.smallShare) || !atLeast(s.median, Rule.shortMedian))) {
            names[s.id] = "Them"
        } else {
            rest.append(s)
        }
    }
    let (numbered, unnumbered) = byFirstWord(rest, keptWords, firstWord)
    for (k, s) in numbered.enumerated() { names[s.id] = numbered.count == 1 ? "Them" : "Them \(k + 1)" }
    for s in unnumbered { names[s.id] = "Them" }
    return names
}

/// Names on the microphone side (spec 6.2). Echo speakers get no name: their words are dropped.
/// `print` is the usable print, or nil. The first rule that matches:
/// 0. paired with a call voice but impossible to tell (in `unknown`): Unknown;
/// 1. a print match with 10 s or more of talk: Me;
/// 2. on a call, 80% or more of the kept words, with no print or a cosine of 0.45 or more with it: Me;
/// 3. a cosine of 0.45 or more with the print: Unknown;
/// 4. without a count: under 5% of the kept words, or a median segment under 2.5 s: Unknown;
/// 5. otherwise Room 1, Room 2, numbered by first kept word; one with no kept word is Unknown.
/// Shares leave out the echo speakers.
func nameMic(_ speakers: [SpeakerInfo], keptWords: [String: Int], firstWord: [String: Double], echo: Set<String>, unknown: Set<String>,
             print: VoicePrint?, isCall: Bool, counted: Bool) -> [String: String] {
    let live = speakers.filter { !echo.contains($0.id) }
    var names: [String: String] = [:]
    var rest: [SpeakerInfo] = []
    for s in live {
        let like = likeness(s, print)
        let part = share(s, keptWords, of: live)
        if unknown.contains(s.id) {
            names[s.id] = "Unknown"
        } else if let c = like, atLeast(c, Rule.printMatch), atLeast(s.seconds, Rule.meSeconds) {
            names[s.id] = "Me"
        } else if isCall, atLeast(part, Rule.dominantShare), like.map({ atLeast($0, Rule.printNear) }) ?? true {
            names[s.id] = "Me"
        } else if let c = like, atLeast(c, Rule.printNear) {
            names[s.id] = "Unknown"
        } else if !counted, !atLeast(part, Rule.smallShare) || !atLeast(s.median, Rule.shortMedian) {
            names[s.id] = "Unknown"
        } else {
            rest.append(s)
        }
    }
    let (numbered, unnumbered) = byFirstWord(rest, keptWords, firstWord)
    for (k, s) in numbered.enumerated() { names[s.id] = "Room \(k + 1)" }
    for s in unnumbered { names[s.id] = "Unknown" }
    return names
}

/// The label of a word with no candidate: the side's one label when every named speaker there has
/// it; Me or Them on a side with no speakers; otherwise Unknown on the microphone side and Them on the call side.
func fallbackLabel(_ names: [String: String], side: Side) -> String {
    let labels = Set(names.values)
    if labels.count == 1, let only = labels.first { return only }
    if labels.isEmpty { return side == .mic ? "Me" : "Them" }
    return side == .mic ? "Unknown" : "Them"
}

/// The words, `words` in time order, as sentences: each runs up to and including a word ending in
/// `.`, `?` or `!`.
private func sentences(_ words: [Word]) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0
    for (i, w) in words.enumerated() where w.text.last.map({ ".?!".contains($0) }) == true {
        ranges.append(start..<(i + 1))
        start = i + 1
    }
    if start < words.count { ranges.append(start..<words.count) }
    return ranges
}

/// Each word's label, `words` in time order with their candidates as `candidates` gives them. A word
/// whose candidates have one label takes it; one with none takes `fallback`. One with two or more
/// different labels takes the label most words of its sentence with exactly one candidate label hold,
/// and a tie goes to the label of the latest-starting segment among them.
func resolve(_ words: [Word], _ candidates: [[String]], names: [String: String], fallback: String) -> [String] {
    // Each word's candidate labels, each placed where its latest-starting segment is, so the last is the latest.
    let options: [[String]] = words.indices.map { i in
        var labels: [String] = []
        for id in i < candidates.count ? candidates[i] : [] {
            guard let label = names[id] else { continue }
            labels.removeAll { $0 == label }
            labels.append(label)
        }
        return labels
    }
    var labels = [String](repeating: fallback, count: words.count)
    for range in sentences(words) {
        var votes: [String: Int] = [:]
        for i in range where options[i].count == 1 { votes[options[i][0], default: 0] += 1 }
        for i in range where !options[i].isEmpty {
            let best = options[i].map { votes[$0] ?? 0 }.max() ?? 0
            labels[i] = options[i].last { (votes[$0] ?? 0) == best } ?? fallback
        }
    }
    return labels
}

/// Smoothing, on labels after naming (so two clusters both named Me are one run). The runs of equal
/// labels in each sentence are found once; then, in one pass, a run of one or two words with the same
/// label on both sides takes that label, and a single word at a sentence's start or end takes the label
/// of its neighbouring run when that run has three or more words.
func smooth(_ labels: [String], _ words: [Word]) -> [String] {
    var out = labels
    for range in sentences(words) where range.upperBound <= labels.count {
        var runs: [(label: String, start: Int, count: Int)] = []
        for i in range {
            if let last = runs.last, last.label == labels[i] { runs[runs.count - 1].count += 1 }
            else { runs.append((labels[i], i, 1)) }
        }
        guard runs.count > 1 else { continue }
        for (k, run) in runs.enumerated() {
            var to: String?
            if k > 0 && k + 1 < runs.count {
                if run.count <= 2 && runs[k - 1].label == runs[k + 1].label { to = runs[k - 1].label }
            } else if run.count == 1 {
                let neighbour = k == 0 ? runs[1] : runs[k - 1]
                if neighbour.count >= 3 { to = neighbour.label }
            }
            if let label = to { for i in run.start..<(run.start + run.count) { out[i] = label } }
        }
    }
    return out
}

/// Both sides' words with their labels, what the meeting's log says about them, and what learning the
/// voice needs.
struct LabelledWords {
    var mic: [Word] = []
    var micLabels: [String] = []
    var call: [Word] = []
    var callLabels: [String] = []
    var log: [String] = []
    var isCall = false
    var model = ""                          // the speaker model of this run, "" without speakers
    var micSpeakers: [SpeakerInfo] = []     // the microphone's speakers that are not echo
    var micKept: [String: Int] = [:]        // their kept words
    var callSpeakers: [SpeakerInfo] = []
}

private func inTimeOrder(_ words: [Word]) -> [Word] {
    words.indices.sorted { words[$0].start != words[$1].start ? words[$0].start < words[$1].start : $0 < $1 }.map { words[$0] }
}

private func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

/// Words to labels (spec 6.2, steps 2 to 7 of mb-transcript): candidates on both sides; the call
/// side's print matches; echo pairs and one voice heard on both sides; echo removed from the
/// microphone against the call words that are not the user's voice, and the user's call-side repeats
/// dropped; both sides named; labels resolved and smoothed. `mic` and `call` have their ends capped.
/// A side without speakers is Me, or Them, throughout.
func labelWords(mic micIn: [Word], call callIn: [Word], micSpeakers: SideSpeakers?, callSpeakers: SideSpeakers?, print: VoicePrint?,
                micCounted: Bool = false, callCounted: Bool = false) -> LabelledWords {
    let mic = inTimeOrder(micIn), call = inTimeOrder(callIn)
    let micSp = micSpeakers?.speakers ?? [], callSp = callSpeakers?.speakers ?? []
    var result = LabelledWords()
    result.model = micSpeakers?.model ?? callSpeakers?.model ?? ""
    let usable = usablePrint(print, model: result.model)

    // Candidates on both sides.
    let micCandidates = micSpeakers.map { candidates(mic, $0.segments) } ?? mic.map { _ in [] }
    let callCandidates = callSpeakers.map { candidates(call, $0.segments) } ?? call.map { _ in [] }

    // The call side's print matches: the user's voice coming back.
    var userVoice = Set(callSp.filter { likeness($0, usable).map { atLeast($0, Rule.printMatch) } == true }.map(\.id))

    // removeEcho's pairs over both whole sides (made once, when needed), then one voice heard on both
    // sides, on a call.
    var alignment: [(micWord: Int, callWord: Int)]?
    func aligned() -> [(micWord: Int, callWord: Int)] {
        if let a = alignment { return a }
        let a = matchEcho(mic: mic, call: call).pairs
        alignment = a
        return a
    }
    result.isCall = isCall(callWords: call, callSpeakers: callSpeakers?.speakers)
    var voices: (micEcho: Set<String>, callEcho: Set<String>, micUnknown: Set<String>) = ([], [], [])
    if result.isCall && !micSp.isEmpty && !callSp.isEmpty {
        voices = pairVoices(mic: micSp, call: callSp, pairs: aligned(), micWords: mic, callWords: call,
                            micCandidates: micCandidates, callCandidates: callCandidates, print: usable)
    }
    userVoice.formUnion(voices.callEcho)

    // Echo: the microphone against the call words that are not the user's voice, so the user's voice
    // on the call side never cancels the user's own words. Then the words of a microphone echo
    // speaker, and the user's call-side words that repeat the microphone words kept.
    // A call word whose candidates are all the user's voice is the user's. One whose candidates mix the
    // user's voice with a far-side speaker (overlapping segments) is the user's voice coming back only
    // when, in the alignment of both whole sides, its run (or, alone, its nearest same word) lags the
    // microphone by a real round trip (`Rule.returnLag`). Otherwise it stays in echo removal, where a
    // far-side word that leaked into the microphone is still dropped.
    let allUser = Set(call.indices.filter { !callCandidates[$0].isEmpty && callCandidates[$0].allSatisfy(userVoice.contains) })
    let mixed = call.indices.filter { !allUser.contains($0) && callCandidates[$0].contains(where: userVoice.contains) }
    var cameBack = Set<Int>()
    if !mixed.isEmpty {
        let lags = echoLags(mic: mic, call: call, pairs: aligned())
        for j in mixed where lags[j].map({ atLeast($0, Rule.returnLag) }) == true { cameBack.insert(j) }
    }
    let mine = call.indices.filter { allUser.contains($0) || cameBack.contains($0) }
    let mineSet = Set(mine)
    let echo = matchEcho(mic: mic, call: call.indices.filter { !mineSet.contains($0) }.map { call[$0] }).echo
    var leaked = 0
    let micKept = mic.indices.filter { i in
        if echo.contains(i) { return false }
        if !micCandidates[i].isEmpty && micCandidates[i].allSatisfy(voices.micEcho.contains) { leaked += 1; return false }
        return true
    }
    let repeats = matchEcho(mic: mine.map { call[$0] }, call: micKept.map { mic[$0] }).echo   // positions in `mine`
    let repeated = Set(repeats.map { mine[$0] })
    let callKept = call.indices.filter { !repeated.contains($0) }
    if leaked > 0 {
        result.log.append("Left out \(plural(leaked, "microphone word")) that \(leaked == 1 ? "was" : "were") the call heard through the speakers")
    }
    // Marked Unknown: the user's voice left on the call side, which is only a word whose candidates are all
    // the user's voice (a mixed word left over is resolved by its sentence, and may be Them).
    let left = mine.filter { allUser.contains($0) && !repeated.contains($0) }.count
    if repeats.count + left > 0 {
        result.log.append("Your voice was heard on the call side: \(plural(repeats.count, "word")) repeating yours "
                          + "\(repeats.count == 1 ? "was" : "were") left out, and \(left) \(left == 1 ? "is" : "are") marked Unknown")
    }

    // Names.
    let micWords = micKept.map { mic[$0] }, micKeptCandidates = micKept.map { micCandidates[$0] }
    let callWords = callKept.map { call[$0] }, callKeptCandidates = callKept.map { callCandidates[$0] }
    let micCounts = keptCounts(micWords, micKeptCandidates), callCounts = keptCounts(callWords, callKeptCandidates)
    let micNames = nameMic(micSp, keptWords: micCounts.counts, firstWord: micCounts.first, echo: voices.micEcho,
                           unknown: voices.micUnknown, print: usable, isCall: result.isCall, counted: micCounted)
    let callNames = nameCall(callSp, keptWords: callCounts.counts, firstWord: callCounts.first, userVoice: userVoice,
                             print: usable, counted: callCounted)
    let live = micSp.filter { !voices.micEcho.contains($0.id) }
    if let p = usable, !live.isEmpty, !micNames.values.contains("Me") {
        let best = live.map { cosine($0.vector, p.vector) }.max() ?? 0
        result.log.append(String(format: "Your voice was not recognised on the microphone side (best match %.2f)", best))
    } else if usable == nil, !result.isCall, !live.isEmpty {
        result.log.append("Your voice is not learnt yet, so nobody in this room recording is labelled Me")
    }

    // Labels, resolved and smoothed.
    result.mic = micWords
    result.micLabels = smooth(resolve(micWords, micKeptCandidates, names: micNames, fallback: fallbackLabel(micNames, side: .mic)), micWords)
    result.call = callWords
    result.callLabels = smooth(resolve(callWords, callKeptCandidates, names: callNames, fallback: fallbackLabel(callNames, side: .call)), callWords)
    result.micSpeakers = live
    result.micKept = micCounts.counts.filter { id, _ in live.contains { $0.id == id } }
    result.callSpeakers = callSp
    return result
}

/// The transcript's lines from labelled words: joinLines over one stream per label, or with tidying off
/// (`plain`), mergeTurns over the same streams, so a line starts at every change of label. Labels come
/// in the order they are first used, the microphone side's first.
func transcriptLines(_ labelled: LabelledWords, plain: Bool) -> [Turn] {
    var order: [String] = []
    var byLabel: [String: [Word]] = [:]
    for (word, label) in Array(zip(labelled.mic, labelled.micLabels)) + Array(zip(labelled.call, labelled.callLabels)) {
        if byLabel[label] == nil { order.append(label) }
        byLabel[label, default: []].append(word)
    }
    let streams = order.map { (label: $0, words: byLabel[$0] ?? []) }
    return plain ? mergeTurns(streams) : joinLines(streams)
}
