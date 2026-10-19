import OpenFlowCore
import Testing

@Suite struct AudioStartFailureTests {
    @Test func classifiesItsOwnErrors() {
        let error = AudioCaptureEngine.makeError(.grantStale, "stale grant")
        #expect(AudioCaptureEngine.failure(of: error) == .grantStale)
        #expect(String(describing: error).contains("stale grant"))
    }

    @Test func ignoresForeignErrors() {
        struct Other: Error {}
        #expect(AudioCaptureEngine.failure(of: Other()) == nil)
    }
}
