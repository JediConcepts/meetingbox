// sources: ../../speech/Sources/mb-speech/Shape.swift ../../speech/Sources/mb-speech/Fetch.swift
// mb-speech's FluidAudio-free parts: the pinned manifest, file checks, `check` and `fetch` (with a
// stand-in downloader), and the speakers JSON with its exclusive copy. No network, no models: every
// file here is made in a temporary folder.
import CryptoKit
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

let speech = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("speech")
let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("mb-speech-test-\(getpid())")
try? fm.removeItem(at: scratch)
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func reason(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch let error as SpeechError { return error.reason } catch { return "\(error)" }
}

// The repository's manifest parses and pins both models.
let source = try? parseManifest(Data(contentsOf: speech.appendingPathComponent("models.json")))
check(source != nil, "manifest: native/speech/models.json parses")
check(source?.models.map(\.folder) == ["parakeet-ultra", "speaker-diarization"],
      "manifest: folders are FluidAudio's own, parakeet-ultra and speaker-diarization")
check(source?.revisionPins["FluidInference/speaker-diarization-coreml"] == "df2625ac79a7ac6b65ad868fee6d80f320da4232",
      "manifest: the diariser is pinned at df2625ac")
check(source?.revisionPins["FluidInference/parakeet-ultra-coreml"]?.count == 40, "manifest: Ultra is pinned at a commit")
check(source?.models.allSatisfy { !$0.files.isEmpty } == true, "manifest: every model lists its files")

// A manifest that could name a path outside its folder, or is not pinned, is refused.
func manifest(revision: String = String(repeating: "a", count: 40), folder: String = "m", path: String = "x/y.bin") -> Data {
    let text = """
    {"models": [{"name": "m", "repo": "Owner/m-coreml", "revision": "\(revision)", "folder": "\(folder)",
                 "files": [{"path": "\(path)", "size": 3, "sha256": "\(String(repeating: "0", count: 64))"}]}]}
    """
    return Data(text.utf8)
}
check(reason { _ = try parseManifest(manifest()) } == nil, "manifest: a plain one parses")
check(reason { _ = try parseManifest(manifest(revision: "main")) } != nil, "manifest: a branch name is refused")
check(reason { _ = try parseManifest(manifest(folder: "..")) } != nil, "manifest: folder .. is refused")
check(reason { _ = try parseManifest(manifest(folder: "a/b")) } != nil, "manifest: a folder with / is refused")
check(reason { _ = try parseManifest(manifest(path: "../evil")) } != nil, "manifest: a path with .. is refused")
check(reason { _ = try parseManifest(manifest(path: "/etc/x")) } != nil, "manifest: an absolute path is refused")
check(reason { _ = try parseManifest(Data("{}".utf8)) } != nil, "manifest: no models is refused")

// verifyFile: size and SHA-256, the path in every reason.
let folder = scratch.appendingPathComponent("folder")
try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
let body = Data("abc".utf8)
try! body.write(to: folder.appendingPathComponent("f.bin"))
let filePath = folder.appendingPathComponent("f.bin").path
check(verifyFile(ManifestFile(path: "f.bin", size: 3, sha256: hex(body)), in: folder) == nil, "verify: right size and hash passes")
let wrongSize = verifyFile(ManifestFile(path: "f.bin", size: 4, sha256: hex(body)), in: folder)
check(wrongSize?.contains(filePath) == true, "verify: a wrong size fails with the path in the reason")
let wrongHash = verifyFile(ManifestFile(path: "f.bin", size: 3, sha256: hex(Data("abd".utf8))), in: folder)
check(wrongHash?.contains(filePath) == true, "verify: a wrong hash fails with the path in the reason")
check(verifyFile(ManifestFile(path: "gone.bin", size: 3, sha256: hex(body)), in: folder)?.contains("gone.bin") == true,
      "verify: a missing file fails with its path")

