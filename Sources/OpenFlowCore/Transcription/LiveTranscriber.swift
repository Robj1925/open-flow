import Foundation

/// What the live preview shows: words that will not change any more, then
/// the tail the engine is still making up its mind about.
public struct LiveTranscript: Equatable, Sendable {
    public var committed: [String]
    public var tentative: [String]

    public init(committed: [String] = [], tentative: [String] = []) {
        self.committed = committed
        self.tentative = tentative
    }

    public var text: String { (committed + tentative).joined(separator: " ") }
    public var isEmpty: Bool { committed.isEmpty && tentative.isEmpty }

    /// Splits a streaming recognizer's monotonic transcript. Emitted tokens
    /// are final, but the last word may still be receiving sub-word pieces,
    /// so it stays tentative until the text has been quiet for a moment.
    public static func streaming(_ text: String, settled: Bool) -> LiveTranscript {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if settled || words.isEmpty {
            return LiveTranscript(committed: words, tentative: [])
        }
        return LiveTranscript(committed: Array(words.dropLast()), tentative: [words[words.count - 1]])
    }
}

/// Turns successive hypotheses for a growing recording into a transcript
/// whose prefix stays put. Pure logic, no engine, so it is unit-testable.
///
/// Stability comes from local agreement: a word is committed once two
/// consecutive passes agree on it and everything before it. Committed words
/// are append-only: their text, case and punctuation never change afterwards
/// (the final transcript is produced by the normal pipeline anyway). The one
/// exception is when two passes in a row agree on a *different* beginning,
/// which means the engine firmly changed its mind (a phantom first word, say);
/// following it once beats showing a wrong word for the whole dictation.
///
/// Bounded latency comes from freezing: once committed audio is older than
/// `keepSeconds` and a pause of at least `minimumPause` follows a committed
/// word, that word and everything before it are frozen and the decode window
/// moves to the middle of the pause. If no real pause shows up before the
/// window reaches `forceCutAfter` (the model's single-chunk limit is 15 s),
/// the widest inter-word gap of at least `forcedMinimumGap` is used instead.
/// Each pass then transcribes only the recent window, so a long dictation
/// keeps the same cadence as a short one.
public struct LiveTranscriptAssembler: Sendable {
    public private(set) var frozen: [String] = []
    public private(set) var committed: [String] = []
    private var previous: [String] = []
    /// Seconds of audio, from the start of the recording, no longer decoded.
    public private(set) var windowStart: TimeInterval = 0
    /// Audio younger than this is never frozen; the model keeps this much
    /// context in front of the words it is still deciding on.
    public var keepSeconds: TimeInterval = 6
    /// Smallest gap between two words that counts as a safe place to cut.
    public var minimumPause: TimeInterval = 0.35
    /// Window length past which a cut at a smaller gap is accepted.
    public var forceCutAfter: TimeInterval = 13
    public var forcedMinimumGap: TimeInterval = 0.12

    public init() {}

    /// Feeds one pass over the current decode window. `timings`, when given,
    /// must line up with `words` one to one and be relative to the window.
    public mutating func ingest(words: [String], timings: [TimedWord]?, windowDuration: TimeInterval) -> LiveTranscript {
        let agreed = Self.commonPrefixLength(previous, words)
        if agreed > committed.count {
            if Self.commonPrefixLength(committed, words) == committed.count {
                // The word at the old boundary was committed while it was the
                // last word heard, so it may carry a sentence-final period or
                // capital that no longer applies ("Mind." followed by "just").
                // Refresh just that one surface as the tail grows past it.
                if let boundary = committed.indices.last {
                    committed[boundary] = words[boundary]
                }
                committed.append(contentsOf: words[committed.count..<agreed])
            } else {
                committed = Array(words[0..<agreed])
            }
        }
        let tentative = Self.tentativeTail(committed: committed, words: words)
        previous = words
        trimWindow(timings: timings, windowDuration: windowDuration)
        return LiveTranscript(committed: frozen + committed, tentative: tentative)
    }

