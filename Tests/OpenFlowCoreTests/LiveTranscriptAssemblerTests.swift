import OpenFlowCore
import Testing

@Suite struct LiveTranscriptAssemblerTests {
    @Test func commitsOnlyAfterTwoAgreeingPasses() {
        var a = LiveTranscriptAssembler()
        let first = a.ingest(words: ["hello", "there"], timings: nil, windowDuration: 1)
        #expect(first.committed.isEmpty)
        #expect(first.tentative == ["hello", "there"])

        let second = a.ingest(words: ["hello", "there", "my"], timings: nil, windowDuration: 1.5)
        #expect(second.committed == ["hello", "there"])
        #expect(second.tentative == ["my"])
        #expect(second.text == "hello there my")
    }

    @Test func committedWordsSurviveALaterDisagreement() {
        var a = LiveTranscriptAssembler()
        _ = a.ingest(words: ["hello", "there"], timings: nil, windowDuration: 1)
        _ = a.ingest(words: ["hello", "there", "my"], timings: nil, windowDuration: 1.5)
        let t = a.ingest(words: ["hello", "their", "my", "friend"], timings: nil, windowDuration: 2)
        #expect(t.committed == ["hello", "there"])
        #expect(t.tentative == ["my", "friend"])
    }

    @Test func committedSurfaceNeverChangesOnlyAppends() {
        var a = LiveTranscriptAssembler()
        _ = a.ingest(words: ["hello", "there"], timings: nil, windowDuration: 1)
        _ = a.ingest(words: ["hello", "there", "my"], timings: nil, windowDuration: 1.5)
        // The engine now capitalises and punctuates the first word; the
        // committed copy keeps its original surface, new agreement appends.
        let t = a.ingest(words: ["Hello,", "there", "my", "friend"], timings: nil, windowDuration: 2)
        #expect(t.committed == ["hello", "there", "my"])
        #expect(t.tentative == ["friend"])
    }

    @Test func refreshesOnlyTheBoundaryWordWhenAppending() {
        var a = LiveTranscriptAssembler()
        _ = a.ingest(words: ["Google", "Deep", "Mind."], timings: nil, windowDuration: 1)
        _ = a.ingest(words: ["Google", "Deep", "Mind."], timings: nil, windowDuration: 1.5)
        _ = a.ingest(words: ["google", "Deep", "Mind", "just"], timings: nil, windowDuration: 2)
        let t = a.ingest(words: ["google", "Deep", "Mind", "just"], timings: nil, windowDuration: 2.5)
        // "Mind." loses its provisional period; "Google" keeps its original surface.
        #expect(t.committed == ["Google", "Deep", "Mind", "just"])
        #expect(t.tentative.isEmpty)
    }

    @Test func followsTheEngineWhenTwoPassesAgreeOnANewBeginning() {
        var a = LiveTranscriptAssembler()
        _ = a.ingest(words: ["yeah"], timings: nil, windowDuration: 0.5)
        _ = a.ingest(words: ["yeah", "deep"], timings: nil, windowDuration: 1)          // commits "yeah"
        let third = a.ingest(words: ["google", "deep", "mind"], timings: nil, windowDuration: 1.5)
        #expect(third.committed == ["yeah"])                                             // one disagreeing pass changes nothing
        let fourth = a.ingest(words: ["google", "deep", "mind", "just"], timings: nil, windowDuration: 2)
        #expect(fourth.committed == ["google", "deep", "mind"])                          // two in a row: phantom replaced
        #expect(fourth.tentative == ["just"])
    }

    @Test func shrinkingHypothesisKeepsCommittedPrefix() {
        var a = LiveTranscriptAssembler()
        _ = a.ingest(words: ["one", "two", "three"], timings: nil, windowDuration: 1)
        _ = a.ingest(words: ["one", "two", "three"], timings: nil, windowDuration: 1.5)
        let t = a.ingest(words: ["one"], timings: nil, windowDuration: 2)
        #expect(t.committed == ["one", "two", "three"])
        #expect(t.tentative.isEmpty)
    }