// check: an installed models folder as fetch leaves it.
let revision = String(repeating: "b", count: 40)
let models = scratch.appendingPathComponent("models")
let model = models.appendingPathComponent("m")
try! fm.createDirectory(at: model.appendingPathComponent("x"), withIntermediateDirectories: true)
try! body.write(to: model.appendingPathComponent("x/y.bin"))
for marker in revisionMarkers { try! Data((revision + "\n").utf8).write(to: model.appendingPathComponent(marker)) }
try! manifest(revision: revision).write(to: models.appendingPathComponent("models.json"))
check(checkModels(at: models) == nil, "check: a complete folder passes")

try! Data("cccc".utf8).write(to: model.appendingPathComponent("x/y.bin"))
check(checkModels(at: models)?.contains("y.bin") == true, "check: a file of the wrong size fails, naming it")
try! fm.removeItem(at: model.appendingPathComponent("x/y.bin"))
check(checkModels(at: models)?.contains("y.bin") == true, "check: a missing file fails, naming it")
try! body.write(to: model.appendingPathComponent("x/y.bin"))
try! Data(String(repeating: "c", count: 40).utf8).write(to: model.appendingPathComponent(".fluidaudio-revision"))
check(checkModels(at: models)?.contains(".fluidaudio-revision") == true, "check: a marker of another revision fails")
try! fm.removeItem(at: model.appendingPathComponent(".fluidaudio-revision"))
check(checkModels(at: models) != nil, "check: a missing marker fails")
check(checkModels(at: scratch.appendingPathComponent("empty")) != nil, "check: no models.json fails")

// writePrivately: 0600, renamed into place, nothing left beside it.
let target = scratch.appendingPathComponent("out.json")
check(reason { try writePrivately(body, to: target) } == nil, "write: succeeds")
let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
check(mode == 0o600, "write: the file is 0600")
check(!fm.fileExists(atPath: scratch.appendingPathComponent(".part-out.json").path), "write: no temporary name is left")

// mergeTokens: Parakeet's tokens to words, as FluidAudio's own word builder has no confidence.
let merged = mergeTokens([
    Token(text: " Hel", start: 1.2, end: 1.3, confidence: 0.99),
    Token(text: "lo,", start: 1.3, end: 1.48, confidence: 0.97),
    Token(text: "<blank>", start: 1.5, end: 1.6, confidence: 0.1),
    Token(text: "", start: 1.6, end: 1.7, confidence: 0.1),
    Token(text: "<pad>", start: 1.7, end: 1.8, confidence: 0.1),
    Token(text: " world", start: 2.0, end: 2.4, confidence: 0.9),
    Token(text: "'s", start: 2.4, end: 2.5, confidence: 0.95),
])
check(merged.map(\.text) == ["Hello,", "world's"], "merge: a token starting with a space starts a word, others join it \(merged.map(\.text))")
check(merged.first?.start == 1.2 && merged.first?.end == 1.48, "merge: start is the first token's start, end the last token's end")
check(merged.first?.confidence == 0.97 && merged.last?.confidence == 0.9, "merge: confidence is the lowest of the word's tokens")
check(mergeTokens([Token(text: "<blank>", start: 0, end: 1, confidence: 1)]).isEmpty, "merge: blank and pad tokens make no word")
let spaced = mergeTokens([Token(text: " at", start: 0, end: 0.2, confidence: 1), Token(text: " ", start: 0.2, end: 0.3, confidence: 1),
                          Token(text: "40", start: 0.3, end: 0.6, confidence: 1), Token(text: "\u{2581}", start: 0.6, end: 0.7, confidence: 1),
                          Token(text: "$5", start: 0.7, end: 0.9, confidence: 1)])
check(spaced.map(\.text) == ["at", "40", "$5"], "merge: a token that is only a space ends the word, as FluidAudio's own rule \(spaced.map(\.text))")
let wordsData = wordsJSON(engine: "parakeet-ultra", words: [Word(start: 1.2, end: 1.48, text: "Hello, \"you\"", confidence: 0.97)])
let parsed = (try? JSONSerialization.jsonObject(with: wordsData)) as? [String: Any]
let firstWord = (parsed?["words"] as? [[String: Any]])?.first
check(parsed?["engine"] as? String == "parakeet-ultra" && (parsed?["words"] as? [Any])?.count == 1,
      "words JSON: engine and words, as the contract says")
