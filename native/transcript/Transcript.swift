// Merges the mic and call transcripts into Me and Them turns.
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

/// One line per turn: [HH:MM:SS] Label: text
func render(_ turns: [Turn]) -> String {
    turns.map { t in
        let s = Int(t.start.rounded(.down))
        return String(format: "[%02d:%02d:%02d] %@: %@\n", s / 3600, (s / 60) % 60, s % 60, t.label, t.text)
    }.joined()
}
