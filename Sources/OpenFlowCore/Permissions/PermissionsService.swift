import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// Checks and requests the three permissions OpenFlow needs. The app is inert
/// without Microphone + Accessibility; Input Monitoring is only requested if
/// the OS refuses to create our event tap with Accessibility alone.
@MainActor
public final class PermissionsService: ObservableObject {
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var inputMonitoringGranted = false

    private var pollTimer: Timer?

    public init() {
        refresh()
    }

    public var allEssentialGranted: Bool { microphoneGranted && accessibilityGranted }

    public func refresh() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    /// Poll while onboarding is visible so the UI advances the moment the user
    /// flips a toggle in System Settings (there is no notification API for TCC).
    public func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// TCC services OpenFlow touches, named the way `tccutil` expects them.
    public enum TCCService: String {
        case microphone = "Microphone"
        case accessibility = "Accessibility"
        case inputMonitoring = "ListenEvent"
    }

    @discardableResult
    public func requestMicrophone() async -> Bool {
        // On an ad-hoc build a "denied" status is almost always an entry left
        // by an older signature, not a choice the user made. Clear it so the
        // system prompt can appear again instead of failing silently.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            Self.resetGrant(.microphone)
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Shows the system Accessibility prompt; after that the user flips the
    /// toggle in System Settings. A stale entry from an older signature
    /// suppresses the prompt and makes that toggle a no-op, so it is cleared
    /// first whenever we are not currently trusted.
    public func requestAccessibility() {
        if !AXIsProcessTrusted() {
            Self.resetGrant(.accessibility)
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Clears every essential grant that is not currently in effect. Called
    /// whenever setup has to be shown again, so a rebuilt binary never gets
    /// stuck behind entries recorded for the previous signature. A missing
    /// entry (first run) makes the reset a no-op.
    public func clearStaleGrants() {
        if !AXIsProcessTrusted() {
            Self.resetGrant(.accessibility)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            Self.resetGrant(.microphone)
        }
        refresh()
    }

    public func requestInputMonitoring() {
        CGRequestListenEventAccess()
        refresh()
    }

    /// Ad-hoc builds get a new code signature on every rebuild, and macOS keys
    /// Accessibility grants to the signature. After an update the old entry
    /// looks enabled in System Settings but no longer matches this binary, so
    /// toggling it does nothing. Clearing it lets the next request register a
    /// fresh entry that actually applies.
    public func clearStaleAccessibilityGrant() {
        Self.resetGrant(.accessibility)
        refresh()
    }

    /// `tccutil reset <service> <bundle id>`: removes this app's entry so the
    /// next request registers a fresh one that matches the running binary.
    nonisolated public static func resetGrant(_ service: TCCService) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = [
            "reset", service.rawValue,
            Bundle.main.bundleIdentifier ?? "dev.openflow.OpenFlow",
        ]
        try? task.run()
        task.waitUntilExit()
    }

    public enum SettingsPane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case keyboard = "com.apple.Keyboard-Settings.extension"
    }

    public static func openSystemSettings(_ pane: SettingsPane) {
        let url: URL?
        switch pane {
        case .keyboard:
            url = URL(string: "x-apple.systempreferences:\(pane.rawValue)")
        default:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        }
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
