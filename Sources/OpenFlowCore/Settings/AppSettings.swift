import Foundation
import ServiceManagement

/// UserDefaults-backed app settings, observable by SwiftUI.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let modelPreset = "modelPreset"
        static let hotkey = "hotkey"
        static let activationMode = "activationMode"
        static let language = "language"
        static let soundsEnabled = "soundsEnabled"
        static let restoreClipboard = "restoreClipboard"
        static let injectionMethod = "injectionMethod"
        static let historyEnabled = "historyEnabled"
        static let onboardingCompleted = "onboardingCompleted"
        static let cleanupEnabled = "cleanupEnabled"
    }

    private init() {}

    /// Selected model preset id from `ModelCatalog` (implies the engine).
    @Published public var modelPresetID: String = UserDefaults.standard.string(forKey: Key.modelPreset) ?? ModelCatalog.parakeetV2.id {
        didSet { defaults.set(modelPresetID, forKey: Key.modelPreset) }
    }

    public var modelPreset: ModelPreset {
        ModelCatalog.preset(id: modelPresetID) ?? ModelCatalog.parakeetV2
    }

    @Published public var hotkey: DictationHotkey = DictationHotkey(
        rawValue: UserDefaults.standard.string(forKey: Key.hotkey) ?? ""
    ) ?? .fn {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkey) }
    }

    @Published public var activationMode: ActivationMode = ActivationMode(
        rawValue: UserDefaults.standard.string(forKey: Key.activationMode) ?? ""
    ) ?? .auto {
        didSet { defaults.set(activationMode.rawValue, forKey: Key.activationMode) }
    }

    /// ISO 639-1 dictation language. Parakeet v2 supports "en" only.
    @Published public var language: String = UserDefaults.standard.string(forKey: Key.language) ?? "en" {
        didSet { defaults.set(language, forKey: Key.language) }
    }

    @Published public var soundsEnabled: Bool = UserDefaults.standard.object(forKey: Key.soundsEnabled) as? Bool ?? true {
        didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) }
    }

    @Published public var restoreClipboard: Bool = UserDefaults.standard.object(forKey: Key.restoreClipboard) as? Bool ?? true {
        didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) }
    }

    @Published public var injectionMethod: TextInjector.Method = TextInjector.Method(
        rawValue: UserDefaults.standard.string(forKey: Key.injectionMethod) ?? ""
    ) ?? .paste {
        didSet { defaults.set(injectionMethod.rawValue, forKey: Key.injectionMethod) }
    }

    @Published public var historyEnabled: Bool = UserDefaults.standard.object(forKey: Key.historyEnabled) as? Bool ?? true {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }

    /// Run the on-device LLM cleanup pass (filler-word removal, punctuation).
    /// On by default; silently no-ops when Apple Intelligence is unavailable.
    @Published public var cleanupEnabled: Bool = UserDefaults.standard.object(forKey: Key.cleanupEnabled) as? Bool ?? true {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    @Published public var onboardingCompleted: Bool = UserDefaults.standard.bool(forKey: Key.onboardingCompleted) {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    // MARK: Launch at login (SMAppService)

    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // .requiresApproval and similar: send the user to Login Items.
                SMAppService.openSystemSettingsLoginItems()
            }
            objectWillChange.send()
        }
    }
}
