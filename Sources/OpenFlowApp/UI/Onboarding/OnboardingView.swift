import OpenFlowCore
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, model, tryIt
    }

    let onFinished: () -> Void

    @ObservedObject private var permissions = AppState.shared.permissions
    @ObservedObject private var controller = AppState.shared.controller
    @ObservedObject private var settings = AppState.shared.settings
    @State private var step: Step = .welcome
    @State private var tryItText = ""

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)

            Divider()

            HStack {
                if step != .welcome, step != .tryIt {
                    Button("Back") { move(-1) }
                }
                Spacer()
                Button(step == .tryIt ? "Finish" : "Continue") {
                    if step == .tryIt {
                        onFinished()
                    } else {
                        move(+1)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
        // System permission dialogs hand focus back to the previously active
        // app, dropping this window behind everything — reclaim it.
        .onChange(of: permissions.microphoneGranted) { _, granted in
            if granted { bringToFront() }
        }
        .onChange(of: permissions.accessibilityGranted) { _, granted in
            if granted { bringToFront() }
        }
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // Activation can be denied (cooperative activation, macOS 14+);
        // orderFrontRegardless works even while another app stays active.
        NSApp.windows.first { $0.title == "Welcome to OpenFlow" }?.orderFrontRegardless()
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .microphone: return permissions.microphoneGranted
        case .accessibility: return permissions.accessibilityGranted
        case .model: return controller.modelState == .ready
        case .tryIt: return true
        }
    }

    private func move(_ delta: Int) {
        let next = Step(rawValue: step.rawValue + delta) ?? step
        step = next
        if next == .model {
            // Kick off download/load if it isn't already running.
            if case .unloaded = controller.modelState {
                Task { await controller.loadSelectedEngine() }
            }
            if case .failed = controller.modelState {
                Task { await controller.loadSelectedEngine() }
            }
        }
        if next == .tryIt {
            controller.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 16) {
                // The real app icon, straight from the bundle — never drifts
                // from the logo shown in Finder/System Settings.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                Text("Welcome to OpenFlow")
                    .font(.largeTitle.bold())
                Text("Hold a key, speak, release — your words appear wherever your cursor is. Everything runs on this Mac; audio never leaves your machine.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Setup takes about two minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .microphone:
            PermissionStepView(
                icon: "mic.fill",
                title: "Microphone",
                granted: permissions.microphoneGranted,
                explanation: "OpenFlow records only while you hold the dictation key. Audio is transcribed locally and immediately discarded.",
                requestTitle: "Allow Microphone",
                request: { Task { await permissions.requestMicrophone() } },
                openSettings: { PermissionsService.openSystemSettings(.microphone) }
            )

        case .accessibility:
            PermissionStepView(
                icon: "accessibility",
                title: "Accessibility",
                granted: permissions.accessibilityGranted,
                explanation: "Needed to watch for your dictation hotkey system-wide and to type the transcribed text into the app you're using.",
                requestTitle: "Request Accessibility",
                request: { permissions.requestAccessibility() },
                openSettings: { PermissionsService.openSystemSettings(.accessibility) }
            )

        case .model:
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Speech Model")
                    .font(.title.bold())
                Text("OpenFlow uses \(settings.modelPreset.displayName) (\(settings.modelPreset.approxSize)), downloaded once and stored on this Mac. You can switch models later in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                switch controller.modelState {
                case .downloading(let progress):
                    ProgressView(value: progress) {
                        Text("Downloading… \(Int(progress * 100))%")
                    }
                    .frame(maxWidth: 320)
                case .loading:
                    ProgressView {
                        Text("Optimizing model for your Mac — one time only…")
                    }
                case .ready:
                    Label("Model ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    VStack(spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Retry") {
                            Task { await controller.loadSelectedEngine() }
                        }
                    }
                case .unloaded:
                    ProgressView()
                }
            }

        case .tryIt:
            VStack(spacing: 16) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Try it")
                    .font(.title.bold())
                Text("Click into the field below, then hold \(settings.hotkey.displayName), say something, and release.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                TextEditor(text: $tryItText)
                    .font(.body)
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                if !controller.hotkeys.isRunning {
                    Label("Hotkey listener couldn't start — this usually means Input Monitoring is also required.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Open Input Monitoring Settings") {
                        permissions.requestInputMonitoring()
                        PermissionsService.openSystemSettings(.inputMonitoring)
                    }
                }
            }
        }
    }
}

private struct PermissionStepView: View {
    let icon: String
    let title: String
    let granted: Bool
    let explanation: String
    let requestTitle: String
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title.bold())
            Text(explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                VStack(spacing: 10) {
                    Button(requestTitle, action: request)
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings", action: openSettings)
                }
            }
        }
    }
}
