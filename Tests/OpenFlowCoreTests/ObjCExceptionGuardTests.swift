import Testing
import OpenFlowCore

@Suite struct ObjCExceptionGuardTests {
    @Test func passesThroughWhenNothingIsRaised() throws {
        var ran = false
        try ObjCExceptionGuard.run { ran = true }
        #expect(ran)
    }

    @Test func turnsAnObjectiveCExceptionIntoAThrownError() {
        var description = ""
        do {
            try ObjCExceptionGuard.run {
                ObjCExceptionGuard.raiseExceptionForTesting(reason: "Failed to create tap due to format mismatch")
            }
        } catch {
            description = String(describing: error)
        }
        // Without the guard this raise would abort the test process.
        #expect(description.contains("OpenFlow.ObjCException"))
        #expect(description.contains("format mismatch"))
    }
}
