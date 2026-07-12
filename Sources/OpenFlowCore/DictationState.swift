import Foundation

/// The dictation session lifecycle. `DictationController` is the only owner of transitions.
public enum DictationState: Equatable {
    case idle
    case recording(mode: ActivationMode, startedAt: Date)
    case transcribing(generation: Int)
    case injecting

    public var isIdle: Bool { if case .idle = self { return true }; return false }
    public var isRecording: Bool { if case .recording = self { return true }; return false }
    public var isTranscribing: Bool { if case .transcribing = self { return true }; return false }
}

/// How a recording session was started / how it ends.
public enum ActivationMode: String, Codable, CaseIterable, Sendable {
    /// Press-and-hold: release stops.
    case hold
    /// Tap to start, tap again to stop.
    case toggle
    /// Decide per-press: a quick tap (< threshold) arms toggle mode, a long press behaves as hold.
    case auto
}

/// Events fed into the state machine.
public enum DictationEvent: Equatable {
    case hotkeyDown
    case hotkeyUp(pressDuration: TimeInterval)
    case escPressed
    case maxDurationReached
    case audioUnavailable
    case transcriptionCompleted(generation: Int)
    case transcriptionFailed
    case injectionFinished
}
