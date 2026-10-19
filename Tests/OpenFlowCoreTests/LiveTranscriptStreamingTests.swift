import OpenFlowCore
import Testing

@Suite struct LiveTranscriptStreamingTests {
    @Test func lastWordStaysTentativeUntilSettled() {
        let growing = LiveTranscript.streaming("Google DeepMind just drop", settled: false)
        #expect(growing.committed == ["Google", "DeepMind", "just"])
        #expect(growing.tentative == ["drop"])

        let settled = LiveTranscript.streaming("Google DeepMind just dropped", settled: true)
        #expect(settled.committed == ["Google", "DeepMind", "just", "dropped"])
        #expect(settled.tentative.isEmpty)
    }

    @Test func emptyTextIsEmpty() {
        #expect(LiveTranscript.streaming("", settled: false).isEmpty)
        #expect(LiveTranscript.streaming("   ", settled: false).isEmpty)
    }
}
