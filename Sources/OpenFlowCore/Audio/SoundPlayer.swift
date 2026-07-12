import AppKit

/// Short audio cues around the dictation lifecycle. Uses system sounds so no
/// bundled assets are required; instances are preloaded to keep the ready cue
/// snappy.
public final class SoundPlayer {
    public enum Cue {
        case ready   // mic is live — safe to start talking
        case done    // text injected
        case cancel  // session discarded / nothing heard
    }

    public var isEnabled = true

    private let ready = NSSound(named: "Tink")
    private let done = NSSound(named: "Pop")
    private let cancel = NSSound(named: "Bottle")

    public init() {
        for sound in [ready, done, cancel] { sound?.volume = 0.4 }
    }

    public func play(_ cue: Cue) {
        guard isEnabled else { return }
        let sound: NSSound?
        switch cue {
        case .ready: sound = ready
        case .done: sound = done
        case .cancel: sound = cancel
        }
        sound?.stop()
        sound?.play()
    }
}
