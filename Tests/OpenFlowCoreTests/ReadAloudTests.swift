import CoreGraphics
import Testing
import OpenFlowCore

@Suite struct TextChunkerTests {
    @Test func splitsOnSentenceBoundaries() {
        let chunks = TextChunker.chunks("The first sentence is here. The second one follows it! Is this the third? Yes it is.")
        #expect(chunks == [
            "The first sentence is here.",
            "The second one follows it!",
            "Is this the third? Yes it is.",
        ])
    }

    @Test func keepsClosingQuotesWithSentence() {
        let chunks = TextChunker.chunks("She said \"we ship on Friday.\" Everyone agreed with the plan.")
        #expect(chunks == ["She said \"we ship on Friday.\"", "Everyone agreed with the plan."])
    }

    @Test func doesNotSplitDecimalsOrInlineDots() {
        let chunks = TextChunker.chunks("Version 2.5 costs 3.99 dollars at example.com today.")
        #expect(chunks == ["Version 2.5 costs 3.99 dollars at example.com today."])
    }

    @Test func shortTrailingFragmentJoinsPreviousChunk() {
        // "The end." alone would be a sub-second blip; it rides with its neighbour.
        let chunks = TextChunker.chunks("This is a complete sentence of normal length. The end.")
        #expect(chunks == ["This is a complete sentence of normal length. The end."])
    }

    @Test func mergesShortFragmentsIntoNextSentence() {
        // "e.g." alone is too short to be its own chunk.
        let chunks = TextChunker.chunks("Use a tool, e.g. the one we discussed at the meeting earlier.")
        #expect(chunks == ["Use a tool, e.g. the one we discussed at the meeting earlier."])
    }

    @Test func doesNotSplitAfterAbbreviations() {
        let chunks = TextChunker.chunks("Version 2.5 ships today, e.g. right now! Ask Dr. Smith about the U.S. launch. Then rest for the whole evening.")
        #expect(chunks == [
            "Version 2.5 ships today, e.g. right now!",
            "Ask Dr. Smith about the U.S. launch.",
            "Then rest for the whole evening.",
        ])
    }

    @Test func doesNotSplitBeforeLowercaseContinuation() {
        let chunks = TextChunker.chunks("we paused. then we continued the long walk home. Later we stopped for a while.")
        #expect(chunks == ["we paused. then we continued the long walk home.", "Later we stopped for a while."])
    }

    @Test func lineBreaksAreHardBoundaries() {
        let chunks = TextChunker.chunks("# Heading\nFirst bullet without a period\nSecond bullet without a period")
        #expect(chunks == ["# Heading", "First bullet without a period", "Second bullet without a period"])
    }

    @Test func collapsesWhitespace() {
        let chunks = TextChunker.chunks("  Too   many\t spaces   here.  ")
        #expect(chunks == ["Too many spaces here."])
    }

    @Test func dropsUnspeakableChunks() {
        let chunks = TextChunker.chunks("---\n...\nReal words here.\n***")
        #expect(chunks == ["Real words here."])
    }

    @Test func splitsLongSentencesAtClauseBoundaries() {
        let clause = "this clause keeps going and going without any terminal punctuation at all"
        let long = ([String](repeating: clause, count: 6)).joined(separator: ", ") + "."
        let chunks = TextChunker.chunks(long, maxLength: 200)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 200 })
        // Nothing is lost: joining the pieces reproduces the sentence.
        #expect(chunks.joined(separator: " ") == long)
    }

    @Test func hardCutsWhenNoBoundaryExists() {
        let long = String(repeating: "a", count: 700)
        let chunks = TextChunker.chunks(long, maxLength: 300)
        #expect(chunks.map(\.count) == [300, 300, 100])
    }

    @Test func emptyInputYieldsNothing() {
        #expect(TextChunker.chunks("").isEmpty)
        #expect(TextChunker.chunks("   \n\n  ").isEmpty)
    }
}

@Suite struct ReadAloudStateTests {
    @Test func activityFlags() {
        #expect(ReadAloudState.idle.isIdle)
        #expect(!ReadAloudState.idle.isActive)
        #expect(ReadAloudState.preparing.isActive)
        #expect(ReadAloudState.speaking.isActive)
        #expect(!ReadAloudState.failed("x").isActive)
        #expect(!ReadAloudState.failed("x").isIdle)
    }
}

@Suite struct ReadAloudHotkeyTests {
    @Test func chordRequiresExactModifiers() {
        let chord = ReadAloudHotkey.controlOptionR
        #expect(chord.matches(keyCode: 15, flags: [.maskControl, .maskAlternate]))
        // Caps Lock / fn state must not break the match.
        #expect(chord.matches(keyCode: 15, flags: [.maskControl, .maskAlternate, .maskAlphaShift]))
        #expect(!chord.matches(keyCode: 15, flags: [.maskControl]))
        #expect(!chord.matches(keyCode: 15, flags: [.maskControl, .maskAlternate, .maskCommand]))
        #expect(!chord.matches(keyCode: 1, flags: [.maskControl, .maskAlternate]))
    }

    @Test func plainKeyRejectsModifiers() {
        #expect(ReadAloudHotkey.f18.matches(keyCode: 79, flags: []))
        #expect(!ReadAloudHotkey.f18.matches(keyCode: 79, flags: [.maskCommand]))
    }

    @Test func offNeverMatches() {
        #expect(!ReadAloudHotkey.off.matches(keyCode: 15, flags: [.maskControl, .maskAlternate]))
    }
}

