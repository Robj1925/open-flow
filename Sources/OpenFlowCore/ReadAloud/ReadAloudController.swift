import Foundation
import os

/// Lifecycle of one read-aloud request.
public enum ReadAloudState: Equatable {
    case idle
    /// Voice model is downloading or loading before the first sentence.
    case preparing
    case speaking
    /// Shown briefly, then falls back to `.idle`.
    case failed(String)

    public var isIdle: Bool { if case .idle = self { return true }; return false }
    public var isActive: Bool {
        switch self {
        case .preparing, .speaking: return true
        case .idle, .failed: return false
        }
    }
}

/// Reads text aloud with the on-device Kokoro voice. Text is split into
/// sentences; each is synthesized and queued for playback while the next one
/// renders, so speech starts after the first sentence (about a quarter of a
/// second) rather than after the whole selection.
///
/// Entry points: the macOS "Read Aloud with OpenFlow" Service (right-click on
/// any selected text), the menu bar, and `openflow-cli speak`.
@MainActor
public final class ReadAloudController: ObservableObject {
    @Published public private(set) var state: ReadAloudState = .idle
    @Published public private(set) var voiceState: ModelState = .unloaded

    /// Selections beyond this are cut off, with a note in the status: the
    /// synthesizer would otherwise churn for minutes on an accidental ⌘A.
    public static let maximumCharacters = 20_000

    public let synthesizer: SpeechSynthesizer
    private let logger = Logger(subsystem: "dev.openflow.OpenFlow", category: "ReadAloud")
    private let player = AudioPlaybackEngine()
    private let settings: AppSettings
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(synthesizer: SpeechSynthesizer = KokoroSpeechSynthesizer(), settings: AppSettings = .shared) {
        self.synthesizer = synthesizer
        self.settings = settings
    }

    public var isActive: Bool { state.isActive }

    // MARK: - Voice model

    /// Downloads (first run) and loads the voice. Idempotent; concurrent
    /// callers share the same outcome through `voiceState`.
    public func prepareVoice() async {
        if case .ready = voiceState { return }
        if case .loading = voiceState {
            while voiceState == .loading { try? await Task.sleep(nanoseconds: 100_000_000) }
            return
        }
        if case .downloading = voiceState {
            while case .downloading = voiceState { try? await Task.sleep(nanoseconds: 100_000_000) }
            return
        }
        voiceState = KokoroSpeechSynthesizer.isDownloaded ? .loading : .downloading(progress: 0)
        do {
            try await synthesizer.prepare()
            voiceState = .ready
        } catch {
            voiceState = .failed(error.localizedDescription)
        }
    }

    public func unloadVoice() async {
        stop()
        await synthesizer.unload()
        voiceState = .unloaded
    }

    // MARK: - Speaking

    /// Starts reading `text`, replacing anything currently being read.
    public func speak(_ text: String) {
        stop()
        generation += 1
        let thisGeneration = generation

        var truncated = false
        var body = text
        if body.count > Self.maximumCharacters {
            body = String(body.prefix(Self.maximumCharacters))
            truncated = true
        }
        let chunks = TextChunker.chunks(body)
        guard !chunks.isEmpty else {
            fail("Nothing readable in the selection", generation: thisGeneration)
            return
        }

        state = voiceState == .ready ? .speaking : .preparing
        let speed = Float(settings.readAloudSpeed)
        logger.log("Read aloud requested: \(chunks.count) chunk(s), \(body.count) characters, speed \(speed)")
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(chunks: chunks, speed: speed, truncated: truncated, generation: thisGeneration)
        }
    }

    /// Hotkey entry point: reads whatever is selected in the frontmost app,
    /// or stops if something is already being read (press again to stop).
    public func speakSelection() {
        if isActive {
            stop()
            return
        }
        generation += 1
        let thisGeneration = generation
        state = .preparing
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await SelectionReader.copySelectedText()
                guard self.generation == thisGeneration else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.fail("Select some text first", generation: thisGeneration)
                    return
                }
                self.speak(text)
            } catch {
                guard self.generation == thisGeneration else { return }
                self.fail(error.localizedDescription, generation: thisGeneration)
            }
        }
    }

    /// Stops playback and abandons any sentences still rendering.
    public func stop() {
        task?.cancel()
        task = nil
        generation += 1
        Task { await player.stop() }
        if state.isActive { state = .idle }
    }

    private func run(chunks: [String], speed: Float, truncated: Bool, generation thisGeneration: Int) async {
        await prepareVoice()
        guard generation == thisGeneration, !Task.isCancelled else { return }
        if case .failed(let message) = voiceState {
            fail("Voice unavailable: \(message)", generation: thisGeneration)
            return
        }
        state = .speaking

        let started = Date()
        for (index, chunk) in chunks.enumerated() {
            guard generation == thisGeneration, !Task.isCancelled else { return }
            do {
                let synthStart = Date()
                let clip = try await synthesizer.synthesize(chunk, speed: speed)
                guard generation == thisGeneration, !Task.isCancelled else { return }
                try await player.enqueue(clip)
                let synthMs = Int(Date().timeIntervalSince(synthStart) * 1000)
                logger.log("Chunk \(index + 1)/\(chunks.count): \(synthMs) ms synth, \(clip.duration, format: .fixed(precision: 2)) s audio")
            } catch {
                guard generation == thisGeneration else { return }
                await player.stop()
                fail("Read aloud failed: \(error.localizedDescription)", generation: thisGeneration)
                return
            }
        }

        await player.waitUntilDrained()
        guard generation == thisGeneration else { return }
        logger.log("Read aloud finished after \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        if truncated {
            fail("Stopped after \(Self.maximumCharacters) characters", generation: thisGeneration)
        } else {
            state = .idle
        }
    }

    /// Surfaces a message for a moment, then returns to idle unless a newer
    /// request has taken over.
    private func fail(_ message: String, generation thisGeneration: Int) {
        logger.error("\(message, privacy: .public)")
        state = .failed(message)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, self.generation == thisGeneration else { return }
            if case .failed = self.state { self.state = .idle }
        }
    }
}
