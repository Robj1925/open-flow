import Foundation

/// Whether an LLM cleanup backend can run right now.
public enum CleanerAvailability: Equatable, Sendable, CustomStringConvertible {
    case available
    /// Enabled in principle, but blocked (e.g. Apple Intelligence turned off).
    case unavailable(reason: String)
    /// This OS/hardware can't run the backend at all (e.g. pre-macOS 26).
    case notSupported

    public var isAvailable: Bool { self == .available }

    public var description: String {
        switch self {
        case .available: return "Available"
        case .unavailable(let reason): return "Unavailable: \(reason)"
        case .notSupported: return "Not supported on this Mac"
        }
    }
}

/// Backend that rewrites a raw transcript into clean prose (removes filler
/// words and false starts, fixes punctuation). The v2 seam the pipeline was
/// designed around; mirrors the `TranscriptionEngine` protocol so a different
/// LLM (a bundled MLX model, a BYOK cloud endpoint) can be dropped in later.
///
/// `clean` must NEVER throw or block a dictation: on any error, timeout, or
/// unavailability it returns the original text unchanged.
public protocol TextCleaner: AnyObject, Sendable {
    var id: String { get }
    var availability: CleanerAvailability { get }
    /// Warms the model so the first real cleanup isn't slow. Safe to call when
    /// unavailable (no-op).
    func prewarm()
    func clean(_ text: String, vocabulary: String?) async -> String
}

public extension TextCleaner {
    var isAvailable: Bool { availability.isAvailable }
}
