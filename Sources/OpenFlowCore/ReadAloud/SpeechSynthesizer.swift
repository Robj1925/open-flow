import FluidAudio
import Foundation

/// Rendered speech: mono Float32 PCM at `sampleRate`.
public struct SpeechClip: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }
}

/// A text-to-speech backend. One implementation today (Kokoro 82M on the
/// Neural Engine via FluidAudio); the protocol keeps the controller and CLI
/// independent of it.
public protocol SpeechSynthesizer: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var isReady: Bool { get async }
    /// Downloads the voice model if needed and loads it. Safe to call twice.
    func prepare() async throws
    /// Renders one chunk of text. `speed` is a rate multiplier (1.0 = normal).
    func synthesize(_ text: String, speed: Float) async throws -> SpeechClip
    func unload() async
}

/// Kokoro 82M, English (`af_heart`), ANE-resident 7-stage CoreML chain.
/// Apache 2.0 weights. About 330 MB on disk; a sentence renders in roughly
/// a quarter of a second on Apple Silicon.
public final class KokoroSpeechSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    public let id = "kokoro"
    public let displayName = "Kokoro (English)"

    private var manager: KokoroAneManager?

    public init() {}

    public var isReady: Bool {
        get async {
            guard let manager else { return false }
            return await manager.isAvailable()
        }
    }

    public func prepare() async throws {
        if let manager, await manager.isAvailable() { return }
        let fresh = KokoroAneManager(variant: .english)
        try await fresh.initialize()
        // The first prediction pays for ANE graph compilation (seconds); take
        // that hit now so the first sentence the user asks for is instant.
        _ = try await fresh.synthesizeDetailed(text: "Ready.", voice: nil, speed: 1.0)
        manager = fresh
    }

    public func synthesize(_ text: String, speed: Float) async throws -> SpeechClip {
        guard let manager else {
            throw NSError(domain: "OpenFlow.ReadAloud", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The Kokoro voice is not loaded yet.",
            ])
        }
        let clamped = min(max(speed, 0.5), 2.0)
        let result = try await manager.synthesizeDetailed(text: text, voice: nil, speed: clamped)
        return SpeechClip(
            samples: Self.normalized(result.samples),
            sampleRate: Double(result.sampleRate)
        )
    }

    public func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// Kokoro's raw samples sit at the model's native level; FluidAudio only
    /// peak-normalizes on its WAV path. Bring peaks to a consistent level so
    /// chunks play at the same loudness, with a gain cap so near-silent
    /// output (a lone number, say) is not amplified into noise.
    static func normalized(_ samples: [Float], target: Float = 0.85, maxGain: Float = 3) -> [Float] {
        guard let peak = samples.lazy.map({ abs($0) }).max(), peak > 0 else { return samples }
        let gain = min(target / peak, maxGain)
        guard abs(gain - 1) > 0.01 else { return samples }
        return samples.map { $0 * gain }
    }

    // MARK: - On-disk model

    /// Where FluidAudio caches the Kokoro ANE chain (`~/.cache/fluidaudio/Models/…`).
    public static var modelsDirectory: URL? {
        guard let root = try? TtsCacheDirectory.ensure() else { return nil }
        return root
            .appendingPathComponent(KokoroAneResourceDownloader.modelsSubdirectory, isDirectory: true)
            .appendingPathComponent(Repo.kokoroAne.folderName, isDirectory: true)
    }

    public static var isDownloaded: Bool {
        guard let directory = modelsDirectory else { return false }
        return ModelNames.KokoroAne.requiredModels.allSatisfy { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    public static var approxSize: String { "~330 MB" }

    public static func deleteDownload() throws {
        guard let directory = modelsDirectory else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public static var diskUsage: Int64 {
        guard let directory = modelsDirectory,
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
