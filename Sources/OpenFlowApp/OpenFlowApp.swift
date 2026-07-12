import OpenFlowCore
import SwiftUI

/// Shared object graph for the app layer.
@MainActor
final class AppState {
    static let shared = AppState()

    let settings = AppSettings.shared
    let controller = DictationController()
    let permissions = PermissionsService()

    private init() {}
}

@main
struct OpenFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
        } label: {
            MenuBarLabel()
        }

        Settings {
            SettingsView()
        }

        Window("OpenFlow History", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 560, height: 480)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject private var controller = AppState.shared.controller

    var body: some View {
        Image(systemName: iconName)
    }

    private var iconName: String {
        switch controller.state {
        case .idle:
            if case .ready = controller.modelState { return "mic" }
            return "mic.badge.xmark"
        case .recording: return "mic.fill"
        case .transcribing, .injecting: return "waveform"
        }
    }
}

/// Accessory (menu-bar) apps aren't granted activation when they open a
/// window, so new windows land BEHIND the frontmost app. Activate, then order
/// the window front once it exists — orderFrontRegardless works even when
/// macOS denies the activation request.
@MainActor
private func focusWindow(matching predicate: @escaping (NSWindow) -> Bool) {
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        guard let window = NSApp.windows.first(where: predicate) else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

private struct MenuContentView: View {
    @ObservedObject private var controller = AppState.shared.controller
    @ObservedObject private var settings = AppState.shared.settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusLine)

        Divider()

        if !settings.onboardingCompleted {
            Button("Finish Setup…") {
                (NSApp.delegate as? AppDelegate)?.showOnboarding()
            }
        }

        Button("History…") {
            openWindow(id: "history")
            focusWindow { $0.title == "OpenFlow History" }
        }

        Button("Settings…") {
            openSettings()
            focusWindow {
                $0.identifier?.rawValue.contains("Settings") == true
                    || $0.title.localizedCaseInsensitiveContains("settings")
            }
        }
        .keyboardShortcut(",")

        Divider()

        Text("Hold \(settings.hotkey.displayName) to dictate")
            .font(.caption)

        Divider()

        Button("Quit OpenFlow") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.modelState {
        case .unloaded: return "Model not loaded"
        case .downloading(let progress): return "Downloading model… \(Int(progress * 100))%"
        case .loading: return "Warming up \(settings.modelPreset.displayName)…"
        case .failed(let message): return "Model error: \(message)"
        case .ready:
            switch controller.state {
            case .idle: return "Ready — \(settings.modelPreset.displayName)"
            case .recording: return "Listening…"
            case .transcribing: return "Transcribing…"
            case .injecting: return "Inserting text…"
            }
        }
    }
}
