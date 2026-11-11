// `mb-speech fetch <models> <manifest>`: the only command that uses the network, and the only
// one that turns FluidAudio's offline mode off (main.swift). It never asks FluidAudio to
// download: it fetches each pinned file itself, checks it, then swaps the folder in.
import Foundation

func fetchModels(into models: URL, manifestAt manifestURL: URL) async throws {
    let fm = FileManager.default
    guard let data = try? Data(contentsOf: manifestURL) else {
        throw SpeechError(reason: "\(manifestURL.path) cannot be read")
    }
    let manifest = try parseManifest(data)
    var isFolder: ObjCBool = false
    guard fm.fileExists(atPath: models.path, isDirectory: &isFolder), isFolder.boolValue else {
        throw SpeechError(reason: "\(models.path) is not a folder")
    }
    // Leftovers of an interrupted fetch are this command's own; nothing else is removed.
    for name in try fm.contentsOfDirectory(atPath: models.path) where name.hasPrefix(".part-") || name.hasPrefix(".old-") {
        try fm.removeItem(at: models.appendingPathComponent(name))
    }

    // Ephemeral: no cookies, no URL cache and nothing else on disk.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 4 * 60 * 60
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    for model in manifest.models {
        let part = models.appendingPathComponent(".part-" + model.folder)
        try fm.createDirectory(at: part, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for file in model.files {
            guard let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(file.path)") else {
                throw SpeechError(reason: "\(file.path) does not make an address")
            }
            let target = part.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let (downloaded, response) = try await session.download(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? fm.removeItem(at: downloaded)
                throw SpeechError(reason: "\(url.absoluteString) answered \(status)")
            }
            try fm.moveItem(at: downloaded, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            if let reason = verifyFile(file, in: part) { throw SpeechError(reason: reason) }
        }
        for marker in revisionMarkers {
            try writePrivately(Data((model.revision + "\n").utf8), to: part.appendingPathComponent(marker))
        }
        try swapIn(part, as: models.appendingPathComponent(model.folder))
    }
    try writePrivately(data, to: models.appendingPathComponent(installedManifestName))
}

/// Renames the old folder aside, renames the new one in, then removes the old.
private func swapIn(_ part: URL, as target: URL) throws {
    let old = target.deletingLastPathComponent().appendingPathComponent(".old-\(target.lastPathComponent)-\(getpid())")
    var status = stat()
    if lstat(target.path, &status) == 0, rename(target.path, old.path) != 0 {
        throw SpeechError(reason: "\(target.path) cannot be moved aside")
    }
    guard rename(part.path, target.path) == 0 else { throw SpeechError(reason: "\(target.path) cannot be put in place") }
    try? FileManager.default.removeItem(at: old)
}
