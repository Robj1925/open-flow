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
        return await cleaner.clean(text, vocabulary: vocabulary)
    }
}
