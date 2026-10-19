import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 samples.
///
/// Capture starts on `start()`; the honest "mic is live" signal is
/// `onFirstBuffer`, which fires when the first real audio buffer arrives — play
/// the ready tone there, never at hotkey-down (avoids the first-word-loss bug).
///
/// The default input device can change at any time (AirPods connect, a USB mic
/// is unplugged). `inputNode` follows the system default, so a switch stops the
/// engine and invalidates the tap format. Two listeners funnel into one rebuild
/// path: mid-recording the tap is reinstalled with the fresh hardware format and
/// the accumulated 16 kHz samples survive; while idle the graph is re-prepared
/// so the next `start()` never sees a stale sample rate.
///
/// Threading: every AVAudioEngine call is confined to a private serial queue.
/// Bringing up an input device can block for seconds (Bluetooth mics
/// renegotiate on connect), and blocking the main thread also starves the
/// CGEventTap watching the dictation hotkey — macOS disables unresponsive
/// taps, which is how a device switch used to take the fn key down with it.
/// All public callbacks fire on the main queue.
public final class AudioCaptureEngine {
    public struct Capture {
        public let samples: [Float]
        public let duration: TimeInterval
        /// Peak per-buffer RMS observed during the session (0...~1).
        public let peakRMS: Float

        public init(samples: [Float], duration: TimeInterval, peakRMS: Float) {
            self.samples = samples
            self.duration = duration
            self.peakRMS = peakRMS
        }
    }

    public static let targetSampleRate: Double = 16_000
    public static let errorDomain = "OpenFlow.Audio"

    /// Why `start()` failed; recoverable from the error with `failure(of:)`.
    public enum StartFailure: Int {
        /// Input reports 0 Hz / 0 channels and no default input device exists.
        case noInputDevice = 1
        case engineDeallocated = 2
        case unsupportedFormat = 3
        /// macOS had not asked for microphone access yet; the prompt is up.
        case permissionPending = 4
        /// Microphone access is off for this app in System Settings.
        case permissionDenied = 5
        /// The grant looks enabled, but macOS is not honouring it for this
        /// binary (typical after an ad-hoc rebuild changed the signature).
        case grantStale = 6
    }

    public static func failure(of error: Error) -> StartFailure? {
        let nsError = error as NSError
        guard nsError.domain == errorDomain else { return nil }
        return StartFailure(rawValue: nsError.code)
    }

