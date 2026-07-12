import CoreGraphics
import Foundation

/// The dictation hotkeys OpenFlow supports natively through its event tap.
/// fn is the Wispr Flow default; the others are common "spare" keys that
/// don't collide with typing.
public enum DictationHotkey: String, Codable, CaseIterable, Sendable {
    case fn
    case rightCommand
    case rightOption
    case f19

    public var displayName: String {
        switch self {
        case .fn: return "fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f19: return "F19"
        }
    }

    /// Virtual key code carried in the CGEvent.
    var keyCode: Int64 {
        switch self {
        case .fn: return 63           // kVK_Function
        case .rightCommand: return 54 // kVK_RightCommand
        case .rightOption: return 61  // kVK_RightOption
        case .f19: return 80          // kVK_F19
        }
    }

    /// Whether the key arrives as a `.flagsChanged` (modifier) event.
    var isModifier: Bool {
        switch self {
        case .fn, .rightCommand, .rightOption: return true
        case .f19: return false
        }
    }

    var modifierFlag: CGEventFlags? {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .f19: return nil
        }
    }
}

/// Turns raw tap events into semantic hotkey-down / hotkey-up / esc signals.
public final class HotkeyManager {
    public var hotkey: DictationHotkey = .fn

    /// Called on hotkey press (main thread — the tap runs on the main run loop).
    public var onHotkeyDown: (() -> Void)?
    /// Called on hotkey release with the held duration.
    public var onHotkeyUp: ((TimeInterval) -> Void)?
    /// Esc pressed. Return true to swallow the keystroke (only honored when the
    /// tap is swallow-capable); return false to let it through to the app.
    public var onEsc: (() -> Bool)?

    private let tap = EventTap()
    private var pressedAt: Date?

    public init() {
        tap.handler = { [weak self] event, type in
            self?.handle(event, type: type) ?? false
        }
    }

    /// Starts listening. Returns false when the tap can't be created
    /// (permissions missing).
    @discardableResult
    public func start() -> Bool {
        tap.start(swallowCapable: true)
    }

    public func stop() {
        tap.stop()
    }

    public var isRunning: Bool { tap.isRunning }
    public var canSwallowEvents: Bool { !tap.isListenOnly }

    private func handle(_ event: CGEvent, type: CGEventType) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged where hotkey.isModifier && keyCode == hotkey.keyCode:
            guard let flag = hotkey.modifierFlag else { return false }
            let isDown = event.flags.contains(flag)
            if isDown, pressedAt == nil {
                pressedAt = Date()
                onHotkeyDown?()
            } else if !isDown, let started = pressedAt {
                pressedAt = nil
                onHotkeyUp?(Date().timeIntervalSince(started))
            }
            // Never swallow flagsChanged: other apps need consistent modifier state.
            return false

        case .keyDown where !hotkey.isModifier && keyCode == hotkey.keyCode:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat, pressedAt == nil {
                pressedAt = Date()
                onHotkeyDown?()
            }
            return true // swallow the dedicated dictation key

        case .keyUp where !hotkey.isModifier && keyCode == hotkey.keyCode:
            if let started = pressedAt {
                pressedAt = nil
                onHotkeyUp?(Date().timeIntervalSince(started))
            }
            return true

        case .keyDown where keyCode == 53: // kVK_Escape
            return onEsc?() ?? false

        default:
            return false
        }
    }
}
