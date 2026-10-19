import AVFoundation
import FluidAudio
import Foundation

/// Live-preview recognizer backed by Parakeet Unified 0.6B in true streaming
/// mode (FluidAudio's `StreamingUnifiedAsrManager`). Audio is fed as it is
/// captured; the encoder re-runs over a short chunked-attention window and the
/// RNNT decoder emits tokens that are final the moment they appear, so the
/// preview grows word by word about a third of a second behind the speaker
/// and never rewrites itself. English only. The dictation itself is still
/// transcribed by the selected batch model after key release.
public actor StreamingPreviewEngine {
    /// Latency tiers are distinct encoder bundles (the attention window is
    /// baked in at conversion), so switching tiers means another download.
    public enum Tier: String, CaseIterable, Sendable {
        case ms320 = "320"
        case ms640 = "640"
        case ms1120 = "1120"

        var variant: StreamingModelVariant {
            switch self {
            case .ms320: return .parakeetUnified320ms
            case .ms640: return .parakeetUnified640ms
            case .ms1120: return .parakeetUnified1120ms
            }
        }

        var config: UnifiedConfig {
            variant.unifiedConfig ?? UnifiedConfig()
        }

        public var displayName: String {
            switch self {
            case .ms320: return "0.32 s (lowest latency)"
            case .ms640: return "0.64 s (lighter on the Neural Engine)"
            case .ms1120: return "1.12 s (best accuracy)"
            }
        }

        public var latency: TimeInterval { Double(config.latencyMs) / 1000 }
    }

    public static let approxSize = "~610 MB"

    /// FluidAudio's cache for this repo; all tiers share the decoder/joint files.
    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    public static func isDownloaded(_ tier: Tier) -> Bool {
        let names = ModelNames.ParakeetUnified.self
        let required = [
            names.streamingEncoderFile(precision: .int8, contextSuffix: tier.config.contextSuffix),
            names.decoderFile, names.jointDecisionFile, names.vocab,
        ]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent($0).path)
        }
    }

    public static var isAnyTierDownloaded: Bool { Tier.allCases.contains(where: isDownloaded) }

    public static var diskUsage: Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Removes every downloaded tier.
    public static func deleteDownload() throws {
        try FileManager.default.removeItem(at: modelsDirectory)
    }

    public let tier: Tier
    private let manager: StreamingUnifiedAsrManager
    private var isLoaded = false

    public init(tier: Tier) {
        self.tier = tier
        manager = StreamingUnifiedAsrManager(config: tier.config)
    }

    /// Downloads the tier if needed, loads it, and runs one silent window so
    /// the first real chunk does not pay the Neural Engine warm-up.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isLoaded else { return }
        try await manager.loadModels(to: nil, configuration: nil) { update in
            progress(update.fractionCompleted)
        }
        isLoaded = true
        try await manager.reset()
        let silence = [Float](repeating: 0, count: Int(AudioCaptureEngine.targetSampleRate))
        try await manager.appendAudio(Self.buffer(from: silence))
        try await manager.processBufferedAudio()
        try await manager.reset()
    }

    /// Starts a fresh transcript for a new dictation.
    public func beginSession() async throws {
        guard isLoaded else { throw Self.notLoaded }
        try await manager.reset()
    }

    /// Feeds newly captured 16 kHz mono samples and returns the transcript so
    /// far. Decoding happens whenever a full chunk has accumulated.
    public func feed(_ samples: [Float]) async throws -> String {
        guard isLoaded else { throw Self.notLoaded }
        if !samples.isEmpty {
            try await manager.appendAudio(Self.buffer(from: samples))
        }
        try await manager.processBufferedAudio()
        return await manager.getPartialTranscript()
    }

    /// Flushes the held-back right context and returns the final streamed text.
    public func finish() async throws -> String {
        guard isLoaded else { throw Self.notLoaded }
        return try await manager.finish()
    }

    public func unload() async {
        await manager.cleanup()
        isLoaded = false
    }

    private static let notLoaded = NSError(domain: "OpenFlow.Engine", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Streaming preview model is not loaded yet.",
    ])

    private static func buffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureEngine.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0], !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
