import CoreGraphics
import Foundation

/// Types text as synthetic unicode keystrokes — the fallback for apps that
/// mishandle programmatic paste. Slower than paste but touches nothing.
public enum KeystrokeTyper {
    /// CGEvent's unicode payload is capped at 20 UTF-16 units per event.
    private static let chunkSize = 20

    public static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.post(tap: .cghidEventTap)
            }
            index = end
            // Small pacing delay so slow apps don't drop events.
            usleep(5_000)
        }
    }
}
