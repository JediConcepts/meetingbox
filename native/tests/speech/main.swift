// sources: ../../speech/Sources/mb-speech/Shape.swift ../../speech/Sources/mb-speech/Fetch.swift
// mb-speech's FluidAudio-free parts: the pinned manifest, file checks, `check` and `fetch` (with a
// stand-in downloader). No network, no models: every file here is made in a temporary folder.
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

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
