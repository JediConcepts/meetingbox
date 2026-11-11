import FluidAudio
import Foundation

/// `transcribe <models> <wav> <out.json>`: Parakeet Ultra, with its int8 encoder, loaded only from
/// the installed models folder. The words are always built by `mergeTokens` from the token timings,
/// because FluidAudio's own word builder has no confidence.
func transcribe(_ models: URL, wav: URL, out: URL) async throws {
    let manifest = try pinnedManifest(models)
    let ultra = try manifest.model(named: "parakeet-ultra")
    let loaded = try await AsrModels.load(from: models.appendingPathComponent(ultra.folder), version: .ultra,
                                          encoderPrecision: .int8)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(loaded)
    var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(wav, decoderState: &state)
    let tokens = (result.tokenTimings ?? []).map {
        Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: Double($0.confidence))
    }
    try writePrivately(wordsJSON(engine: "parakeet-ultra", words: mergeTokens(tokens)), to: out)
}
