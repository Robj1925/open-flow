import Testing
import OpenFlowCore

/// Stand-in cleaner so the stage's control flow is testable without the OS model.
private final class StubCleaner: TextCleaner, @unchecked Sendable {
    let id = "stub"
    let available: Bool
    let transform: @Sendable (String) -> String
    private(set) var callCount = 0

    init(available: Bool, transform: @escaping @Sendable (String) -> String) {
        self.available = available
        self.transform = transform
    }

    var availability: CleanerAvailability { available ? .available : .unavailable(reason: "test") }
    func prewarm() {}
    func clean(_ text: String, vocabulary: String?) async -> String {
        transform(text)
    }
}

@Suite struct LLMCleanerStageTests {
    private let context = DictationContext(audioDuration: 2, peakRMS: 0.3, engineID: "test")

    @Test func cleansWhenEnabledAndAvailable() async {
        let stage = LLMCleanerStage(
            cleaner: StubCleaner(available: true) { _ in "cleaned" },
            enabled: true,
            vocabulary: nil
        )
        #expect(await stage.process("um raw text", context: context) == "cleaned")
    }

    @Test func passesThroughWhenDisabled() async {
        let stage = LLMCleanerStage(
            cleaner: StubCleaner(available: true) { _ in "cleaned" },
            enabled: false,
            vocabulary: nil
        )
        #expect(await stage.process("um raw text", context: context) == "um raw text")
    }

    @Test func passesThroughWhenUnavailable() async {
        let stage = LLMCleanerStage(
            cleaner: StubCleaner(available: false) { _ in "cleaned" },
            enabled: true,
            vocabulary: nil
        )
        #expect(await stage.process("um raw text", context: context) == "um raw text")
    }

    @Test func skipsEmptyText() async {
        let stage = LLMCleanerStage(
            cleaner: StubCleaner(available: true) { _ in "should not run" },
            enabled: true,
            vocabulary: nil
        )
        #expect(await stage.process("", context: context) == "")
    }
}
