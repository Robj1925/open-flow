import Testing
import OpenFlowCore

/// Engine that "recognizes" one word per 0.5 s of audio and records calls.
private final class CountingEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    var isReady = true
    var calls: [Int] = []
    var delay: UInt64 = 0

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() {}

    func transcribe(_ audio: [Float], hints: TranscriptionHints) async throws -> EngineResult {
        calls.append(audio.count)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let words = audio.count / Int(AudioCaptureEngine.targetSampleRate / 2)
        let text = (0..<words).map { "w\($0 + 1)" }.joined(separator: " ")
        return EngineResult(text: text, processingTime: 0)
    }
}

@Suite struct LiveTranscriberTests {
    private let rate = Int(AudioCaptureEngine.targetSampleRate)

    @MainActor @Test func emitsGrowingPartialsAsAudioArrives() async throws {
        let engine = CountingEngine()
        let live = LiveTranscriber()
        live.interval = 0.02
        let buffer = Buffer()
        var partials: [String] = []
        live.onPartial = { partials.append($0) }
        live.start(hints: TranscriptionHints(), engine: { engine }, samples: { buffer.samples })

        buffer.samples = Array(repeating: 0, count: rate)          // 1 s → 2 words
        try await Task.sleep(nanoseconds: 120_000_000)
        buffer.samples = Array(repeating: 0, count: rate * 2)      // 2 s → 4 words
        try await Task.sleep(nanoseconds: 120_000_000)
        live.stop()

        #expect(partials.first == "w1 w2")
        #expect(partials.last == "w1 w2 w3 w4")
        // No new audio between passes → no redundant engine calls.
        #expect(engine.calls.count == 2)
    }

    @MainActor @Test func waitsForMinimumAudio() async throws {
        let engine = CountingEngine()
        let live = LiveTranscriber()
        live.interval = 0.02
        let buffer = Buffer()
        buffer.samples = Array(repeating: 0, count: rate / 4)      // 0.25 s: below the floor
        live.start(hints: TranscriptionHints(), engine: { engine }, samples: { buffer.samples })
        try await Task.sleep(nanoseconds: 100_000_000)
        live.stop()
        #expect(engine.calls.isEmpty)
    }

    @MainActor @Test func dropsResultsAfterStop() async throws {
        let engine = CountingEngine()
        engine.delay = 150_000_000
        let live = LiveTranscriber()
        live.interval = 0.02
        let buffer = Buffer()
        buffer.samples = Array(repeating: 0, count: rate)
        var partials: [String] = []
        live.onPartial = { partials.append($0) }
        live.start(hints: TranscriptionHints(), engine: { engine }, samples: { buffer.samples })
        try await Task.sleep(nanoseconds: 50_000_000)     // pass is inside the engine
        live.stop()
        try await Task.sleep(nanoseconds: 200_000_000)    // it finishes after stop
        #expect(engine.calls.count == 1)
        #expect(partials.isEmpty)
    }

    @MainActor @Test func skipsPassesWhileEngineIsUnavailable() async throws {
        let engine = CountingEngine()
        let live = LiveTranscriber()
        live.interval = 0.02
        let buffer = Buffer()
        buffer.samples = Array(repeating: 0, count: rate)
        var ready = false
        live.start(hints: TranscriptionHints(), engine: { ready ? engine : nil }, samples: { buffer.samples })
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(engine.calls.isEmpty)
        ready = true
        try await Task.sleep(nanoseconds: 80_000_000)
        live.stop()
        #expect(engine.calls.count == 1)
    }
}

private final class Buffer: @unchecked Sendable {
    var samples: [Float] = []
}
