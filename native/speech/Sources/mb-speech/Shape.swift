// FluidAudio-free parts of mb-speech: the model manifest, file checks, private writes, the words JSON
// and the speakers JSON. native/tests/speech compiles this file on its own, so it must never import
// FluidAudio.
import CryptoKit
import Foundation

/// A failure with the one line mb-speech prints on stderr.
struct SpeechError: Error {
    let reason: String
}

struct ManifestFile: Decodable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
}

struct ManifestModel: Decodable, Equatable {
    let name: String
    let repo: String
    let revision: String
    let folder: String
    let files: [ManifestFile]
}

struct Manifest: Decodable, Equatable {
    let models: [ManifestModel]

    func model(named name: String) throws -> ManifestModel {
        guard let found = models.first(where: { $0.name == name }) else {
            throw SpeechError(reason: "the model manifest has no \(name)")
        }
        return found
    }

    /// FluidAudio's revision overrides: each repository pinned to the manifest's commit.
    var revisionPins: [String: String] {
        Dictionary(models.map { ($0.repo, $0.revision) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The installed copy of the manifest inside the models folder.
let installedManifestName = "models.json"
/// Written by `fetch` into each model folder, holding the manifest revision. `.fluidaudio-revision`
/// is the marker FluidAudio itself compares with a pinned revision before it loads a folder.
let revisionMarkers = [".revision", ".fluidaudio-revision"]

private func isHex(_ text: String, count: Int) -> Bool {
    text.count == count && text.allSatisfy { "0123456789abcdef".contains($0) }
}

/// One path component of letters, digits, '.', '_' or '-', not starting with '.'.
private func isPlainName(_ text: String) -> Bool {
    guard let first = text.first, first != "." else { return false }
    return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
}

private func isPlainPath(_ text: String) -> Bool {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { isPlainName(String($0)) }
}

/// Parses a manifest and refuses anything that could name a path outside a model folder.
func parseManifest(_ data: Data) throws -> Manifest {
    guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
        throw SpeechError(reason: "the model manifest is not valid JSON of the expected shape")
    }
    guard !manifest.models.isEmpty else { throw SpeechError(reason: "the model manifest lists no models") }
    for model in manifest.models {
        let repo = model.repo.split(separator: "/", omittingEmptySubsequences: false)
        guard repo.count == 2, repo.allSatisfy({ isPlainName(String($0)) }) else {
            throw SpeechError(reason: "model \(model.name): repository \(model.repo) is not owner/name")
        }
        guard isHex(model.revision, count: 40) else {
            throw SpeechError(reason: "model \(model.name): revision \(model.revision) is not a commit")
        }
        guard isPlainName(model.folder) else {
            throw SpeechError(reason: "model \(model.name): folder \(model.folder) is not a plain name")
        }
        guard !model.files.isEmpty else { throw SpeechError(reason: "model \(model.name) lists no files") }
        for file in model.files where !isPlainPath(file.path) || file.size < 0 || !isHex(file.sha256, count: 64) {
            throw SpeechError(reason: "model \(model.name): file entry \(file.path) is not valid")
        }
    }
    guard Set(manifest.models.map(\.folder)).count == manifest.models.count,
          Set(manifest.models.map(\.repo)).count == manifest.models.count else {
        throw SpeechError(reason: "the model manifest names a folder or repository twice")
    }
    return manifest
}

private func regularFileSize(_ url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber else { return nil }
    return size.int64Value
}

func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// nil when the file in `folder` has the manifest's size and SHA-256; otherwise the reason, with its path.
func verifyFile(_ file: ManifestFile, in folder: URL) -> String? {
    let url = folder.appendingPathComponent(file.path)
    guard let size = regularFileSize(url) else { return "\(url.path) is missing" }
    guard size == file.size else { return "\(url.path) is \(size) bytes, not \(file.size)" }
    guard let hash = try? sha256Hex(of: url) else { return "\(url.path) cannot be read" }
    guard hash == file.sha256 else { return "\(url.path) does not match its SHA-256" }
    return nil
}

func readMarker(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// True when `folder` already holds this model: both markers name its revision and every file
/// has the manifest's size and SHA-256. `fetch` keeps such a folder rather than download it again.
func modelIsCurrent(_ model: ManifestModel, in folder: URL) -> Bool {
    revisionMarkers.allSatisfy { readMarker(folder.appendingPathComponent($0)) == model.revision }
        && model.files.allSatisfy { verifyFile($0, in: folder) == nil }
}

/// Reads and parses `<models>/models.json`.
func installedManifest(at models: URL) throws -> Manifest {
    let url = models.appendingPathComponent(installedManifestName)
    guard let data = try? Data(contentsOf: url) else { throw SpeechError(reason: "\(url.path) is missing") }
    return try parseManifest(data)
}

/// `check`: nil when the installed manifest parses, each folder's markers name its revision and
/// every file is present at its size. Hashes are checked by `fetch`, not here, so this stays quick.
func checkModels(at models: URL) -> String? {
    let manifest: Manifest
    do { manifest = try installedManifest(at: models) } catch { return (error as? SpeechError)?.reason ?? "\(error)" }
    for model in manifest.models {
        let folder = models.appendingPathComponent(model.folder)
        for marker in revisionMarkers {
            let url = folder.appendingPathComponent(marker)
            guard readMarker(url) == model.revision else {
                return "\(url.path) does not name revision \(model.revision)"
            }
        }
        for file in model.files {
            let url = folder.appendingPathComponent(file.path)
            guard regularFileSize(url) == file.size else { return "\(url.path) is missing or not \(file.size) bytes" }
        }
    }
    return nil
}

/// Writes `data` to a temporary name beside `target`, sets it to 0600 and renames it into place.
func writePrivately(_ data: Data, to target: URL) throws {
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".part-" + target.lastPathComponent)
    try? FileManager.default.removeItem(at: temporary)
    guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
          rename(temporary.path, target.path) == 0 else {
        throw SpeechError(reason: "\(target.path) cannot be written")
    }
}

/// Runs `body` with stderr (fd 2) sent to /dev/null, and puts stderr back as it was however `body`
/// ends. FluidAudio's offline diariser writes "[Profiling]" timing lines straight to stderr, which
/// would break the one-line rule. Only its `process` runs inside this, so everything else keeps its
/// stderr, Swift trap text included.
func withStderrSilenced<T>(_ body: () async throws -> T) async rethrows -> T {
    let kept = dup(STDERR_FILENO)
    if kept >= 0 {
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, STDERR_FILENO); close(null) }
    }
    defer { if kept >= 0 { dup2(kept, STDERR_FILENO); close(kept) } }
    return try await body()
}

/// One of the transcriber's tokens, with its timing and confidence.
struct Token {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double
}

/// One word of the words JSON.
struct Word: Equatable {
    var start: Double
    var end: Double
    var text: String
    var confidence: Double
}

/// Parakeet's tokens to words. FluidAudio's own word builder has no confidence, so this is ours:
/// a token starting with a space starts a word (the space dropped), any other token joins the
/// current word; empty, `<blank>` and `<pad>` tokens are skipped. A token that is only a space ends
/// the current word, so the next token starts one (Ultra writes digits and `$` that way, and
/// FluidAudio's own rule splits there too). A word starts with its first token and ends with its
/// last, and its confidence is the lowest of its tokens'.
func mergeTokens(_ tokens: [Token]) -> [Word] {
    var words: [Word] = []
    var boundary = true
    for token in tokens {
        if token.text.isEmpty || token.text == "<blank>" || token.text == "<pad>" { continue }
        let starts = token.text.hasPrefix(" ") || token.text.hasPrefix("\u{2581}")
        let text = starts ? String(token.text.dropFirst()) : token.text
        if text.isEmpty { boundary = true; continue }
        defer { boundary = false }
        if starts || boundary {
            words.append(Word(start: token.start, end: token.end, text: text, confidence: token.confidence))
        } else {
            words[words.count - 1].text += text
            words[words.count - 1].end = token.end
            words[words.count - 1].confidence = min(words[words.count - 1].confidence, token.confidence)
        }
    }
    return words
}

/// A JSON string, quoted and escaped.
private func quoted(_ text: String) -> String {
    String(data: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
}

/// A JSON number to the millisecond; anything not finite is 0.
private func number(_ value: Double) -> String { String(format: "%.3f", value.isFinite ? value : 0) }

/// The words JSON every transcriber's output is read in:
/// `{"engine": "parakeet-ultra", "words": [{"start": 1.2, "end": 1.48, "text": "Hello,", "confidence": 0.97}]}`.
func wordsJSON(engine: String, words: [Word]) -> Data {
    let lines = words.map {
        "{\"start\": \(number($0.start)), \"end\": \(number($0.end)), \"text\": \(quoted($0.text)), \"confidence\": \(number($0.confidence))}"
    }
    return Data("{\"engine\": \(quoted(engine)), \"words\": [\(lines.joined(separator: ",\n"))]}\n".utf8)
}

/// The shortest segment the diariser keeps, and the shortest the exclusive copy keeps after trimming.
let minimumSegmentSeconds = 1.0

/// One speaker's turn, as the diariser found it.
struct SpeakerSegment: Equatable {
    let speaker: String
    let start: Double
    let end: Double
}

/// FluidAudio's start order: by start, then end, then speaker.
private func startsBefore(_ a: SpeakerSegment, _ b: SpeakerSegment) -> Bool {
    (a.start, a.end, a.speaker) < (b.start, b.end, b.speaker)
}

/// The exclusive copy, by the rule FluidAudio's own exclusive output follows: in start order, a
/// segment starting before the last kept one ends starts at that end instead, and is dropped if
/// less than `minimum` seconds is left.
func exclusiveCopy(_ segments: [SpeakerSegment], minimum: Double = minimumSegmentSeconds) -> [SpeakerSegment] {
    var kept: [SpeakerSegment] = []
    for segment in segments.sorted(by: startsBefore) {
        let start = max(segment.start, kept.last?.end ?? segment.start)
        if segment.end > start && segment.end - start >= minimum {
            kept.append(SpeakerSegment(speaker: segment.speaker, start: start, end: segment.end))
        }
    }
    return kept
}

/// A speaker's talk time and median segment length, in seconds.
struct SpeakerTalk: Equatable {
    let seconds: Double
    let median: Double
}

/// Each speaker's talk, measured on the exclusive copy of the segments, as the naming thresholds
/// were. A speaker with nothing left in it has 0 and 0. The median of an even count is the mean of
/// the middle two.
func speakerTalk(_ segments: [SpeakerSegment]) -> [String: SpeakerTalk] {
    var lengths: [String: [Double]] = Dictionary(uniqueKeysWithValues: Set(segments.map(\.speaker)).map { ($0, []) })
    for segment in exclusiveCopy(segments) { lengths[segment.speaker, default: []].append(segment.end - segment.start) }
    return lengths.mapValues { list in
        let sorted = list.sorted(), middle = sorted.count / 2
        let median: Double
        if sorted.isEmpty { median = 0 }
        else if sorted.count % 2 == 1 { median = sorted[middle] }
        else { median = (sorted[middle - 1] + sorted[middle]) / 2 }
        return SpeakerTalk(seconds: sorted.reduce(0, +), median: median)
    }
}

/// The speakers JSON, kept only in the run's work folder:
/// `{"model": "<repo>@<revision>", "segments": [{"speaker": "S1", "start": 0.0, "end": 4.2}],
///   "speakers": [{"id": "S1", "seconds": 391.0, "median": 3.9, "vector": [256 numbers]}]}`.
/// The segments overlap, as found, in start order. Each speaker's seconds and median come from the
/// exclusive copy, and its vector is the diariser's own. A speaker without a vector is refused.
func speakersJSON(model: String, segments: [SpeakerSegment], vectors: [String: [Float]]) throws -> Data {
    let talks = speakerTalk(segments)
    let ids = talks.keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    let segmentLines = segments.sorted(by: startsBefore).map {
        "{\"speaker\": \(quoted($0.speaker)), \"start\": \(number($0.start)), \"end\": \(number($0.end))}"
    }
    let speakerLines = try ids.map { id -> String in
        guard let vector = vectors[id], let talk = talks[id] else {
            throw SpeechError(reason: "the diariser gave no voice vector for speaker \(id)")
        }
        let values = vector.map { $0.isFinite ? "\($0)" : "0" }.joined(separator: ", ")
        return "{\"id\": \(quoted(id)), \"seconds\": \(number(talk.seconds)), \"median\": \(number(talk.median)), \"vector\": [\(values)]}"
    }
    return Data("""
    {"model": \(quoted(model)),
    "segments": [\(segmentLines.joined(separator: ",\n"))],
    "speakers": [\(speakerLines.joined(separator: ",\n"))]}

    """.utf8)
}
