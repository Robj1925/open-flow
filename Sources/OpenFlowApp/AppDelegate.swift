import AppKit
import Combine
import OpenFlowCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var hudPanel: RecordingHUDPanel?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var hudHideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the bundled app; this covers bare `swift run`.
        NSApp.setActivationPolicy(.accessory)

        let panel = RecordingHUDPanel()
        hudPanel = panel

        state.controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dictationState in
                self?.updateHUD(for: dictationState)
            }
            .store(in: &cancellables)

        if state.settings.onboardingCompleted, state.permissions.allEssentialGranted {
            state.controller.start()
        } else {
            showOnboarding()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Re-opening the app (Finder double-click, `open`) recovers the setup
    /// window if setup never finished — without this, a closed onboarding
    /// window leaves no path back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.permissions.refresh()
        if !state.settings.onboardingCompleted || !state.permissions.allEssentialGranted {
            showOnboarding()
        }
        return true
    }

    // MARK: - HUD lifecycle

    private func updateHUD(for dictationState: DictationState) {
        guard let hudPanel else { return }
        hudHideWork?.cancel()

        if dictationState.isIdle {
            // Give error/status flashes a moment on screen before hiding —
            // and surface them even if the panel wasn't up yet (e.g. mic
            // failure straight from idle).
            let hasMessage = state.controller.statusMessage != nil
            if hasMessage {
                hudPanel.showBottomCenter()
            }
            let work = DispatchWorkItem { [weak hudPanel] in
                hudPanel?.orderOut(nil)
            }
            hudHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (hasMessage ? 1.4 : 0.15), execute: work)
        } else {
            hudPanel.showBottomCenter()
        }
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Welcome to OpenFlow"
        window.isReleasedWhenClosed = false
        // Keep setup visible while the user is off in System Settings granting
        // permissions — macOS won't let a background app re-activate itself,
        // so a normal window would sink behind everything and look "closed".
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(onFinished: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.state.settings.onboardingCompleted = true
                self.onboardingWindow?.close()
                self.state.controller.start()
            }
        }))
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