check(firstWord?["start"] as? Double == 1.2 && firstWord?["end"] as? Double == 1.48 && firstWord?["text"] as? String == "Hello, \"you\""
      && firstWord?["confidence"] as? Double == 0.97, "words JSON: start, end, text and confidence per word \(firstWord ?? [:])")
let emptyWords = (try? JSONSerialization.jsonObject(with: wordsJSON(engine: "parakeet-ultra", words: []))) as? [String: Any]
check((emptyWords?["words"] as? [Any])?.isEmpty == true, "words JSON: no words is an empty list")

// No source may ask FluidAudio to download, recover or clear models on its own.
let banned = ["prepareModels", "AsrModels.download", "downloadAndLoad", "loadFromCache", "loadWithAutoRecovery",
              "ModelHub.clearCache"]
let sources = (try? fm.contentsOfDirectory(atPath: speech.appendingPathComponent("Sources/mb-speech").path)) ?? []
check(sources.contains("main.swift") && sources.contains("Fetch.swift"), "sources: the helper's sources are found")
var found: [String] = []
for name in sources where name.hasSuffix(".swift") {
    let text = (try? String(contentsOf: speech.appendingPathComponent("Sources/mb-speech/\(name)"), encoding: .utf8)) ?? ""
    found += banned.filter { text.contains($0) }.map { "\(name): \($0)" }
}
check(found.isEmpty, "sources: none of the banned FluidAudio calls appear \(found)")

// main.swift turns offline mode on, and console mirroring off, before it reads any argument.
let mainText = (try? String(contentsOf: speech.appendingPathComponent("Sources/mb-speech/main.swift"), encoding: .utf8)) ?? ""
let firstArgument = mainText.range(of: "CommandLine.arguments")?.lowerBound
for statement in ["ModelHub.offlineMode = true", "AppLogger.mirrorsToConsole = false"] {
    let at = mainText.range(of: statement)?.lowerBound
    check(at != nil && firstArgument != nil && at! < firstArgument!, "main.swift: \(statement) comes before any argument is read")
}
// FluidAudio's offline diariser writes "[Profiling]" lines straight to stderr. The one reason line
// goes to a kept copy of stderr, and everything else written there goes to /dev/null, from before
// any argument is read.
let quieted = mainText.range(of: "dup2(")?.lowerBound
check(quieted != nil && firstArgument != nil && quieted! < firstArgument!,
      "main.swift: stderr is sent to /dev/null before any argument is read")
check(!mainText.contains("FileHandle.standardError"), "main.swift: the reason line is written to the kept stderr, not fd 2")