    /// The part of `words` that comes after the committed prefix. When the
    /// engine's current view of the committed region differs (it dropped or
    /// merged a word), anchor on the last committed word instead of a raw
    /// index so the new words at the end still show instead of vanishing.
    static func tentativeTail(committed: [String], words: [String]) -> [String] {
        guard let last = committed.last else { return words }
        if commonPrefixLength(committed, words) == committed.count {
            return Array(words.dropFirst(committed.count))
        }
        let from = max(0, committed.count - 3)
        if let anchor = words.indices.dropFirst(from).first(where: { key(words[$0]) == key(last) }) {
            return Array(words[(anchor + 1)...])
        }
        return words.count > committed.count ? Array(words[committed.count...]) : []
    }

    private mutating func trimWindow(timings: [TimedWord]?, windowDuration: TimeInterval) {
        guard let timings, timings.count == previous.count,
              committed.count >= 2, committed.count <= previous.count,
              Self.commonPrefixLength(committed, previous) == committed.count,
              windowDuration > keepSeconds
        else { return }
        let limit = windowDuration - keepSeconds
        var pauseCut: Int?
        var forcedCut: (index: Int, gap: TimeInterval)?
        for i in 0..<(committed.count - 1) where timings[i].end <= limit {
            let gap = timings[i + 1].start - timings[i].end
            if gap >= minimumPause {
                pauseCut = i
            } else if gap >= forcedMinimumGap, forcedCut.map({ gap > $0.gap }) ?? true {
                forcedCut = (i, gap)
            }
        }
        guard let cut = pauseCut ?? (windowDuration > forceCutAfter ? forcedCut?.index : nil) else { return }
        frozen.append(contentsOf: committed[0...cut])
        committed.removeFirst(cut + 1)
        previous.removeFirst(cut + 1)
        windowStart += (timings[cut].end + timings[cut + 1].start) / 2
    }

    /// Words compare without case or punctuation, so "hello" and "Hello,"
    /// count as agreement.
    static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func commonPrefixLength(_ a: [String], _ b: [String]) -> Int {
        var n = 0
        while n < a.count, n < b.count, key(a[n]) == key(b[n]) { n += 1 }
        return n
    }
}

/// Produces a running transcript while a recording is still in progress by
/// re-transcribing the recent audio at a steady cadence. The final transcript
/// is still produced by the normal pipeline after key release; this only
/// feeds the on-screen preview.
///
/// Each pass runs the decode window through the engine and hands the result
/// to a `LiveTranscriptAssembler`, which keeps the displayed prefix stable
/// and trims the window at pauses so passes stay fast. The cadence adapts:
/// the next pass starts `interval` after the previous one finishes.
@MainActor
public final class LiveTranscriber {
    /// Pause between passes, on top of the engine's own processing time.
    public var interval: TimeInterval = 0.1
    /// Passes are skipped until this much audio exists in the decode window.
    public var minimumAudio: TimeInterval = 0.45
    /// A pass runs only when at least this much new audio arrived.
    public var minimumNewAudio: TimeInterval = 0.2

    /// Poll interval for the streaming mode; the recognizer decides when it has
    /// a full chunk to decode.
    public var streamingInterval: TimeInterval = 0.08
    /// Quiet time after which the last streamed word counts as complete.
    public var streamingSettleTime: TimeInterval = 0.6

    /// Stable-prefix transcript, on the main actor, each time a pass completes.
    public var onUpdate: ((LiveTranscript) -> Void)?
    /// Raw engine hypothesis for the decode window, before assembly. Diagnostics only.
    public var onPass: ((String) -> Void)?
    /// Plain-text convenience for callers that do not distinguish the tail.
    public var onPartial: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var generation = 0

    public init() {}

    public var isRunning: Bool { task != nil }

