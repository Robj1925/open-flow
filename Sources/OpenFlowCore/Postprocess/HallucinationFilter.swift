import Foundation

/// Drops transcripts that are almost certainly ASR hallucinations on silence
/// or near-silence (Whisper's classic "Thank you." problem).
public struct HallucinationFilter: TranscriptStage {
    /// RMS below this means no speech-level audio was ever captured.
    public var minimumPeakRMS: Float = 0.01
    /// Dictations shorter than this are noise.
    public var minimumDuration: TimeInterval = 0.3
    /// Whisper-reported no-speech probability above this is discarded.
    public var noSpeechThreshold: Float = 0.7

    /// Phrases Whisper famously produces from silence, matched only when the
    /// audio energy was low — a real quiet "thank you" still goes through.
    private static let silenceArtifacts: Set<String> = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!",
        "thank you for watching", "thank you for watching.", "you", "you.",
        "bye", "bye.", ".", "the end", "the end.",
        "subtitles by the amara.org community",
    ]
    /// Below this peak RMS the audio counts as "low energy" for artifact matching.
    private var lowEnergyRMS: Float { minimumPeakRMS * 4 }

    public init() {}

    public func process(_ text: String, context: DictationContext) async -> String {
        if context.peakRMS < minimumPeakRMS { return "" }
        if context.audioDuration < minimumDuration { return "" }
        if let noSpeech = context.noSpeechProb, noSpeech > noSpeechThreshold { return "" }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if context.peakRMS < lowEnergyRMS, Self.silenceArtifacts.contains(normalized) {
            return ""
        }
        return text
    }
}