// fetch: every changed model is downloaded and verified before any is swapped in, so a failed
// download leaves a working install as it was; a model already at its revision is not fetched again.
func entry(_ path: String, _ body: Data) -> String { "{\"path\": \"\(path)\", \"size\": \(body.count), \"sha256\": \"\(hex(body))\"}" }
func twoModels(_ revA: String, _ a: Data, _ revB: String, _ b: Data) -> URL {
    let url = scratch.appendingPathComponent("manifest-\(UUID().uuidString).json")
    try! Data("""
    {"models": [{"name": "a", "repo": "Owner/a-coreml", "revision": "\(revA)", "folder": "a", "files": [\(entry("w/a.bin", a))]},
                {"name": "b", "repo": "Owner/b-coreml", "revision": "\(revB)", "folder": "b", "files": [\(entry("b.bin", b))]}]}
    """.utf8).write(to: url)
    return url
}
var requested: [String] = []
func serving(_ bodies: [String: Data], failing: String? = nil) -> Download {
    return { url, target in
        requested.append(url.lastPathComponent)
        if url.lastPathComponent == failing { throw SpeechError(reason: "\(url.absoluteString) answered 404") }
        try bodies[url.lastPathComponent]!.write(to: target)
    }
}
let store = scratch.appendingPathComponent("store")
try! fm.createDirectory(at: store, withIntermediateDirectories: true)
func fetchReason(_ manifest: URL, _ download: @escaping Download) async -> String? {
    do { try await fetchModels(into: store, manifestAt: manifest, download: download); return nil }
    catch let error as SpeechError { return error.reason } catch { return "\(error)" }
}
func snapshot() -> [Data?] {
    ["models.json", "a/w/a.bin", "a/.revision", "a/.fluidaudio-revision", "b/b.bin", "b/.revision", "b/.fluidaudio-revision"]
        .map { try? Data(contentsOf: store.appendingPathComponent($0)) }
}
let rev1 = String(repeating: "1", count: 40), rev2 = String(repeating: "2", count: 40)
let oldA = Data("old a".utf8), oldB = Data("old b".utf8), newA = Data("new a".utf8), newB = Data("new b".utf8)
let first = await fetchReason(twoModels(rev1, oldA, rev1, oldB), serving(["a.bin": oldA, "b.bin": oldB]))
check(first == nil && checkModels(at: store) == nil, "fetch: two models install and pass check \(first ?? "")")

let before = snapshot()
let failed = await fetchReason(twoModels(rev2, newA, rev2, newB), serving(["a.bin": newA, "b.bin": newB], failing: "b.bin"))
check(failed?.contains("404") == true, "fetch: a failed download is the reason")
check(snapshot() == before, "fetch: after a failed download both old folders and models.json are byte-identical")
check(checkModels(at: store) == nil, "fetch: after a failed download check still passes")

requested = []
let one = await fetchReason(twoModels(rev1, oldA, rev2, newB), serving(["b.bin": newB]))
check(one == nil && requested == ["b.bin"], "fetch: a model already at its revision is not downloaded again \(requested)")
check(checkModels(at: store) == nil && (try? Data(contentsOf: store.appendingPathComponent("b/b.bin"))) == newB,
      "fetch: the changed model is swapped in and check passes")
let leftovers = ((try? fm.contentsOfDirectory(atPath: store.path)) ?? []).filter { $0.hasPrefix(".part-") || $0.hasPrefix(".old-") }
check(leftovers.isEmpty, "fetch: no .part- or .old- folder is left after a good fetch \(leftovers)")

