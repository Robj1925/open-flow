import Foundation

/// Hints passed to an engine for a single transcription.
public struct TranscriptionHints: Sendable {
    /// ISO 639-1 code, e.g. "en". nil lets the engine decide.
    public var language: String?
    /// Free-text vocabulary bias (custom dictionary words). Engines that can't
    /// bias (Parakeet) ignore it; correctness is guaranteed by the post-pass
    /// `DictionaryReplacer` either way.
    public var vocabulary: String?

    public init(language: String? = nil, vocabulary: String? = nil) {
        self.language = language
        self.vocabulary = vocabulary
    }
}

public struct EngineResult: Sendable {
    public var text: String
    /// Highest no-speech probability across segments, when the engine reports one.
    public var noSpeechProb: Float?
    /// Lowest average log-probability across segments, when reported.
    public var avgLogprob: Float?
    public var processingTime: TimeInterval

    public init(text: String, noSpeechProb: Float? = nil, avgLogprob: Float? = nil, processingTime: TimeInterval) {
        self.text = text
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
        self.processingTime = processingTime
    }
}

/// Seam between the dictation pipeline and any speech-to-text backend.
/// v1 ships `FluidAudioEngine` (Parakeet) and `WhisperKitEngine`; a future
/// cloud/BYOK engine implements the same protocol.
public protocol TranscriptionEngine: AnyObject {
    /// Stable identifier persisted in settings and history ("parakeet", "whisper").
    var id: String { get }
    var displayName: String { get }
    var isReady: Bool { get }
    /// Download (if needed) and load the model. `progress` is 0...1 and only
    /// meaningful during downloads; loading/specialization reports indeterminate.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Transcribe 16 kHz mono Float32 samples.
    func transcribe(_ audio: [Float], hints: TranscriptionHints) async throws -> EngineResult
    /// Release model memory. Safe to call `prepare` again afterwards.
    func unload()
}

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisper

    public var displayName: String {
        switch self {
        case .parakeet: return "Parakeet (fastest, English)"
        case .whisper: return "Whisper (multilingual)"
        }
    }
}

/// Load/download state of the selected engine, orthogonal to `DictationState`.
public enum ModelState: Equatable {
    case unloaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}
