import OpenFlowCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "cpu") }
            DictionarySettingsView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppState.shared.settings
    @ObservedObject private var controller = AppState.shared.controller
    @State private var launchAtLogin = AppState.shared.settings.launchAtLogin

    private let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ja", "Japanese"),
        ("ko", "Korean"), ("zh", "Chinese"), ("hi", "Hindi"), ("ru", "Russian"),
        ("ar", "Arabic"),
    ]

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Hotkey", selection: $settings.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Picker("Activation", selection: $settings.activationMode) {
                    Text("Auto (hold or quick-tap to toggle)").tag(ActivationMode.auto)
                    Text("Hold to talk").tag(ActivationMode.hold)
                    Text("Toggle (tap to start/stop)").tag(ActivationMode.toggle)
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                if settings.language != "en", settings.modelPreset.engine == .parakeet {
                    Label("Parakeet is English-only. Pick a Whisper model in the Models tab for \(languageName(settings.language)).",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("Clean up transcripts with Apple Intelligence", isOn: $settings.cleanupEnabled)
                cleanupStatus
            } header: {
                Text("Cleanup")
            } footer: {
                Text("Removes filler words and false starts, on-device. Runs only when a transcript actually contains disfluencies, and never delays a dictation more than a few seconds — if the model is slow, the raw transcript is inserted instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Picker("Insert text by", selection: $settings.injectionMethod) {
                    Text("Pasting (fast, recommended)").tag(TextInjector.Method.paste)
                    Text("Typing keystrokes (slower, maximum compatibility)").tag(TextInjector.Method.type)
                }
                Toggle("Restore previous clipboard after pasting", isOn: $settings.restoreClipboard)
                    .disabled(settings.injectionMethod == .type)
                Toggle("Play sounds", isOn: $settings.soundsEnabled)
                Toggle("Save dictation history", isOn: $settings.historyEnabled)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                        launchAtLogin = settings.launchAtLogin
                    }
                LabeledContent("fn key conflicts") {
                    Button("Set 🌐 key to “Do Nothing”…") {
                        PermissionsService.openSystemSettings(.keyboard)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.hotkey) { _, _ in controller.settingsChanged() }
        .onChange(of: settings.soundsEnabled) { _, _ in controller.settingsChanged() }
    }

    private func languageName(_ code: String) -> String {
        languages.first { $0.code == code }?.name ?? code
    }

    @ViewBuilder
    private var cleanupStatus: some View {
        switch controller.cleanupAvailability {
        case .available:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .notSupported:
            Label("Requires macOS 26 or later. Dictation still works; text just isn't cleaned.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label("Cleanup is off because \(reason). Transcripts are inserted as-is until you enable it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open Apple Intelligence Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Models

private struct ModelsSettingsView: View {
    @ObservedObject private var settings = AppState.shared.settings
    @ObservedObject private var controller = AppState.shared.controller
    @State private var refreshToken = 0

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { preset in
                    row(for: preset)
                }
            } footer: {
                Text("Models run entirely on this Mac. Switching engines warms the new model before the old one is released.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(refreshToken)
    }

    @ViewBuilder
    private func row(for preset: ModelPreset) -> some View {
        let isSelected = settings.modelPresetID == preset.id
        let isDownloaded = ModelManager.shared.isDownloaded(preset)

        HStack(alignment: .top) {
            Button {
                settings.modelPresetID = preset.id
                controller.settingsChanged()
            } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(preset.displayName).fontWeight(.medium)
                    if isSelected, case .downloading(let progress) = controller.modelState {
                        ProgressView(value: progress)
                            .frame(width: 90)
                    } else if isSelected, controller.modelState == .loading {
                        ProgressView().controlSize(.small)
                    } else if isSelected, controller.modelState == .ready {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(isDownloaded
                     ? "On disk: \(ByteCountFormatter.string(fromByteCount: ModelManager.shared.diskUsage(preset), countStyle: .file))"
                     : "Not downloaded (\(preset.approxSize))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isDownloaded, !isSelected {
                Button("Delete") {
                    try? ModelManager.shared.delete(preset)
                    refreshToken += 1
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Dictionary

private struct DictionarySettingsView: View {
    @ObservedObject private var store = AppState.shared.controller.dictionary
    @State private var spoken = ""
    @State private var replacement = ""
    @State private var isSnippet = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.entries()) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.replacement).fontWeight(.medium)
                            if entry.spoken.caseInsensitiveCompare(entry.replacement) != .orderedSame {
                                Text("heard as “\(entry.spoken)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if entry.isSnippet {
                            Text("Snippet")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer()
                        Button {
                            store.delete(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack {
                    TextField(isSnippet ? "Spoken trigger (e.g. “email sign off”)" : "Heard as (e.g. “cube cuddle”)", text: $spoken)
                    TextField(isSnippet ? "Expands to…" : "Replace with (e.g. “kubectl”)", text: $replacement)
                }
                HStack {
                    Toggle("Snippet", isOn: $isSnippet)
                    Spacer()
                    Button("Add") {
                        let spokenTrimmed = spoken.trimmingCharacters(in: .whitespaces)
                        let replacementTrimmed = replacement.trimmingCharacters(in: .whitespaces)
                        guard !spokenTrimmed.isEmpty else { return }
                        store.add(
                            spoken: spokenTrimmed,
                            replacement: replacementTrimmed.isEmpty ? spokenTrimmed : replacementTrimmed,
                            isSnippet: isSnippet
                        )
                        spoken = ""
                        replacement = ""
                        isSnippet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }
}