// The exclusive copy, by FluidAudio's own rule: sorted by start, a segment starting before the last
// kept one ends starts at that end instead, and is dropped if under 1.0 s is left.
func seg(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSegment {
    SpeakerSegment(speaker: speaker, start: start, end: end)
}
let overlapping = [seg("S2", 3.0, 9.0), seg("S1", 0.0, 5.0)]
check(exclusiveCopy(overlapping) == [seg("S1", 0.0, 5.0), seg("S2", 5.0, 9.0)],
      "exclusive: the later of two overlapping segments starts where the earlier ends \(exclusiveCopy(overlapping))")
let pairTalk = speakerTalk(overlapping)
check(pairTalk["S1"] == SpeakerTalk(seconds: 5.0, median: 5.0) && pairTalk["S2"] == SpeakerTalk(seconds: 4.0, median: 4.0),
      "exclusive: two overlapping segments give S1 5 s (median 5 s) and S2 4 s (median 4 s) \(pairTalk)")
check(exclusiveCopy([seg("S1", 0.0, 5.0), seg("S2", 4.0, 5.8)]) == [seg("S1", 0.0, 5.0)],
      "exclusive: a segment with under 1.0 s left is dropped")
check(exclusiveCopy([seg("S1", 0.0, 5.0), seg("S2", 4.0, 6.0)]) == [seg("S1", 0.0, 5.0), seg("S2", 5.0, 6.0)],
      "exclusive: a segment with exactly 1.0 s left is kept")
check(exclusiveCopy([seg("S1", 0.0, 10.0), seg("S2", 2.0, 4.0), seg("S3", 5.0, 12.0)])
      == [seg("S1", 0.0, 10.0), seg("S3", 10.0, 12.0)],
      "exclusive: a segment inside the last kept one is dropped, the next starts at the kept one's end")
check(exclusiveCopy([seg("S1", 1.0, 5.0), seg("S2", 1.0, 3.0)]) == [seg("S2", 1.0, 3.0), seg("S1", 3.0, 5.0)],
      "exclusive: equal starts go by end, as FluidAudio sorts them")
check(exclusiveCopy([seg("S2", 1.0, 3.0), seg("S1", 1.0, 3.0)]) == [seg("S1", 1.0, 3.0)],
      "exclusive: equal starts and ends go by speaker, as FluidAudio sorts them")
let several = speakerTalk([seg("S1", 0, 2), seg("S1", 10, 14), seg("S1", 20, 23), seg("S2", 30, 32), seg("S2", 40, 45),
                           seg("S3", 31, 32)])
check(several["S1"] == SpeakerTalk(seconds: 9, median: 3) && several["S2"] == SpeakerTalk(seconds: 7, median: 3.5),
      "talk: total seconds, and the median segment (the middle two averaged when even) \(several)")
check(several["S3"] == SpeakerTalk(seconds: 0, median: 0), "talk: a speaker with nothing left in the exclusive copy has 0 and 0")

// The speakers JSON: the overlapping segments as found, and each speaker's talk from the exclusive copy.
let vectors: [String: [Float]] = ["S1": (0..<256).map { Float($0) / 256 }, "S2": Array(repeating: -0.5, count: 256)]
let speakersData = try? speakersJSON(model: "FluidInference/speaker-diarization-coreml@df2625ac79a7ac6b65ad868fee6d80f320da4232",
                                     segments: overlapping, vectors: vectors)
let speakersRoot = speakersData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
let speakerSegments = speakersRoot?["segments"] as? [[String: Any]] ?? []
let speakerList = speakersRoot?["speakers"] as? [[String: Any]] ?? []
check(speakersRoot?["model"] as? String == "FluidInference/speaker-diarization-coreml@df2625ac79a7ac6b65ad868fee6d80f320da4232",
      "speakers JSON: the model is repo@revision")
check(speakerSegments.map { "\($0["speaker"] ?? "")" } == ["S1", "S2"] && speakerSegments.last?["start"] as? Double == 3.0
      && speakerSegments.last?["end"] as? Double == 9.0,
      "speakers JSON: segments overlap, as found, in start order \(speakerSegments)")
check(speakerList.map { "\($0["id"] ?? "")" } == ["S1", "S2"] && speakerList.first?["seconds"] as? Double == 5.0
      && speakerList.last?["seconds"] as? Double == 4.0 && speakerList.last?["median"] as? Double == 4.0,
      "speakers JSON: each speaker's seconds and median come from the exclusive copy \(speakerList.map { [$0["id"], $0["seconds"], $0["median"]] })")
let firstVector = (speakerList.first?["vector"] as? [Double]) ?? []
check(firstVector.count == 256 && firstVector[128] == 0.5 && (speakerList.last?["vector"] as? [Double])?.allSatisfy { $0 == -0.5 } == true,
      "speakers JSON: each speaker's vector is its raw 256 values")
check(reason { _ = try speakersJSON(model: "m@r", segments: overlapping, vectors: ["S1": [1]]) } != nil,
      "speakers JSON: a speaker without a vector is refused")
let noSpeech = (try? speakersJSON(model: "m@r", segments: [], vectors: [:])).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    as? [String: Any]
check((noSpeech?["segments"] as? [Any])?.isEmpty == true && (noSpeech?["speakers"] as? [Any])?.isEmpty == true
      && noSpeech?["model"] as? String == "m@r", "speakers JSON: no speech gives empty segments and speakers")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
