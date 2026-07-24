import Foundation

/// One selectable model in Settings.
public struct ModelPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let engine: EngineKind
    public let displayName: String
    public let detail: String
    /// Variant folder name in argmaxinc/whisperkit-coreml (Whisper presets only).
    public let whisperVariant: String?
    /// Approximate download size, for display.
    public let approxSize: String
}

/// Unified catalog of the shippable models plus download/lifecycle helpers.
/// Parakeet weights are managed by FluidAudio in its own cache; Whisper weights
/// live under Application Support/OpenFlow/Models.
public enum ModelCatalog {
    public static let parakeetV3 = ModelPreset(
        id: "parakeet-tdt-v3",
        engine: .parakeet,
        displayName: "Parakeet TDT v3",
        detail: "Fastest engine. English plus 24 European languages.",
        whisperVariant: nil,
        approxSize: "~600 MB"
    )
    public static let whisperLargeTurbo = ModelPreset(
        id: "whisper-large-v3-turbo",
        engine: .whisper,
        displayName: "Whisper Large v3 Turbo",
        detail: "Broadest coverage (~100 languages), quantized. Use for languages Parakeet does not cover.",
        whisperVariant: "openai_whisper-large-v3-v20240930_626MB",
        approxSize: "~626 MB"
    )

    public static let all: [ModelPreset] = [parakeetV3, whisperLargeTurbo]

    public static func preset(id: String) -> ModelPreset? {
        all.first { $0.id == id }
    }

    /// ISO 639-1 codes Parakeet TDT v3 transcribes: English plus 24 European
    /// languages. Anything outside this set needs the Whisper engine.
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
        "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]
}

public final class ModelManager {
    public static let shared = ModelManager()

    /// Root for OpenFlow-managed (Whisper) model weights.
    public let whisperDownloadBase: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        whisperDownloadBase = appSupport.appendingPathComponent("OpenFlow/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: whisperDownloadBase, withIntermediateDirectories: true)
    }

    /// Builds a fresh (unloaded) engine for a preset. Caller drives `prepare()`.
    public func makeEngine(for preset: ModelPreset) -> TranscriptionEngine {
        switch preset.engine {
        case .parakeet:
            return FluidAudioEngine()
        case .whisper:
            return WhisperKitEngine(
                modelVariant: preset.whisperVariant ?? "openai_whisper-large-v3-v20240930_626MB",
                downloadBase: whisperDownloadBase
            )
        }
    }

    public func isDownloaded(_ preset: ModelPreset) -> Bool {
        switch preset.engine {
        case .parakeet:
            return FluidAudioEngine.isDownloaded
        case .whisper:
            guard let variant = preset.whisperVariant else { return false }
            return FileManager.default.fileExists(atPath: whisperModelFolder(variant: variant).path)
        }
    }

    public func delete(_ preset: ModelPreset) throws {
        switch preset.engine {
        case .parakeet:
            try FileManager.default.removeItem(at: FluidAudioEngine.modelsDirectory)
        case .whisper:
            guard let variant = preset.whisperVariant else { return }
            try FileManager.default.removeItem(at: whisperModelFolder(variant: variant))
        }
    }

    public func diskUsage(_ preset: ModelPreset) -> Int64 {
        let url: URL
        switch preset.engine {
        case .parakeet: url = FluidAudioEngine.modelsDirectory
        case .whisper:
            guard let variant = preset.whisperVariant else { return 0 }
            url = whisperModelFolder(variant: variant)
        }
        return Self.directorySize(url)
    }

    private func whisperModelFolder(variant: String) -> URL {
        // Mirrors WhisperKit's HubApi layout under downloadBase.
        whisperDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
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
