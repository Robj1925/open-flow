import FluidAudio
import Foundation

/// Parakeet TDT 0.6b v2 (English-only) via FluidAudio's CoreML runtime.
/// Fastest engine, near-zero silence hallucination, no vocabulary biasing —
/// dictionary correctness comes from the `DictionaryReplacer` post-pass.
public final class FluidAudioEngine: TranscriptionEngine {
    public let id = "parakeet"
    public let displayName = "Parakeet TDT v2"

    private var manager: AsrManager?

    public var isReady: Bool { manager != nil }

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2) { update in
            progress(update.fractionCompleted)
        }
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    public func transcribe(_ audio: [Float], hints: TranscriptionHints) async throws -> EngineResult {
        guard let manager else {
            throw NSError(domain: "OpenFlow.Engine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet model is not loaded yet.",
            ])
        }
        // FluidAudio rejects audio shorter than ~300 ms.
        guard audio.count >= Int(AudioCaptureEngine.targetSampleRate * 0.3) else {
            return EngineResult(text: "", processingTime: 0)
        }
        let started = Date()
        // Fresh decoder state per utterance; dictations are independent.
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &decoderState)
        return EngineResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            noSpeechProb: nil,
            avgLogprob: nil,
            processingTime: Date().timeIntervalSince(started)
        )
    }

    public func unload() {
        manager = nil
    }

    /// Where FluidAudio caches the Parakeet v2 CoreML weights.
    public static var modelsDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v2)
    }

    public static var isDownloaded: Bool {
        AsrModels.modelsExist(at: modelsDirectory, version: .v2)
    }
}
