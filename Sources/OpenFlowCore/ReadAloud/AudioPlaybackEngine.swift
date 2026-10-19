import AVFoundation
import Foundation

/// Gapless queue player for synthesized speech. Clips are scheduled on an
/// `AVAudioPlayerNode` as they arrive, so synthesis of chunk N+1 overlaps
/// playback of chunk N. The engine releases the output device when the
/// queue drains or playback is stopped.
public actor AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedSampleRate: Double = 0
    private var pendingBuffers = 0
    /// Bumped on stop() so late completion callbacks from a cancelled queue
    /// cannot decrement the next session's count.
    private var generation = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {
        engine.attach(player)
    }

    /// Schedules a clip for playback right after whatever is already queued.
    public func enqueue(_ clip: SpeechClip) throws {
        guard !clip.samples.isEmpty else { return }
        try ensureRunning(sampleRate: clip.sampleRate)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
           let channel = buffer.floatChannelData?[0]
        else {
            throw NSError(domain: "OpenFlow.ReadAloud", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate an audio buffer.",
            ])
        }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: clip.samples.count)
        }

        pendingBuffers += 1
        let thisGeneration = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            Task { await self.bufferPlayed(generation: thisGeneration) }
        }
        if !player.isPlaying { player.play() }
    }

    /// Resumes once every queued clip has been heard (or playback was stopped).
    public func waitUntilDrained() async {
        guard pendingBuffers > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    /// Cuts playback immediately and discards the queue.
    public func stop() {
        generation += 1
        pendingBuffers = 0
        player.stop()
        engine.stop()
        resumeDrainWaiters()
    }

    public var isPlaying: Bool { pendingBuffers > 0 }

    // MARK: - Private

    private func bufferPlayed(generation playedGeneration: Int) {
        guard playedGeneration == generation, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        if pendingBuffers == 0 {
            // Queue drained naturally: let go of the audio device.
            player.stop()
            engine.stop()
            resumeDrainWaiters()
        }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func ensureRunning(sampleRate: Double) throws {
        if connectedSampleRate != sampleRate {
            player.stop()
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            )
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedSampleRate = sampleRate
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }
}
