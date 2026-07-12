import Foundation

/// A dictionary rule ready for matching (decoupled from the SwiftData model so
/// the pipeline stays UI/storage-free and testable).
public struct ReplacementRule: Sendable, Equatable {
    /// What the ASR is likely to produce (matched case-insensitively on word
    /// boundaries), e.g. "cube cuddle" or "robbie".
    public var spoken: String
    /// Exact text to insert, e.g. "kubectl" or "Robby".
    public var replacement: String

    public init(spoken: String, replacement: String) {
        self.spoken = spoken
        self.replacement = replacement
    }
}

/// Word-boundary, case-insensitive find/replace of custom dictionary entries
/// and snippets. This pass guarantees dictionary correctness on every engine,
/// including ones with no vocabulary biasing (Parakeet).
public struct DictionaryReplacer: TranscriptStage {
    private let rules: [ReplacementRule]

    public init(rules: [ReplacementRule]) {
        // Longest spoken form first so "sequel pro" wins over "sequel".
        self.rules = rules.sorted { $0.spoken.count > $1.spoken.count }
    }

    public func process(_ text: String, context: DictationContext) async -> String {
        let active = rules.filter { !$0.spoken.isEmpty }
        guard !active.isEmpty else { return text }

        // One combined pass: replaced text is never re-scanned, so one rule's
        // output can't be corrupted by another ("sequel pro" → "Sequel Pro"
        // must not then hit the "sequel" rule). Longest-first ordering makes
        // the alternation prefer the longest spoken form at each position.
        let alternation = active
            .map { NSRegularExpression.escapedPattern(for: $0.spoken) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "\\b(?:\(alternation))\\b",
            options: [.caseInsensitive]
        ) else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let matched = String(text[range])
            if let rule = active.first(where: { $0.spoken.caseInsensitiveCompare(matched) == .orderedSame }) {
                result += rule.replacement
            } else {
                result += matched
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
