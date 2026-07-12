import AppKit
import SwiftUI

/// Floating status pill shown while dictating. Non-activating and non-key so
/// keyboard focus never leaves the app being dictated into.
final class RecordingHUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 56),
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
        contentView = NSHostingView(rootView: RecordingHUDView())
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel bottom-center of the screen the mouse is on, without
    /// activating the app or taking key status.
    func showBottomCenter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - self.frame.width / 2,
            y: frame.minY + 84
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}
