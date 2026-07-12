import OpenFlowCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = AppState.shared.controller.history
    @State private var query = ""

    var body: some View {
        let records = store.records(matching: query)

        VStack(spacing: 0) {
            if records.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: "text.bubble",
                    description: Text(query.isEmpty
                        ? "Transcripts appear here after you dictate. Everything stays on this Mac."
                        : "No transcripts match “\(query)”.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.text)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(record.createdAt, format: .relative(presentation: .named))
                            if let app = record.appBundleID {
                                Text("→ \(appName(for: app))")
                            }
                            Text(String(format: "%.0fs", record.duration))
                            Text(record.engineID)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            Button {
                                store.delete(id: record.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
            HStack {
                Text("\(records.count) dictation\(records.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All", role: .destructive) {
                    store.deleteAll()
                }
                .disabled(records.isEmpty)
            }
            .padding(10)
        }
        .searchable(text: $query, prompt: "Search transcripts")
        .frame(minWidth: 480, minHeight: 360)
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }
}
