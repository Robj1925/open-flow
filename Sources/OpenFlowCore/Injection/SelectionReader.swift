import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Reads the text selected in the frontmost app by synthesizing ⌘C, the
/// mirror image of `TextInjector`'s ⌘V path. The user's clipboard is
/// snapshotted first and restored afterwards, so nothing is lost.
@MainActor
public enum SelectionReader {
    /// Returns the selected text, or "" when the app put nothing on the
    /// clipboard (no selection, or a field that refuses to copy).
    public static func copySelectedText(timeout: TimeInterval = 0.6) async throws -> String {
        guard AXIsProcessTrusted() else { throw InjectionError.accessibilityNotGranted }
        guard !IsSecureEventInputEnabled() else { throw InjectionError.secureInputActive }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        let before = pasteboard.changeCount

        postCommandC()

        // Copy lands asynchronously in the target app; poll briefly.
        let deadline = Date().addingTimeInterval(timeout)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let text = pasteboard.changeCount == before ? "" : (pasteboard.string(forType: .string) ?? "")
        snapshot.restore(to: pasteboard)
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
