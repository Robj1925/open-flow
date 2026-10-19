import Foundation

/// Splits text into short, self-contained chunks for sentence-by-sentence
/// speech synthesis. Kokoro renders a chunk in one shot, so the first
/// sentence is audible while the rest is still being rendered.
public enum TextChunker {
    /// Chunks longer than this are split at a clause boundary. Roughly two
    /// spoken sentences; keeps per-chunk latency well under a second.
    public static let defaultMaxLength = 320

    /// Fragments shorter than this (abbreviations like "e.g.", list bullets)
    /// are merged into the next sentence instead of becoming their own chunk.
    static let minimumFragmentLength = 24

    public static func chunks(_ text: String, maxLength: Int = defaultMaxLength) -> [String] {
        var result: [String] = []
        for paragraph in paragraphs(text) {
            var carry = ""
            for sentence in sentences(paragraph) where isSpeakable(sentence) {
                let candidate = carry.isEmpty ? sentence : carry + " " + sentence
                if candidate.count < minimumFragmentLength {
                    carry = candidate
                    continue
                }
                carry = ""
                result.append(contentsOf: split(candidate, maxLength: maxLength))
            }
            if !carry.isEmpty {
                if let last = result.indices.last, result[last].count + carry.count + 1 <= maxLength {
                    result[last] += " " + carry
                } else {
                    result.append(carry)
                }
            }
        }
        return result
    }

    // MARK: - Stages

    /// Line breaks are hard boundaries (headings, list items, code lines).
    static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }
    }

    /// Splits on `.`, `!`, `?` and `…` (optionally followed by closing quotes
    /// or brackets) when whitespace or the end of the text follows, the word
    /// before is not an abbreviation ("e.g.", "Dr."), and the next word looks
    /// like a sentence start (capital, digit, quote or bracket).
    static func sentences(_ paragraph: String) -> [String] {
        let characters = Array(paragraph)
        var pieces: [String] = []
        var start = 0
        var index = 0
        while index < characters.count {
            if terminators.contains(characters[index]) {
                var end = index + 1
                while end < characters.count, closers.contains(characters[end]) { end += 1 }
                let atEnd = end == characters.count
                if atEnd || characters[end].isWhitespace,
                   !(characters[index] == "." && isAbbreviation(characters, endingAt: index)),
                   atEnd || startsSentence(characters, from: end) {
                    let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { pieces.append(piece) }
                    start = end
                    index = end
                    continue
                }
            }
            index += 1
        }
        let tail = String(characters[start...]).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    /// Breaks an over-long sentence at the last clause boundary (`, ; :`)
    /// before the limit, falling back to the last space, then a hard cut.
    static func split(_ sentence: String, maxLength: Int) -> [String] {
        guard sentence.count > maxLength else { return [sentence] }
        var remaining = Substring(sentence)
        var pieces: [String] = []
        while remaining.count > maxLength {
            let window = remaining.prefix(maxLength)
            let cut = window.lastIndex(where: { clauseBreaks.contains($0) })
                .map { window.index(after: $0) }
                ?? window.lastIndex(where: \.isWhitespace)
                ?? window.endIndex
            let piece = remaining[..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            remaining = remaining[cut...].drop(while: \.isWhitespace)
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    /// The word that ends at `dotIndex` (letters/dots only, no whitespace).
    /// "e.g." and "U.S." carry an inner dot; "Dr." and friends are listed.
    static func isAbbreviation(_ characters: [Character], endingAt dotIndex: Int) -> Bool {
        var wordStart = dotIndex
        while wordStart > 0, !characters[wordStart - 1].isWhitespace { wordStart -= 1 }
        let word = String(characters[wordStart..<dotIndex])
        if word.contains(".") { return true }
        return abbreviations.contains(word.lowercased())
    }

    /// True when the next non-space character could open a sentence.
    static func startsSentence(_ characters: [Character], from index: Int) -> Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        guard cursor < characters.count else { return true }
        let next = characters[cursor]
        return next.isUppercase || next.isNumber || openers.contains(next) || !next.isLetter
    }

    static func collapseWhitespace<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Something must be pronounceable: bare punctuation or rules ("---") are skipped.
    static func isSpeakable(_ chunk: String) -> Bool {
        chunk.contains { $0.isLetter || $0.isNumber }
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
    private static let openers: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "«"]
    private static let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–"]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "approx", "no", "fig", "inc", "ltd", "co",
    ]
}
