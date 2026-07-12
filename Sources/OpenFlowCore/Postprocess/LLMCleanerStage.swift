import Foundation

/// Pipeline stage that runs the LLM cleanup pass. Placed after the
/// hallucination filter (so silence never costs an LLM call) and before the
/// dictionary replacer (so custom vocabulary always wins over the model).
public struct LLMCleanerStage: TranscriptStage {
    private let cleaner: any TextCleaner
    private let enabled: Bool
    private let vocabulary: String?

    public init(cleaner: any TextCleaner, enabled: Bool, vocabulary: String?) {
        self.cleaner = cleaner
        self.enabled = enabled
        self.vocabulary = vocabulary
    }

    public func process(_ text: String, context: DictationContext) async -> String {
        guard enabled, !text.isEmpty, cleaner.isAvailable else { return text }
        guard Self.needsCleanup(text) else { return text }
        return await cleaner.clean(text, vocabulary: vocabulary)
    }

    /// Fast local check for disfluency markers. The ASR engines already
    /// punctuate and rarely emit fillers, so most dictations are clean and
    /// skip the LLM entirely — zero added latency is the common case, and the
    /// system model's erratic reload cost (~7 s) is only ever paid when the
    /// transcript visibly needs repair.
    public static func needsCleanup(_ text: String) -> Bool {
        // Filler words and spoken self-corrections. Bare "like" is deliberately
        // excluded — too often legitimate.
        let fillers = #"(?i)(^|[\s,.;!?])(um+|uh+|erm?|hmm+|you know|i mean|no wait|wait no|scratch that|actually no|strike that)($|[\s,.;!?])"#
        if text.range(of: fillers, options: .regularExpression) != nil { return true }
        // Stutters: the same word twice in a row ("the the report").
        let stutter = #"(?i)\b(\w+)\s+\1\b"#
        if text.range(of: stutter, options: .regularExpression) != nil { return true }
        return false
    }
}
