import AppKit
import Foundation

/// Orchestrates the whole dictation lifecycle:
/// hotkey → capture → transcribe → post-process → inject → history.
/// The single owner of `DictationState` transitions.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var modelState: ModelState = .unloaded
    @Published public private(set) var statusMessage: String?
    /// Live mic level for the HUD waveform (0...~1).
    @Published public private(set) var level: Float = 0
    /// True while the LLM cleanup stage is running (HUD shows "Cleaning up…").
    @Published public private(set) var isCleaningUp = false

    public let audio = AudioCaptureEngine()
    public let sounds = SoundPlayer()
    public let injector = TextInjector()
    public let hotkeys = HotkeyManager()
    public let cleaner: any TextCleaner = AppleFoundationCleaner()

    /// Availability of the LLM cleanup backend, for Settings to display.
    public var cleanupAvailability: CleanerAvailability { cleaner.availability }

    private let settings: AppSettings
    public let history: HistoryStore
    public let dictionary: DictionaryStore

    private var engine: TranscriptionEngine?
    /// Preset id the current `engine` was built from.
    private var loadedPresetID: String?
    /// Bumped to invalidate in-flight transcriptions (Esc during transcribe).
    private var generation = 0
    /// Auto mode: a quick tap armed toggle; the next press stops.
    private var toggleArmed = false
    /// Frontmost app at hotkey-down, for history attribution.
    private var targetAppBundleID: String?

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
        hotkeys.start()
        if settings.cleanupEnabled { cleaner.prewarm() }
        Task { await loadSelectedEngine() }
    }

    /// Re-reads settings that affect live components (hotkey, model).
    public func settingsChanged() {
        hotkeys.hotkey = settings.hotkey
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

    // MARK: - Hotkey handling

    private func wireCallbacks() {
        hotkeys.onHotkeyDown = { [weak self] in self?.hotkeyDown() }
        hotkeys.onHotkeyUp = { [weak self] duration in self?.hotkeyUp(afterPress: duration) }
        hotkeys.onEsc = { [weak self] in self?.escPressed() ?? false }

        audio.onFirstBuffer = { [weak self] in self?.sounds.play(.ready) }
        audio.onLevel = { [weak self] rms in self?.level = rms }
        audio.onMaxDuration = { [weak self] in self?.finishRecording() }
    }

    private func hotkeyDown() {
        switch state {
        case .idle:
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
            audio.cancel()
            toggleArmed = false
            sounds.play(.cancel)
            transition(to: .idle, status: "Cancelled")
            return true
        case .transcribing:
            generation += 1 // stale-drop any in-flight result
            transition(to: .idle, status: "Cancelled")
            return true
        case .idle, .injecting:
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
        do {
            try audio.start()
            transition(to: .recording(mode: settings.activationMode, startedAt: Date()), status: nil)
        } catch {
            transition(to: .idle, status: "Microphone unavailable: \(error.localizedDescription)")
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        toggleArmed = false
        let capture = audio.stop()

        // Energy gate: never transcribed, never injected.
        let filter = HallucinationFilter()
        guard capture.peakRMS >= filter.minimumPeakRMS,
              capture.duration >= filter.minimumDuration else {
            sounds.play(.cancel)
            transition(to: .idle, status: "Heard nothing")
            return
        }

        generation += 1
        let thisGeneration = generation
        transition(to: .transcribing(generation: thisGeneration), status: nil)
        Task { await transcribeAndInject(capture, generation: thisGeneration) }
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
        do {
            result = try await engine.transcribe(capture.samples, hints: hints)
        } catch {
            guard generation == thisGeneration else { return }
            transition(to: .idle, status: "Transcription failed: \(error.localizedDescription)")
            return
        }
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
        isCleaningUp = settings.cleanupEnabled && cleaner.isAvailable && !result.text.isEmpty
        let text = await pipeline.run(result.text, context: context)
        isCleaningUp = false

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
        if newState.isIdle { level = 0 }
    }
}
