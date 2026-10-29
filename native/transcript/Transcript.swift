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

/// Drops a mic word when a call word with the same non-empty text starts within `window`
/// seconds of it. Each call word can cancel at most one mic word.
func removeEcho(mic: [Word], call: [Word], window: Double = 0.6) -> [Word] {
    var used = [Bool](repeating: false, count: call.count)
    let callKeys = call.map { normalised($0.text) }
    return mic.filter { m in
        let key = normalised(m.text)
        if key.isEmpty { return true }
        var best: Int?
        for (i, c) in call.enumerated() where !used[i] && callKeys[i] == key {
            let d = abs(c.start - m.start)
            if d <= window, best == nil || d < abs(call[best!].start - m.start) { best = i }
        }
        guard let hit = best else { return true }
        used[hit] = true
        return false
    }
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
