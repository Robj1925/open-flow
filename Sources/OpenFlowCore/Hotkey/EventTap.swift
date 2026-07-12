import AppKit
import CoreGraphics

/// Thin wrapper around a session CGEventTap for keyboard events.
///
/// Resilience: re-enables itself when macOS disables the tap (timeout or user
/// input), runs a watchdog, and rebuilds after system wake — event taps are
/// known to die silently in all three cases.
public final class EventTap {
    /// Return true to swallow the event (only possible when created with
    /// `swallowCapable` and the OS granted a default tap).
    public var handler: ((CGEvent, CGEventType) -> Bool)?

    public private(set) var isListenOnly = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var wakeObserver: NSObjectProtocol?

    public init() {}

    deinit {
        stop()
    }

    /// Creates and starts the tap. Returns false when the OS refuses
    /// (missing Accessibility/Input Monitoring permission).
    @discardableResult
    public func start(swallowCapable: Bool = true) -> Bool {
        stop()

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tap.reenable()
                return nil
            }
            let swallow = tap.handler?(event, type) ?? false
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var created = swallowCapable
            ? CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: callback, userInfo: refcon
            )
            : nil
        if created != nil {
            isListenOnly = false
        } else {
            created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .listenOnly, eventsOfInterest: mask,
                callback: callback, userInfo: refcon
            )
            isListenOnly = true
        }
        guard let machPort = created else { return false }

        tap = machPort
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)

        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reenable()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Taps can die across sleep/wake; rebuild from scratch.
            let wasSwallowCapable = !self.isListenOnly
            self.start(swallowCapable: wasSwallowCapable)
        }
        return true
    }

    public func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }

    public var isRunning: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    fileprivate func reenable() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
