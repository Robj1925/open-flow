import AppKit
import OpenFlowCore
import os

/// Receives the selected text from the system-wide "Read Aloud with OpenFlow"
/// Service. macOS looks up the `readAloud:userData:error:` selector named by
/// `NSMessage` in Info.plist on `NSApp.servicesProvider`.
@MainActor
final class ReadAloudServiceProvider: NSObject {
    private let logger = Logger(subsystem: "dev.openflow.OpenFlow", category: "ReadAloudService")

    @objc func readAloud(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            logger.error("Service invoked without plain text on the pasteboard")
            error.pointee = "OpenFlow could not read the selected text."
            return
        }
        logger.log("Service invoked with \(text.count) characters")
        AppState.shared.readAloud.speak(text)
    }
}
