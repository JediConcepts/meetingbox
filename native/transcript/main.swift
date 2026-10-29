// mb-transcript --mic FILE --call FILE: prints the merged Me and Them transcript.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mb-transcript: \(message)\n".utf8))
    exit(1)
}

var micPath: String?
var callPath: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--mic": micPath = args.isEmpty ? nil : args.removeFirst()
    case "--call": callPath = args.isEmpty ? nil : args.removeFirst()
    default: fail("usage: mb-transcript --mic FILE --call FILE")
    }
}

/// A missing or empty file counts as no words.
func words(_ path: String?) -> [Word] {
    guard let path = path, let data = FileManager.default.contents(atPath: path) else { return [] }
    do { return try loadWords(data) } catch { fail("cannot read \(path): \(error)") }
}

let call = words(callPath)
let mic = removeEcho(mic: words(micPath), call: call)
if mic.isEmpty && call.isEmpty { fail("no speech found on either channel") }
print(render(mergeTurns([("Me", mic), ("Them", call)])), terminator: "")
