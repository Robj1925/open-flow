import FluidAudio
import Foundation

/// Parakeet TDT 0.6b v3 (multilingual: English plus 24 European languages) via
/// FluidAudio's CoreML runtime. Fastest engine, near-zero silence hallucination,
/// no vocabulary biasing. Dictionary correctness comes from the
/// `DictionaryReplacer` post-pass.
public final class FluidAudioEngine: TranscriptionEngine {
    public let id = "parakeet"
    public let displayName = "Parakeet TDT v3"

    private var manager: AsrManager?

    public var isReady: Bool { manager != nil }

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3) { update in
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
            processingTime: Date().timeIntervalSince(started),
            words: Self.words(from: result.tokenTimings)
        )
    }

    /// Groups SentencePiece tokens into words. FluidAudio renders the word
    /// boundary marker as a leading space, so a token that starts with a
    /// space (or follows a lone boundary token) begins a new word; everything
    /// else, punctuation included, attaches to the word before it.
    static func words(from timings: [TokenTiming]?) -> [TimedWord]? {
        guard let timings, !timings.isEmpty else { return nil }
        var words: [TimedWord] = []
        var boundaryPending = true
        for timing in timings {
            let startsWord = timing.token.hasPrefix(" ") || boundaryPending
            let text = timing.token.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                boundaryPending = true
                continue
            }
            boundaryPending = false
            if startsWord || words.isEmpty {
                words.append(TimedWord(text: text, start: timing.startTime, end: timing.endTime))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = max(words[words.count - 1].end, timing.endTime)
            }
        }
        return words.isEmpty ? nil : words
    }

    public func unload() {
        manager = nil
    }

    /// Where FluidAudio caches the Parakeet v3 CoreML weights.
    public static var modelsDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    public static var isDownloaded: Bool {
        AsrModels.modelsExist(at: modelsDirectory, version: .v3)
    }
}
