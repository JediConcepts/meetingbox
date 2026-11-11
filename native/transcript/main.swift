// mb-transcript --mic FILE --call FILE [--plain]: prints the transcript, labelled Me and Them.
// Lines follow sentences, with short replies inline and fillers dropped. With --plain (tidying
// off), a new line starts at every change of speaker and every word is kept.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mb-transcript: \(message)\n".utf8))
    exit(1)
}

var micPath: String?
var callPath: String?
var plain = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--mic": micPath = args.isEmpty ? nil : args.removeFirst()
    case "--call": callPath = args.isEmpty ? nil : args.removeFirst()
    case "--plain": plain = true
    default: fail("usage: mb-transcript --mic FILE --call FILE [--plain]")
    }
}

/// A missing, empty or unreadable file counts as no words, so one bad side
/// still leaves the other side's transcript. Word ends are capped as they load.
func words(_ path: String?) -> [Word] {
    guard let path = path, let data = FileManager.default.contents(atPath: path) else { return [] }
    do { return capEnds(try loadWords(data)) } catch {
        FileHandle.standardError.write(Data("mb-transcript: cannot read \(path), carrying on without it: \(error)\n".utf8))
        return []
    }
}

let call = words(callPath)
let mic = removeEcho(mic: words(micPath), call: call)
let streams: [(label: String, words: [Word])] = [("Me", mic), ("Them", call)]
let turns = plain ? mergeTurns(streams) : joinLines(streams)
if turns.isEmpty { fail("no speech found on either channel") }
print(render(turns), terminator: "")
