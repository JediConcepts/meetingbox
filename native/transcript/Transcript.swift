// Merges the mic and call transcripts into labelled lines: tidy lines that follow sentences,
// or with tidying off, a line per turn.
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
    for (k, pair) in chain.enumerated() {
        let inRun = (k > 0 && chain[k - 1].i == pair.i - 1) || (k + 1 < chain.count && chain[k + 1].i == pair.i + 1)
        let dt = abs(mic[m[pair.i]].start - call[c[pair.j]].start)
        if inRun || dt <= window { echo[pair.i] = true }
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
        }
    }
    for i in m.indices where !echo[i] && !mk[i].isEmpty {
        let near = callNear(mic[m[i]].start)
        if let j = near.first(where: { $0 + 1 < near.upperBound && !used.contains($0) && !used.contains($0 + 1)
                                        && !ck[$0].isEmpty && !ck[$0 + 1].isEmpty && ck[$0] + ck[$0 + 1] == mk[i] }) {
            echo[i] = true; used.insert(j); used.insert(j + 1)
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
    return mic.indices.filter { !drop.contains($0) }.map { mic[$0] }
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