    public static func makeError(_ failure: StartFailure, _ message: String) -> Error {
        NSError(domain: errorDomain, code: failure.rawValue, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
    /// Hard cap on a single dictation.
    public var maxDuration: TimeInterval = 300

    /// Fired once per session on the main queue when audio is actually flowing.
    public var onFirstBuffer: (() -> Void)?
    /// Per-buffer RMS level on the main queue, for the HUD waveform.
    public var onLevel: ((Float) -> Void)?
    /// Fired on the main queue when `maxDuration` is hit; owner should stop.
    public var onMaxDuration: (() -> Void)?
    /// Fired on the main queue when the input device disappeared mid-session and
    /// capture could not resume; owner should finish with what was recorded.
    public var onInputDeviceLost: (() -> Void)?
    /// Fired on the main queue when `start()` could not bring the mic up.
    public var onStartFailed: ((Error) -> Void)?

    /// Replaced wholesale by `rebuildEngine()` when a start fails; see there.
    /// sessionQueue-confined after init.
    private var engine = AVAudioEngine()
    /// Confines all engine/CoreAudio work; see the threading note above.
    private let sessionQueue = DispatchQueue(label: "dev.openflow.audio-session")
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakRMS: Float = 0
    private var firstBufferSeen = false
    private var maxDurationFired = false
    private var converter: AVAudioConverter?
    /// sessionQueue-confined.
    private var isRunning = false

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureEngine.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private var pendingReconfigure: DispatchWorkItem?
    private var configChangeObserver: NSObjectProtocol?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    public init() {
        // The engine posts this (and stops itself) when its I/O configuration
        // changes, e.g. the active input device is unplugged or renegotiated.
        observeEngine()
        // The engine notification alone is not enough: a default-device switch
        // while the engine sits idle can leave the prepared graph stale without
        // any notification, so listen to CoreAudio directly as well.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReconfigure()
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            block
        )
    }

    deinit {
        if let block = deviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                block
            )
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Subscribes to the current engine's configuration-change notification.
    private func observeEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReconfigure()
        }
    }

    /// Replaces the AVAudioEngine with a fresh instance. `reset()` keeps the
    /// same input node, and that node keeps the hardware format it was created
    /// with: 0 Hz / 0 channels if it was first touched before the microphone
    /// permission existed (the HAL hides input streams from unauthorized
    /// processes). Only a new engine re-queries the hardware. sessionQueue.
    private func rebuildEngine() {
        try? ObjCExceptionGuard.run {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = AVAudioEngine()
        converter = nil
        observeEngine()
    }

    /// Pre-allocates the audio graph so `start()` is fast (~100 ms instead of ~500 ms).
    public func prepare() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Touching inputNode before the microphone permission exists bakes
            // a 0-channel format into the node for the engine's lifetime, so
            // leave the graph alone until then; start() builds it on demand.
            guard Self.microphoneAuthorized else {
                TimingLog.shared.note("audio: prepare skipped, mic not authorized")
                return
            }
            // prepare() raises an NSException when the input device has no
            // usable format (nothing plugged in); swallow it and let start()
            // report the problem through onStartFailed instead.
            try? ObjCExceptionGuard.run {
                _ = self.engine.inputNode // force graph creation
                self.engine.prepare()
            }
            TimingLog.shared.note("audio: graph prepared")
        }
    }

    /// Begins capture. Returns immediately; failure to bring the mic up is
    /// reported via `onStartFailed` so the caller's thread never blocks on
    /// device negotiation.
    public func start() {
        startInternal { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onStartFailed?(error) }
        }
    }

    /// Async variant for CLI/tools: returns once the mic is live, throws if it
    /// could not start.
    public func startAndWait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            startInternal { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// `completion` is invoked exactly once, on the session queue.
    private func startInternal(_ completion: @escaping (Error?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                completion(Self.makeError(.engineDeallocated, "Audio engine was deallocated."))
                return
            }
            self.lock.lock()
            self.samples.removeAll(keepingCapacity: true)
            self.samples.reserveCapacity(Int(Self.targetSampleRate * 60))
            self.peakRMS = 0
            self.firstBufferSeen = false
            self.maxDurationFired = false
            self.lock.unlock()
            TimingLog.shared.note("audio: start running on session queue")

            if let denied = Self.microphoneAccessError() {
                completion(denied)
                return
            }
            let started = Date()
            do {
                try self.activate()
                TimingLog.shared.note("audio: engine started in \(Self.ms(since: started))")
                completion(nil)
            } catch {
                TimingLog.shared.note("audio: first attempt failed in \(Self.ms(since: started)): \(error.localizedDescription)")
                // One retry on a brand-new engine: covers a device swap the
                // listeners have not reconciled yet (e.g. it happened during
                // sleep) and an input node created before the microphone
                // permission was granted.
                self.rebuildEngine()
                let retried = Date()
                do {
                    try self.activate()
                    TimingLog.shared.note("audio: engine started on retry in \(Self.ms(since: retried))")
                    completion(nil)
                } catch {
                    TimingLog.shared.note("audio: retry failed in \(Self.ms(since: retried)): \(error.localizedDescription)")
                    completion(error)
                }
            }
        }
    }

    /// Stops capture and delivers everything recorded this session on the main
    /// queue.
    public func stop(_ completion: @escaping (Capture) -> Void) {
        sessionQueue.async { [weak self] in
            let capture = self?.tearDownAndCollect()
                ?? Capture(samples: [], duration: 0, peakRMS: 0)
            DispatchQueue.main.async { completion(capture) }
        }
    }

    /// Async variant for CLI/tools.
    public func stopAndWait() async -> Capture {
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                cont.resume(returning: self?.tearDownAndCollect()
                    ?? Capture(samples: [], duration: 0, peakRMS: 0))
            }
        }
    }

    /// Copy of everything captured so far (16 kHz mono). Safe to call from
    /// any thread while recording; used for live partial transcription.
    public func samplesSoFar() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Stops capture and discards the audio.
    public func cancel() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.tearDown()
            self.lock.lock()
            self.samples.removeAll()
            self.lock.unlock()
        }
    }

    // MARK: - sessionQueue internals

    /// Installs the tap against the current hardware format and starts the
    /// engine. Session state (accumulated samples) is untouched, so this is
    /// safe both for a fresh start and for a mid-recording device rebuild.
    private func activate() throws {
        var input = engine.inputNode
        var hwFormat = input.outputFormat(forBus: 0)

        // The node's output format is cached from the last prepare(). If the
        // default input changed since (built-in mic at 48 kHz → Bluetooth
        // headset at 8 kHz, say) it is stale, and installing a tap with it
        // raises "Failed to create tap due to format mismatch". Compare with
        // the live hardware format and rebuild the graph when they differ.
        let liveFormat = input.inputFormat(forBus: 0)
        if !Self.sameShape(hwFormat, liveFormat) {
            TimingLog.shared.note("audio: stale node format \(Int(hwFormat.sampleRate)) Hz/\(hwFormat.channelCount) ch vs live \(Int(liveFormat.sampleRate)) Hz/\(liveFormat.channelCount) ch → reset")
            engine.stop()
            engine.reset()
            input = engine.inputNode
            hwFormat = input.outputFormat(forBus: 0)
        }
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw Self.noUsableInputError()
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: outputFormat) else {
            throw Self.makeError(.unsupportedFormat, "Unsupported input format \(Int(hwFormat.sampleRate)) Hz, \(hwFormat.channelCount) ch.")
        }
        self.converter = converter

        // AVFoundation raises NSException (uncatchable from Swift) for format
        // problems inside installTap/prepare; the guard converts that into a
        // thrown error so start() can retry on a reset graph, then report.
        var startError: Error?
        try ObjCExceptionGuard.run {
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let startError {
            input.removeTap(onBus: 0)
            throw startError
        }
        isRunning = true
    }

    private static func sameShape(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    private static func ms(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000)) ms"
    }

    private func tearDown() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        TimingLog.shared.note("audio: stopped")
    }

    private func tearDownAndCollect() -> Capture {
        tearDown()
        lock.lock()
        let out = samples
        let peak = peakRMS
        lock.unlock()
        return Capture(
            samples: out,
            duration: Double(out.count) / Self.targetSampleRate,
            peakRMS: peak
        )
    }

    /// Coalesces the burst of notifications a single device switch produces
    /// (CoreAudio + engine notification, sometimes several of each). Main queue.
    private func scheduleReconfigure() {
        pendingReconfigure?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionQueue.async { self.reconfigure() }
        }
        pendingReconfigure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Rebuilds the audio graph for the current default input device.
    private func reconfigure() {
        TimingLog.shared.note("audio: device/config change → reconfigure (recording=\(isRunning))")
        if isRunning {
            // Mid-recording: reinstall the tap with the new device's format and
            // keep going. `samples` is already 16 kHz mono, so the transition is
            // seamless apart from the switch itself.
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            do {
                try activate()
            } catch {
                isRunning = false
                DispatchQueue.main.async { [weak self] in self?.onInputDeviceLost?() }
            }
        } else {
            // Idle: refresh the prepared graph so the next start() sees the new
            // device's real sample rate instead of a stale one.
            engine.stop()
            engine.reset()
            guard Self.microphoneAuthorized else { return }
            try? ObjCExceptionGuard.run {
                _ = engine.inputNode
                engine.prepare()
            }
        }
    }

    // MARK: - Microphone access

    private static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Nil when capture may proceed. Otherwise an error whose description
    /// tells the user what to do; the HUD shows it verbatim.
    private static func microphoneAccessError() -> Error? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return nil
        case .notDetermined:
            // Shows the system prompt; the user answers it and presses the
            // hotkey again.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return makeError(.permissionPending, "macOS is asking for microphone access. Click Allow, then try again.")
        case .denied, .restricted:
            return makeError(.permissionDenied, "Microphone access is off for OpenFlow. Turn it on in System Settings > Privacy & Security > Microphone.")
        @unknown default:
            return nil
        }
    }

    /// The input node reported 0 Hz / 0 channels. Either nothing is connected,
    /// or (the common case after an ad-hoc rebuild) the Microphone grant in
    /// System Settings no longer matches this binary although it looks enabled.
    private static func noUsableInputError() -> Error {
        if systemHasDefaultInput() {
            return makeError(.grantStale, "macOS is not giving OpenFlow microphone access. Allow it when asked, then try again.")
        }
        return makeError(.noInputDevice, "No microphone is available. Connect an input device, or check System Settings > Privacy & Security > Microphone.")
    }

    private static func systemHasDefaultInput() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }

        let frames = Int(converted.frameLength)
        var sumSquares: Float = 0
        for i in 0..<frames { sumSquares += channel[i] * channel[i] }
        let rms = (sumSquares / Float(frames)).squareRoot()

        var fireFirstBuffer = false
        var fireMaxDuration = false
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
        peakRMS = max(peakRMS, rms)
        if !firstBufferSeen {
            firstBufferSeen = true
            fireFirstBuffer = true
        }
        if !maxDurationFired, Double(samples.count) / Self.targetSampleRate >= maxDuration {
            maxDurationFired = true
            fireMaxDuration = true
        }
        lock.unlock()
        if fireFirstBuffer {
            TimingLog.shared.note("audio: first buffer from device (\(Int(buffer.format.sampleRate)) Hz)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if fireFirstBuffer { self.onFirstBuffer?() }
            self.onLevel?(rms)
            if fireMaxDuration { self.onMaxDuration?() }
        }
    }
}
