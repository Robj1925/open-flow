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

    @Test func skipsCleanTranscriptsEntirely() async {
        let stage = LLMCleanerStage(
            cleaner: StubCleaner(available: true) { _ in "should not run" },
            enabled: true,
            vocabulary: nil
        )
        let clean = "Send the quarterly report to Sarah before Friday."
        #expect(await stage.process(clean, context: context) == clean)
    }
}

@Suite struct NeedsCleanupHeuristicTests {
    @Test func detectsFillers() {
        #expect(LLMCleanerStage.needsCleanup("um send the report"))
        #expect(LLMCleanerStage.needsCleanup("So, uh, let's start over."))
        #expect(LLMCleanerStage.needsCleanup("Ship it Friday, no wait, Monday."))
        #expect(LLMCleanerStage.needsCleanup("I mean the second draft, you know."))
    }

    @Test func detectsStutters() {
        #expect(LLMCleanerStage.needsCleanup("refactor the the login page"))
        #expect(LLMCleanerStage.needsCleanup("it is is kind of broken"))
    }

    @Test func passesCleanText() {
        #expect(!LLMCleanerStage.needsCleanup("Send the quarterly report to Sarah before Friday."))
        #expect(!LLMCleanerStage.needsCleanup("Run kubectl apply to deploy the new build."))
        // Words merely containing filler substrings must not trigger.
        #expect(!LLMCleanerStage.needsCleanup("The drummer hummed a tune."))
        #expect(!LLMCleanerStage.needsCleanup("I like this design a lot."))
    }
}
