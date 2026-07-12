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

    @discardableResult
    public func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Shows the system Accessibility prompt (once per app signature); after
    /// that the user must flip the toggle in System Settings.
    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    public func requestInputMonitoring() {
        CGRequestListenEventAccess()
        refresh()
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