    /// Starts polling. `engine` is asked for each pass so a model that
    /// finishes loading mid-recording joins in; return nil to skip a pass.
    public func start(
        hints: TranscriptionHints,
        engine: @escaping @MainActor () -> TranscriptionEngine?,
        samples: @escaping @Sendable () -> [Float]
    ) {
        stop()
        generation += 1
        let thisGeneration = generation
        let sampleRate = AudioCaptureEngine.targetSampleRate
        task = Task { [weak self] in
            var assembler = LiveTranscriptAssembler()
            var lastCount = 0
            var passes = 0
            while !Task.isCancelled {
                guard let self, self.generation == thisGeneration else { return }
                let audio = samples()
                let windowStart = min(Int(assembler.windowStart * sampleRate), audio.count)
                let window = Array(audio[windowStart...])
                let needed = Int(self.minimumAudio * sampleRate)
                if window.count < needed {
                    // The mic fills the buffer in real time, so sleep only
                    // until the floor is reached instead of a whole interval.
                    let missing = Double(needed - window.count) / sampleRate
                    let wait = min(self.interval, max(0.05, missing))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                let fresh = Double(audio.count - lastCount) >= self.minimumNewAudio * sampleRate
                if fresh, let engine = engine() {
                    lastCount = audio.count
                    let started = Date()
                    if let result = try? await engine.transcribe(window, hints: hints),
                       !Task.isCancelled, self.generation == thisGeneration {
                        passes += 1
                        let words = result.words?.map(\.text)
                            ?? result.text.split(whereSeparator: \.isWhitespace).map(String.init)
                        let timings = result.words?.count == words.count ? result.words : nil
                        let windowBefore = assembler.windowStart
                        let transcript = assembler.ingest(
                            words: words,
                            timings: timings,
                            windowDuration: Double(window.count) / sampleRate
                        )
                        if assembler.windowStart != windowBefore {
                            TimingLog.shared.note("live window cut: decoding from \(String(format: "%.1f", assembler.windowStart)) s, \(assembler.frozen.count) words frozen")
                        }
                        if passes <= 3 {
                            TimingLog.shared.note("live pass \(passes): \(Int(Date().timeIntervalSince(started) * 1000)) ms for \(String(format: "%.1f", Double(window.count) / sampleRate)) s of audio")
                        }
                        self.onPass?(words.joined(separator: " "))
                        self.onUpdate?(transcript)
                        self.onPartial?(transcript.text)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    /// Streaming mode: feeds new audio to a true streaming recognizer and
    /// shows its monotonic transcript. Nothing is ever rewritten; the newest
    /// word is tentative only while sub-word pieces may still be arriving.
    public func startStreaming(
        engine: StreamingPreviewEngine,
        samples: @escaping @Sendable () -> [Float]
    ) {
        stop()
        generation += 1
        let thisGeneration = generation
        task = Task { [weak self] in
            do {
                try await engine.beginSession()
            } catch {
                TimingLog.shared.note("stream: session start failed: \(error.localizedDescription)")
                return
            }
            var fed = 0
            var feeds = 0
            var feedTotal: TimeInterval = 0
            var feedMax: TimeInterval = 0
            var lastText = ""
            var lastChange = Date()
            var settledShown = true
            while !Task.isCancelled {
                guard let self, self.generation == thisGeneration else { return }
                let audio = samples()
                if audio.count > fed {
                    let new = Array(audio[fed...])
                    fed = audio.count
                    let started = Date()
                    guard let text = try? await engine.feed(new), self.generation == thisGeneration else {
                        try? await Task.sleep(nanoseconds: UInt64(self.streamingInterval * 1_000_000_000))
                        continue
                    }
                    let took = Date().timeIntervalSince(started)
                    feeds += 1
                    feedTotal += took
                    feedMax = max(feedMax, took)
                    if feeds <= 3 {
                        TimingLog.shared.note("stream feed \(feeds): \(Int(took * 1000)) ms, \(String(format: "%.1f", Double(fed) / AudioCaptureEngine.targetSampleRate)) s fed, \(text.count) chars")
                    }
                    if text != lastText {
                        lastText = text
                        lastChange = Date()
                        settledShown = false
                        self.onPass?(text)
                        let transcript = LiveTranscript.streaming(text, settled: false)
                        self.onUpdate?(transcript)
                        self.onPartial?(transcript.text)
                    }
                }
                if !settledShown, Date().timeIntervalSince(lastChange) >= self.streamingSettleTime {
                    settledShown = true
                    let transcript = LiveTranscript.streaming(lastText, settled: true)
                    self.onUpdate?(transcript)
                    self.onPartial?(transcript.text)
                }
                try? await Task.sleep(nanoseconds: UInt64(self.streamingInterval * 1_000_000_000))
            }
            if feeds > 0 {
                TimingLog.shared.note("stream summary: \(feeds) feeds, avg \(Int(feedTotal / Double(feeds) * 1000)) ms, max \(Int(feedMax * 1000)) ms, \(String(format: "%.1f", Double(fed) / AudioCaptureEngine.targetSampleRate)) s of audio")
            }
        }
    }

    /// Stops polling. A pass already inside the engine finishes on its own but
    /// its result is dropped.
    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
