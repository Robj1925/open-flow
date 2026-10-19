import AppKit
import OpenFlowCore
import SwiftUI

/// Floating live transcript shown above the recording pill: words pop in as
/// the engine recognizes them, so the user sees dictation land while still
/// speaking. Non-activating, so keyboard focus stays in the target app.
final class TranscriptPreviewPanel: NSPanel {
    private let hosting: NSHostingView<TranscriptPreviewView>

    init() {
        hosting = NSHostingView(rootView: TranscriptPreviewView())
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: TranscriptPreviewView.width, height: 80),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-measures the content (it grows as words arrive) and sits just above
    /// the recording pill on the screen the mouse is on.
    func showAbovePill() {
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 84 + 56 + 12)
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}

struct TranscriptPreviewView: View {
    static let width: CGFloat = 560
    /// Older words scroll out so a long dictation never fills the screen.
    static let visibleWords = 48

    @ObservedObject private var controller = AppState.shared.controller

    var body: some View {
        let transcript = controller.liveTranscript
        let all = transcript.committed + transcript.tentative
        let shown = Array(all.suffix(Self.visibleWords))
        let offset = all.count - shown.count
        let committedCount = transcript.committed.count

        Group {
            if shown.isEmpty {
                Text(controller.state.isTranscribing ? "Finishing…" : "Listening…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 5) {
                    if offset > 0 {
                        Text("…").foregroundStyle(.tertiary)
                    }
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, word in
                        // Committed words are final for the preview; the tail
                        // the engine is still deciding on is dimmed so a
                        // changing word reads as "not settled" instead of
                        // "the app got it wrong".
                        Text(word)
                            .opacity(offset + index < committedCount ? 1 : 0.5)
                            .id(offset + index)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .font(.title3)
                .foregroundStyle(controller.state.isTranscribing ? .secondary : .primary)
                .animation(.spring(duration: 0.22, bounce: 0.25), value: all.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

/// Left-to-right, top-to-bottom wrapping of variable-width children.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
