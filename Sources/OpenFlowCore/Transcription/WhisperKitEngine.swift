import Foundation
import WhisperKit

/// Whisper via WhisperKit (CoreML/ANE). Multilingual, supports vocabulary
/// biasing through the decoder's initial prompt.
public final class WhisperKitEngine: TranscriptionEngine {
    public let id = "whisper"
    public var displayName: String { "Whisper (\(modelVariant))" }

    /// Variant folder name in the argmaxinc/whisperkit-coreml HF repo.
    public let modelVariant: String
    private let downloadBase: URL
    private var whisperKit: WhisperKit?

    public var isReady: Bool { whisperKit != nil }

    public init(modelVariant: String, downloadBase: URL) {
        self.modelVariant = modelVariant
        self.downloadBase = downloadBase
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard whisperKit == nil else { return }
        // Download explicitly first so we get progress; WhisperKit(config:) would
        // download too, but without a callback surface.
        let modelFolder = try await WhisperKit.download(
            variant: modelVariant,
            downloadBase: downloadBase,
            progressCallback: { p in progress(p.fractionCompleted) }
        )
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    public func transcribe(_ audio: [Float], hints: TranscriptionHints) async throws -> EngineResult {
        guard let kit = whisperKit else {
            throw NSError(domain: "OpenFlow.Engine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Whisper model is not loaded yet.",
            ])
        }
        let started = Date()
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = hints.language
        options.temperature = 0
        options.chunkingStrategy = .vad
        options.skipSpecialTokens = true

        // Vocabulary biasing via initial prompt tokens. Known to be flaky on some
        // WhisperKit versions (argmax-oss-swift#372): applied best-effort; the
        // DictionaryReplacer post-pass guarantees correctness regardless.
        if let vocabulary = hints.vocabulary, !vocabulary.isEmpty,
           let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + vocabulary)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }

        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let segments = results.flatMap { $0.segments }
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineResult(
            text: text,
            noSpeechProb: segments.map(\.noSpeechProb).max(),
            avgLogprob: segments.map(\.avgLogprob).min(),
            processingTime: Date().timeIntervalSince(started)
        )
    }

    public func unload() {
        whisperKit = nil
    }
}
