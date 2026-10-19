import AppKit
import Combine
import OpenFlowCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState.shared
    private var hudPanel: RecordingHUDPanel?
    private var previewPanel: TranscriptPreviewPanel?
    private var onboardingWindow: NSWindow?
    /// A plain denial gets one automatic re-ask per launch, not a nag loop.
    private var microphoneRepromptUsed = false
    private var cancellables = Set<AnyCancellable>()
    private var hudHideWork: DispatchWorkItem?
    /// Target of the "Read Aloud with OpenFlow" Service (see Info.plist).
    private let serviceProvider = ReadAloudServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement covers the bundled app; this covers bare `swift run`.
        NSApp.setActivationPolicy(.accessory)

        let panel = RecordingHUDPanel()
        hudPanel = panel
        previewPanel = TranscriptPreviewPanel()

        state.controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHUD() }
            .store(in: &cancellables)
        state.readAloud.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshHUD() }
            .store(in: &cancellables)
        // The live transcript grows word by word; re-fit the panel each time.
        state.controller.$liveTranscript
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPreview() }
            .store(in: &cancellables)

        // Registers the context-menu Service in every app. The menu item
        // itself comes from Info.plist; this object receives the selection.
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        // A failed mic start that points at the permission (stale entry after
        // a rebuild, or denied) clears the entry and re-asks, so recovery is
        // a single click on Allow instead of a trip through System Settings.
        state.controller.onMicrophoneAccessFailed = { [weak self] failure in
            self?.recoverMicrophoneGrant(after: failure)
        }

        if state.settings.onboardingCompleted, state.permissions.allEssentialGranted {
            state.controller.start()
        } else {
            // Setup is back because a grant is missing. On an ad-hoc build that
            // usually means the entry belongs to the previous signature; clear
            // it so the prompts and the System Settings toggles work again.
            state.permissions.clearStaleGrants()
            showOnboarding()
        }
        // Warm the Read Aloud voice only if it was downloaded before; a
        // first-time download waits for an explicit request.
        if KokoroSpeechSynthesizer.isDownloaded {
            Task { await state.readAloud.prepareVoice() }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Re-opening the app (Finder double-click, `open`) recovers the setup
    /// window if setup never finished — without this, a closed onboarding
    /// window leaves no path back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state.permissions.refresh()
        if !state.settings.onboardingCompleted || !state.permissions.allEssentialGranted {
            state.permissions.clearStaleGrants()
            showOnboarding()
        }
        return true
    }

    // MARK: - Permission recovery

    /// Clears the Microphone entry and shows the system prompt again. Always
    /// when macOS is visibly ignoring a grant that looks enabled; once per
    /// launch for a denial or a missing device, so a deliberate "Don't Allow"
    /// is not nagged on every hotkey press.
    private func recoverMicrophoneGrant(after failure: AudioCaptureEngine.StartFailure) {
        switch failure {
        case .grantStale:
            break
        case .permissionDenied, .noInputDevice:
            guard !microphoneRepromptUsed else { return }
            microphoneRepromptUsed = true
        case .permissionPending, .engineDeallocated, .unsupportedFormat:
            return
        }
        PermissionsService.resetGrant(.microphone)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.state.permissions.requestMicrophone()
        }
    }

    // MARK: - HUD lifecycle

    /// The live transcript is visible from the first captured buffer until
    /// the final text is inserted.
    private func refreshPreview() {
        guard let previewPanel else { return }
        let dictationState = state.controller.state
        let wanted = state.settings.livePreviewEnabled
            && (dictationState.isRecording || dictationState.isTranscribing)
        if wanted {
            // Let SwiftUI lay out the new words before measuring.
            DispatchQueue.main.async { previewPanel.showAbovePill() }
        } else {
            previewPanel.orderOut(nil)
        }
    }

    private func refreshHUD() {
        guard let hudPanel else { return }
        hudHideWork?.cancel()
        refreshPreview()

        let dictationState = state.controller.state
        let readAloudState = state.readAloud.state

        if dictationState.isIdle, !readAloudState.isActive {
            // Give error/status flashes a moment on screen before hiding —
            // and surface them even if the panel wasn't up yet (e.g. mic
            // failure straight from idle).
            var hasMessage = state.controller.statusMessage != nil
            if case .failed = readAloudState { hasMessage = true }
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
