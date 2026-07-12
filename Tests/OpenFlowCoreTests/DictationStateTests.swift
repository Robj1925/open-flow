import Testing
import OpenFlowCore

@Suite struct DictationStateTests {
    @Test func idleFlags() {
        #expect(DictationState.idle.isIdle)
        #expect(!DictationState.idle.isRecording)
        #expect(!DictationState.idle.isTranscribing)
    }

    @Test func recordingFlags() {
        let state = DictationState.recording(mode: .hold, startedAt: .distantPast)
        #expect(state.isRecording)
        #expect(!state.isIdle)
    }
}

@Suite struct HallucinationFilterTests {
    private func context(rms: Float, duration: Double = 3, noSpeech: Float? = nil) -> DictationContext {
        DictationContext(audioDuration: duration, peakRMS: rms, engineID: "test", noSpeechProb: noSpeech)
    }

    @Test func dropsSilentAudio() async {
        let filter = HallucinationFilter()
        #expect(await filter.process("Thank you.", context: context(rms: 0.001)) == "")
    }

    @Test func dropsTooShortAudio() async {
        let filter = HallucinationFilter()
        #expect(await filter.process("Hi", context: context(rms: 0.5, duration: 0.1)) == "")
    }

    @Test func dropsHighNoSpeechProbability() async {
        let filter = HallucinationFilter()
        #expect(await filter.process("Hello world", context: context(rms: 0.5, noSpeech: 0.95)) == "")
    }

    @Test func dropsKnownArtifactOnLowEnergy() async {
        let filter = HallucinationFilter()
        #expect(await filter.process("Thanks for watching!", context: context(rms: 0.02)) == "")
    }

    @Test func keepsRealSpeech() async {
        let filter = HallucinationFilter()
        let text = "Let's ship the new feature today."
        #expect(await filter.process(text, context: context(rms: 0.3)) == text)
    }

    @Test func keepsLoudThankYou() async {
        // A genuinely spoken "thank you" (normal energy) must survive.
        let filter = HallucinationFilter()
        #expect(await filter.process("Thank you.", context: context(rms: 0.3)) == "Thank you.")
    }
}

@Suite struct DictionaryReplacerTests {
    @Test func replacesWordBoundaryCaseInsensitive() async {
        let replacer = DictionaryReplacer(rules: [
            ReplacementRule(spoken: "cube cuddle", replacement: "kubectl"),
            ReplacementRule(spoken: "open flow", replacement: "OpenFlow"),
        ])
        let context = DictationContext(audioDuration: 2, peakRMS: 0.3, engineID: "test")
        let out = await replacer.process("Run Cube Cuddle to deploy Open Flow.", context: context)
        #expect(out == "Run kubectl to deploy OpenFlow.")
    }

    @Test func doesNotReplaceInsideWords() async {
        let replacer = DictionaryReplacer(rules: [ReplacementRule(spoken: "flow", replacement: "FLOW")])
        let context = DictationContext(audioDuration: 2, peakRMS: 0.3, engineID: "test")
        let out = await replacer.process("Workflows keep flowing, go with the flow.", context: context)
        #expect(out == "Workflows keep flowing, go with the FLOW.")
    }

    @Test func longestRuleWins() async {
        let replacer = DictionaryReplacer(rules: [
            ReplacementRule(spoken: "sequel", replacement: "SQL"),
            ReplacementRule(spoken: "sequel pro", replacement: "Sequel Pro"),
        ])
        let context = DictationContext(audioDuration: 2, peakRMS: 0.3, engineID: "test")
        let out = await replacer.process("Open sequel pro and write sequel.", context: context)
        #expect(out == "Open Sequel Pro and write SQL.")
    }
}
