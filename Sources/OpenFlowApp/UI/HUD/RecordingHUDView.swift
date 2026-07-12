import OpenFlowCore
import SwiftUI

struct RecordingHUDView: View {
    @ObservedObject private var controller = AppState.shared.controller
    @State private var levels: [Float] = Array(repeating: 0, count: 26)

    var body: some View {
        HStack(spacing: 10) {
            switch controller.state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                waveform
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text(controller.isCleaningUp ? "Cleaning up…" : "Transcribing…")
                    .font(.callout.weight(.medium))
            case .injecting:
                Image(systemName: "text.cursor")
                Text("Inserting…")
                    .font(.callout.weight(.medium))
            case .idle:
                if let message = controller.statusMessage {
                    Image(systemName: "info.circle")
                    Text(message)
                        .font(.callout)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minWidth: 180, maxWidth: 300)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .onReceive(controller.$level) { level in
            guard controller.state.isRecording else { return }
            levels.removeFirst()
            levels.append(level)
        }
        .onChange(of: controller.state.isRecording) { _, recording in
            if recording { levels = Array(repeating: 0, count: levels.count) }
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(0.85))
                    .frame(width: 3, height: barHeight(levels[index]))
            }
        }
        .frame(height: 28)
        .animation(.linear(duration: 0.05), value: levels)
    }

    private func barHeight(_ level: Float) -> CGFloat {
        // RMS for speech mostly lives below ~0.3; scale up for visibility.
        let normalized = min(CGFloat(level) * 6, 1)
        return max(3, normalized * 28)
    }
}
