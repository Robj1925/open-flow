import AppKit

/// Full-fidelity snapshot of the general pasteboard, taken *before*
/// `clearContents()` — pasteboard items are invalidated by a clear, so all
/// data must be copied out first.
public struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public init(pasteboard: NSPasteboard = .general) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var byType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    byType[type] = data
                }
            }
            return byType
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { byType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in byType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
