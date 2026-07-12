import AVFoundation
import Foundation

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 samples.
///
/// Capture starts synchronously on `start()`; the honest "mic is live" signal is
/// `onFirstBuffer`, which fires when the first real audio buffer arrives — play
/// the ready tone there, never at hotkey-down (avoids the first-word-loss bug).
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

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peakRMS: Float = 0
    private var firstBufferSeen = false
    private var maxDurationFired = false
    private var converter: AVAudioConverter?
    private var isRunning = false

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureEngine.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    /// Pre-allocates the audio graph so `start()` is fast (~100 ms instead of ~500 ms).
    public func prepare() {
        _ = engine.inputNode // force graph creation
        engine.prepare()
    }

    public func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.targetSampleRate * 60))
        peakRMS = 0
        firstBufferSeen = false
        maxDurationFired = false
        lock.unlock()

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

    /// Stops capture and returns everything recorded this session.
    public func stop() -> Capture {
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

    /// Stops capture and discards the audio.
    public func cancel() {
        tearDown()
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    private func tearDown() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
