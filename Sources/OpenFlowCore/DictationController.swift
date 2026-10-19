import AppKit
import Foundation

/// Orchestrates the whole dictation lifecycle:
/// hotkey → capture → transcribe → post-process → inject → history.
/// The single owner of `DictationState` transitions.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var modelState: ModelState = .unloaded
    /// Load state of the optional streaming preview model (Parakeet Unified).
    @Published public private(set) var streamingPreviewState: ModelState = .unloaded
    @Published public private(set) var statusMessage: String?
    /// Live mic level for the HUD waveform (0...~1).
    @Published public private(set) var level: Float = 0
    /// True while the LLM cleanup stage is running (HUD shows "Cleaning up…").
    @Published public private(set) var isCleaningUp = false
    /// Running transcript of the current recording, for the live preview.
    /// Empty when the preview is off or nothing has been recognized yet.
    @Published public private(set) var liveTranscript = LiveTranscript()
    /// True once the first audio buffer arrived: the mic is really open. The
    /// HUD appears ~0.3 s before that, so it uses this to colour its dot.
    @Published public private(set) var micLive = false

    public let audio = AudioCaptureEngine()
    public let sounds = SoundPlayer()
    public let injector = TextInjector()
    public let hotkeys = HotkeyManager()
    public let live = LiveTranscriber()
    public let cleaner: any TextCleaner = AppleFoundationCleaner()
    /// Esc pressed while no dictation is in flight. Return true to swallow
    /// the keystroke (Read Aloud uses this to stop playback).
    public var onEscWhileIdle: (() -> Bool)?
    /// Read Aloud chord pressed anywhere on the system.
    public var onReadAloudHotkey: (() -> Void)?

    /// Availability of the LLM cleanup backend, for Settings to display.
    public var cleanupAvailability: CleanerAvailability { cleaner.availability }

    private let settings: AppSettings
    public let history: HistoryStore
    public let dictionary: DictionaryStore

    private var engine: TranscriptionEngine?
    /// Preset id the current `engine` was built from.
    private var loadedPresetID: String?
    /// Streaming recognizer for the live preview, when enabled and loaded.
    private var streamingEngine: StreamingPreviewEngine?
    private var streamingLoadGeneration = 0
    /// Bumped to invalidate in-flight transcriptions (Esc during transcribe).
    private var generation = 0
    /// Auto mode: a quick tap armed toggle; the next press stops.
    private var toggleArmed = false
    /// Frontmost app at hotkey-down, for history attribution.
    private var targetAppBundleID: String?

    /// Fired on the main queue after a failed mic start, with the reason. The
    /// app shell uses it to clear a stale permission entry and re-prompt.
    public var onMicrophoneAccessFailed: ((AudioCaptureEngine.StartFailure) -> Void)?

    public init(settings: AppSettings = .shared) {
        self.settings = settings
        self.history = HistoryStore()
        self.dictionary = DictionaryStore()
        wireCallbacks()
    }

    // MARK: - Startup

    /// Call once at app launch (after permissions exist).
    public func start() {
        audio.prepare()
        hotkeys.hotkey = settings.hotkey
        hotkeys.readAloudHotkey = settings.readAloudHotkey
        hotkeys.start()
        if settings.cleanupEnabled { cleaner.prewarm() }
        Task { await loadSelectedEngine() }
        if settings.streamingPreviewEnabled {
            Task { await loadStreamingPreview() }
        }
    }

    /// Re-reads settings that affect live components (hotkey, model).
    public func settingsChanged() {
        hotkeys.hotkey = settings.hotkey
        syncStreamingPreview()
        hotkeys.readAloudHotkey = settings.readAloudHotkey
        sounds.isEnabled = settings.soundsEnabled
        if settings.cleanupEnabled { cleaner.prewarm() }
        if settings.modelPresetID != loadedPresetID {
            Task { await loadSelectedEngine() }
        }
    }

    public func loadSelectedEngine() async {
        let preset = settings.modelPreset
        let newEngine = ModelManager.shared.makeEngine(for: preset)
        let downloaded = ModelManager.shared.isDownloaded(preset)
        modelState = downloaded ? .loading : .downloading(progress: 0)
        do {
            try await newEngine.prepare { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.modelState else { return }
                    self.modelState = .downloading(progress: fraction)
                }
            }
            // Swap only after the new engine is warm so dictation never breaks.
            engine?.unload()
            engine = newEngine
            loadedPresetID = preset.id
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Streaming preview model

    /// Downloads (if needed) and loads the streaming preview tier from settings.
    public func loadStreamingPreview() async {
        guard let tier = StreamingPreviewEngine.Tier(rawValue: settings.streamingPreviewTier) else { return }
        streamingLoadGeneration += 1
        let thisLoad = streamingLoadGeneration
        if let current = streamingEngine {
            streamingEngine = nil
            Task { await current.unload() }
        }
        let newEngine = StreamingPreviewEngine(tier: tier)
        streamingPreviewState = StreamingPreviewEngine.isDownloaded(tier) ? .loading : .downloading(progress: 0)
        do {
            try await newEngine.prepare { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.streamingLoadGeneration == thisLoad,
                          case .downloading = self.streamingPreviewState else { return }
                    self.streamingPreviewState = .downloading(progress: fraction)
                }
            }
            guard streamingLoadGeneration == thisLoad else {
                await newEngine.unload()
                return
            }
            streamingEngine = newEngine
            streamingPreviewState = .ready
        } catch {
            guard streamingLoadGeneration == thisLoad else { return }
            streamingPreviewState = .failed(error.localizedDescription)
        }
    }

    public func unloadStreamingPreview() {
        streamingLoadGeneration += 1
        if let current = streamingEngine {
            streamingEngine = nil
            Task { await current.unload() }
        }
        streamingPreviewState = .unloaded
    }

    private func syncStreamingPreview() {
        guard settings.streamingPreviewEnabled else {
            if streamingEngine != nil || streamingPreviewState != .unloaded { unloadStreamingPreview() }
            return
        }
        let wanted = settings.streamingPreviewTier
        let loadedTier = streamingEngine?.tier.rawValue
        let inFlight: Bool
        switch streamingPreviewState {
        case .downloading, .loading: inFlight = true
        default: inFlight = false
        }
        if loadedTier != wanted || (!inFlight && streamingEngine == nil) {
            Task { await loadStreamingPreview() }
        }
    }

    /// The streaming engine applies only to English and only when it is ready.
    private var streamingEngineForPreview: StreamingPreviewEngine? {
        guard settings.streamingPreviewEnabled, settings.language == "en",
              streamingPreviewState == .ready else { return nil }
        return streamingEngine
    }

    // MARK: - Hotkey handling

    private func wireCallbacks() {
        hotkeys.onHotkeyDown = { [weak self] in self?.hotkeyDown() }
        hotkeys.onHotkeyUp = { [weak self] duration in self?.hotkeyUp(afterPress: duration) }
        hotkeys.onEsc = { [weak self] in self?.escPressed() ?? false }
        hotkeys.onReadAloudHotkey = { [weak self] in self?.onReadAloudHotkey?() }

        audio.onFirstBuffer = { [weak self] in
            TimingLog.shared.note("first buffer on main → ready tone")
            self?.micLive = true
            self?.sounds.play(.ready)
        }
        audio.onLevel = { [weak self] rms in self?.level = rms }
        audio.onMaxDuration = { [weak self] in self?.finishRecording() }
        // Input device vanished mid-recording (e.g. AirPods disconnected) and
        // capture could not resume: transcribe whatever was captured so far.
        audio.onInputDeviceLost = { [weak self] in self?.finishRecording() }
        // start() is asynchronous (device bring-up can take seconds on
        // Bluetooth); a failed start lands here instead of throwing.
        audio.onStartFailed = { [weak self] error in
            TimingLog.shared.note("audio start failed: \(error.localizedDescription)")
            guard let self, case .recording = self.state else { return }
            self.transition(to: .idle, status: "Microphone unavailable: \(error.localizedDescription)")
            if let failure = AudioCaptureEngine.failure(of: error) {
                self.onMicrophoneAccessFailed?(failure)
            }
        }
    }

    private func hotkeyDown() {
        switch state {
        case .idle:
            TimingLog.shared.begin("hotkey down")
            beginRecording()
        case .recording:
            // Toggle mode (or auto with toggle armed): second press stops.
            if settings.activationMode == .toggle || toggleArmed {
                finishRecording()
            }
        case .transcribing, .injecting:
            break // no re-entrancy in v1
        }
    }

    private func hotkeyUp(afterPress duration: TimeInterval) {
        guard case .recording = state else { return }
        TimingLog.shared.note("hotkey up after \(Int(duration * 1000)) ms press")
        switch settings.activationMode {
        case .hold:
            finishRecording()
        case .toggle:
            break // stops on second press
        case .auto:
            if duration < 0.35 {
                if !toggleArmed {
                    toggleArmed = true
                    statusMessage = "Listening — tap \(settings.hotkey.displayName) or Esc to stop"
                }
            } else {
                finishRecording()
            }
        }
    }

    /// Returns true when Esc was consumed (swallow the keystroke).
    private func escPressed() -> Bool {
        switch state {
        case .recording:
            live.stop()
            audio.cancel()
            toggleArmed = false
            sounds.play(.cancel)
            transition(to: .idle, status: "Cancelled")
            return true
        case .transcribing:
            generation += 1 // stale-drop any in-flight result
            transition(to: .idle, status: "Cancelled")
            return true
        case .idle:
            return onEscWhileIdle?() ?? false
        case .injecting:
            return false
        }
    }

    // MARK: - Session flow

    private func beginRecording() {
        toggleArmed = false
        targetAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Warm the cleanup model while the user is still speaking — covers
        // Apple Intelligence being enabled mid-session (no-op when warm).
        if settings.cleanupEnabled { cleaner.prewarm() }
        // Optimistic transition: start() never blocks (device bring-up runs on
        // the audio session queue), and a failure rolls back via onStartFailed.
        micLive = false
        audio.start()
        transition(to: .recording(mode: settings.activationMode, startedAt: Date()), status: nil)
        TimingLog.shared.note("HUD shown")

        // Warm the recognizer while the mic is still opening. The first pass
        // after an idle period costs ~0.4 s extra on the Neural Engine; paying
        // it on silence now, in parallel with device bring-up, means neither
        // the first preview words nor a short dictation's final pass wait for
        // it. The engine serializes calls, so this never races a real pass.
        if modelState == .ready, let engine {
            let warmHints = TranscriptionHints(language: settings.language, vocabulary: nil)
            let silence = [Float](repeating: 0, count: Int(AudioCaptureEngine.targetSampleRate * 0.6))
            Task {
                let started = Date()
                _ = try? await engine.transcribe(silence, hints: warmHints)
                TimingLog.shared.note("engine warm-up pass: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        }

        liveTranscript = LiveTranscript()
        if settings.livePreviewEnabled {
            let hints = TranscriptionHints(language: settings.language, vocabulary: dictionary.vocabularyPrompt())
            let audio = self.audio
            var firstPartial = true
            live.onUpdate = { [weak self] transcript in
                guard let self, self.state.isRecording else { return }
                if firstPartial, !transcript.isEmpty {
                    firstPartial = false
                    TimingLog.shared.note("first live preview text")
                }
                self.liveTranscript = transcript
            }
            if let streaming = streamingEngineForPreview {
                TimingLog.shared.note("preview: streaming (Parakeet Unified \(streaming.tier.rawValue) ms)")
                live.startStreaming(engine: streaming, samples: { audio.samplesSoFar() })
            } else {
                live.start(
                    hints: hints,
                    engine: { [weak self] in
                        guard let self, self.modelState == .ready else { return nil }
                        return self.engine
                    },
                    samples: { audio.samplesSoFar() }
                )
            }
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        toggleArmed = false
        live.stop()
        TimingLog.shared.note("finish requested")

        generation += 1
        let thisGeneration = generation
        transition(to: .transcribing(generation: thisGeneration), status: nil)
        audio.stop { [weak self] capture in
            guard let self else { return }
            TimingLog.shared.note("capture collected: \(String(format: "%.2f", capture.duration)) s, peak \(String(format: "%.3f", capture.peakRMS))")
            // Esc while the mic was winding down bumps the generation.
            guard self.generation == thisGeneration, self.state.isTranscribing else { return }

            // Energy gate: never transcribed, never injected.
            let filter = HallucinationFilter()
            guard capture.peakRMS >= filter.minimumPeakRMS,
                  capture.duration >= filter.minimumDuration else {
                self.sounds.play(.cancel)
                self.transition(to: .idle, status: "Heard nothing")
                return
            }
            Task { await self.transcribeAndInject(capture, generation: thisGeneration) }
        }
    }

    private func transcribeAndInject(_ capture: AudioCaptureEngine.Capture, generation thisGeneration: Int) async {
        // Recording is legal before the model is warm; wait for readiness here
        // so cold-start hides behind speaking time.
        while modelState != .ready {
            if case .failed(let message) = modelState {
                transition(to: .idle, status: "Model failed to load: \(message)")
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard generation == thisGeneration, state.isTranscribing else { return }
        }
        guard let engine else {
            transition(to: .idle, status: "No transcription engine loaded")
            return
        }

        let hints = TranscriptionHints(
            language: settings.language,
            vocabulary: dictionary.vocabularyPrompt()
        )
        let result: EngineResult
        TimingLog.shared.note("transcribe start")
        do {
            result = try await engine.transcribe(capture.samples, hints: hints)
        } catch {
            guard generation == thisGeneration else { return }
            transition(to: .idle, status: "Transcription failed: \(error.localizedDescription)")
            return
        }
        TimingLog.shared.note("transcribe done: \(result.text.count) chars")
        guard generation == thisGeneration, state.isTranscribing else { return } // cancelled meanwhile

        let context = DictationContext(
            audioDuration: capture.duration,
            peakRMS: capture.peakRMS,
            engineID: engine.id,
            noSpeechProb: result.noSpeechProb,
            avgLogprob: result.avgLogprob
        )
        let pipeline = TranscriptPipeline(stages: [
            HallucinationFilter(),
            LLMCleanerStage(
                cleaner: cleaner,
                enabled: settings.cleanupEnabled,
                vocabulary: dictionary.vocabularyPrompt()
            ),
            DictionaryReplacer(rules: dictionary.replacementRules()),
        ])
        isCleaningUp = settings.cleanupEnabled && cleaner.isAvailable
            && LLMCleanerStage.needsCleanup(result.text)
        let text = await pipeline.run(result.text, context: context)
        isCleaningUp = false
        TimingLog.shared.note("pipeline done")

        guard !text.isEmpty else {
            sounds.play(.cancel)
            transition(to: .idle, status: "Heard nothing")
            return
        }

        transition(to: .injecting, status: nil)
        do {
            try await injector.inject(
                text,
                method: settings.injectionMethod,
                restoreClipboard: settings.restoreClipboard
            )
            sounds.play(.done)
            TimingLog.shared.note("injected")
            transition(to: .idle, status: nil)
        } catch {
            // Graceful degradation: leave it on the clipboard.
            injector.copyOnly(text)
            transition(to: .idle, status: "Copied to clipboard — press ⌘V (\(error.localizedDescription))")
        }

        if settings.historyEnabled {
            history.save(
                text: text,
                rawText: result.text,
                duration: capture.duration,
                appBundleID: targetAppBundleID,
                engineID: engine.id
            )
        }
    }

    private func transition(to newState: DictationState, status: String?) {
        state = newState
        statusMessage = status
        if newState.isIdle {
            level = 0
            liveTranscript = LiveTranscript()
            micLive = false
        }
    }
}
