// mb-speech: Parakeet Ultra and offline speaker labels for meetingbox, through FluidAudio.
// Every command exits 0, or exits 1 with exactly one line on stderr naming the reason.
import FluidAudio
import Foundation

// First, before any argument is read: FluidAudio may not reach the network (only `fetch`
// turns this off), and it writes nothing to the console.
ModelHub.offlineMode = true
AppLogger.mirrorsToConsole = false

func fail(_ reason: String) -> Never {
    let line = reason.components(separatedBy: .newlines).joined(separator: " ")
    FileHandle.standardError.write(Data(("mb-speech: " + line + "\n").utf8))
    exit(1)
}

/// The folder Core ML keeps this process's prepared models in: the user's caches folder plus the
/// process's name. Nothing is created.
func cacheDirectory() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
}

/// Checks the installed models, then pins FluidAudio to their revisions, so that FluidAudio itself
/// refuses a folder from any other revision.
func pinnedManifest(_ models: URL) throws -> Manifest {
    if let reason = checkModels(at: models) { throw SpeechError(reason: reason) }
    let manifest = try installedManifest(at: models)
    ModelRegistry.revisionOverrides = manifest.revisionPins
    return manifest
}

/// `warm <models>`: loads both models once, so Core ML prepares them before the first meeting.
func warm(_ models: URL) async throws {
    let manifest = try pinnedManifest(models)
    let ultra = try manifest.model(named: "parakeet-ultra")
    _ = try await AsrModels.load(from: models.appendingPathComponent(ultra.folder), version: .ultra)
    _ = try manifest.model(named: "speaker-diarization")
    let speakers = try await OfflineDiarizerModels.load(from: models)
    OfflineDiarizerManager().initialize(models: speakers)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch (arguments.first ?? "", arguments.count) {
    case ("version", 1):
        print("mb-speech \(buildVersion) \(speechHash)")
    case ("cache-dir", 1):
        print(cacheDirectory().path)
    case ("fetch", 3):
        ModelHub.offlineMode = false
        try await fetchModels(into: URL(fileURLWithPath: arguments[1]), manifestAt: URL(fileURLWithPath: arguments[2]),
                              download: sessionDownload())
    case ("check", 2):
        if let reason = checkModels(at: URL(fileURLWithPath: arguments[1])) { fail(reason) }
    case ("warm", 2):
        try await warm(URL(fileURLWithPath: arguments[1]))
    default:
        fail("usage: mb-speech version | cache-dir | fetch <models> <manifest> | check <models> | warm <models>")
    }
} catch let error as SpeechError {
    fail(error.reason)
} catch {
    fail(String(describing: error))
}
exit(0)
