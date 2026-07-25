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

    private let engine = AVAudioEngine()
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
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReconfigure()
        }
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

    /// Pre-allocates the audio graph so `start()` is fast (~100 ms instead of ~500 ms).
    public func prepare() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            _ = self.engine.inputNode // force graph creation
            self.engine.prepare()
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
                completion(NSError(domain: "OpenFlow.Audio", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Audio engine was deallocated.",
                ]))
                return
            }
            self.lock.lock()
            self.samples.removeAll(keepingCapacity: true)
            self.samples.reserveCapacity(Int(Self.targetSampleRate * 60))
            self.peakRMS = 0
            self.firstBufferSeen = false
            self.maxDurationFired = false
            self.lock.unlock()

            do {
                try self.activate()
                completion(nil)
            } catch {
                // One retry on a fully reset graph: covers a device swap the
                // listeners have not reconciled yet (e.g. it happened during
                // sleep).
                self.engine.stop()
                self.engine.reset()
                do {
                    try self.activate()
                    completion(nil)
                } catch {
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
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "OpenFlow.Audio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input device available.",
            ])
        }
        converter = AVAudioConverter(from: hwFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private func tearDown() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
            _ = engine.inputNode
            engine.prepare()
        }
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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if fireFirstBuffer { self.onFirstBuffer?() }
            self.onLevel?(rms)
            if fireMaxDuration { self.onMaxDuration?() }
        }
    }
}
