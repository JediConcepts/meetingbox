import FluidAudio
import Foundation

/// `speakers <models> <wav> <out.json> [--count N]`: FluidAudio's offline diariser, loaded only from
/// the installed models folder, with the community settings and overlapping segments. A count (2 to
/// 6) asks for that many speakers, and FluidAudio may find fewer; without one it works them out. No
/// speech found writes empty lists.
func findSpeakers(_ models: URL, wav: URL, out: URL, count: Int?) async throws {
    let manifest = try pinnedManifest(models)
    let diarizer = try manifest.model(named: "speaker-diarization")
    var config = OfflineDiarizerConfig(clusteringThreshold: 0.6, Fa: 0.07, Fb: 0.8, segmentationStepRatio: 0.2,
                                       minSegmentDuration: minimumSegmentSeconds, exclusiveSegments: false)
    if let count { config.clustering.numSpeakers = count }
    let manager = OfflineDiarizerManager(config: config)
    manager.initialize(models: try await OfflineDiarizerModels.load(from: models))
    var segments: [SpeakerSegment] = []
    var vectors: [String: [Float]] = [:]
    do {
        // the diariser writes timing lines straight to stderr, where only the reason line may go
        let result = try await withStderrSilenced { try await manager.process(wav) }
        segments = result.segments.map {
            SpeakerSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        vectors = result.speakerDatabase ?? [:]
    } catch OfflineDiarizationError.noSpeechDetected {
        // nothing said: empty lists, and still a success
    }
    try writePrivately(speakersJSON(model: "\(diarizer.repo)@\(diarizer.revision)", segments: segments, vectors: vectors),
                       to: out)
}
