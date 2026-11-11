// FluidAudio-free parts of mb-speech: the model manifest, file checks and private writes.
// native/tests/speech compiles this file on its own, so it must never import FluidAudio.
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