    @Test func freezesAtAPauseAndMovesTheWindow() {
        var a = LiveTranscriptAssembler()
        a.keepSeconds = 8
        a.minimumPause = 0.4
        let words = ["w0", "w1", "w2", "w3", "w4", "w5"]
        // w1 ends at 2.0, w2 starts at 2.6: a 0.6 s pause, old enough to cut.
        // w3/w4 also have a pause, but at 15 s they are inside the kept 8 s.
        let timings = [
            TimedWord(text: "w0", start: 0.5, end: 1.0),
            TimedWord(text: "w1", start: 1.1, end: 2.0),
            TimedWord(text: "w2", start: 2.6, end: 3.0),
            TimedWord(text: "w3", start: 3.1, end: 15.0),
            TimedWord(text: "w4", start: 15.9, end: 16.5),
            TimedWord(text: "w5", start: 16.6, end: 17.0),
        ]
        _ = a.ingest(words: words, timings: timings, windowDuration: 17)
        let t = a.ingest(words: words, timings: timings, windowDuration: 17.5)
        #expect(a.frozen == ["w0", "w1"])
        #expect(a.windowStart == 2.3)
        #expect(t.committed == ["w0", "w1", "w2", "w3", "w4", "w5"])
        #expect(t.tentative.isEmpty)

        // The next pass decodes from 2.3 s, so its words start at w2.
        let next = a.ingest(words: ["w2", "w3", "w4", "w5", "w6"], timings: nil, windowDuration: 15.5)
        #expect(next.committed == ["w0", "w1", "w2", "w3", "w4", "w5"])
        #expect(next.tentative == ["w6"])
    }

    @Test func forcesACutAtTheWidestSmallGapWhenTheWindowGetsLong() {
        var a = LiveTranscriptAssembler()
        a.keepSeconds = 6
        a.forceCutAfter = 13
        let words = ["a", "b", "c", "d", "e"]
        // No gap reaches 0.35 s; the widest eligible one (0.25 s, after "b") wins once the window passes 13 s.
        let timings = [
            TimedWord(text: "a", start: 0.0, end: 1.0),
            TimedWord(text: "b", start: 1.15, end: 3.0),
            TimedWord(text: "c", start: 3.25, end: 6.0),
            TimedWord(text: "d", start: 6.18, end: 9.0),
            TimedWord(text: "e", start: 9.1, end: 14.0),
        ]
        _ = a.ingest(words: words, timings: timings, windowDuration: 12.9)
        _ = a.ingest(words: words, timings: timings, windowDuration: 12.9)
        #expect(a.frozen.isEmpty)                                   // under the force threshold: wait for a real pause
        _ = a.ingest(words: words, timings: timings, windowDuration: 14.1)
        #expect(a.frozen == ["a", "b"])
        #expect(abs(a.windowStart - 3.125) < 0.001)
    }

    @Test func anchorsTheTailWhenTheEngineDropsACommittedWord() {
        var a = LiveTranscriptAssembler()
        _ = a.ingest(words: ["a", "b", "c", "d"], timings: nil, windowDuration: 2)
        _ = a.ingest(words: ["a", "b", "c", "d"], timings: nil, windowDuration: 2.5)
        // "c" vanished from the hypothesis; the new words after "d" must still show.
        let t = a.ingest(words: ["a", "b", "d", "e", "f"], timings: nil, windowDuration: 3)
        #expect(t.committed == ["a", "b", "c", "d"])
        #expect(t.tentative == ["e", "f"])
    }

    @Test func neverFreezesWithoutAPause() {
        var a = LiveTranscriptAssembler()
        let words = ["a", "b", "c"]
        let timings = [
            TimedWord(text: "a", start: 0.0, end: 1.0),
            TimedWord(text: "b", start: 1.1, end: 2.0),
            TimedWord(text: "c", start: 2.1, end: 20.0),
        ]
        _ = a.ingest(words: words, timings: timings, windowDuration: 20)
        _ = a.ingest(words: words, timings: timings, windowDuration: 20.5)
        #expect(a.frozen.isEmpty)
        #expect(a.windowStart == 0)
    }
}
