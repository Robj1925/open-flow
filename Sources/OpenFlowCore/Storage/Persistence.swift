import Foundation
import SQLite3

// Plain SQLite3 storage. (SwiftData's @Model macro can't compile under
// Command Line Tools, and SQLite is the better fit for append-heavy history.)

public struct TranscriptRecord: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let text: String
    public let rawText: String
    public let createdAt: Date
    public let duration: TimeInterval
    public let appBundleID: String?
    public let engineID: String
}

public struct DictionaryEntryRecord: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var spoken: String
    public var replacement: String
    public var isSnippet: Bool
    public let createdAt: Date
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Owns the on-device database. Everything stays local:
/// ~/Library/Application Support/OpenFlow/OpenFlow.sqlite
@MainActor
public final class Persistence {
    public static let shared = Persistence()

    private var db: OpaquePointer?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("OpenFlow.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("OpenFlow could not open its local database at \(path)")
        }
        exec("PRAGMA journal_mode = WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            raw_text TEXT NOT NULL,
            created_at REAL NOT NULL,
            duration REAL NOT NULL,
            app_bundle_id TEXT,
            engine_id TEXT NOT NULL
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS dictionary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            spoken TEXT NOT NULL,
            replacement TEXT NOT NULL,
            is_snippet INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        )
        """)
    }

    fileprivate func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    fileprivate func statement(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }
}

@MainActor
public final class HistoryStore: ObservableObject {
    private let persistence: Persistence

    public init(persistence: Persistence = .shared) {
        self.persistence = persistence
    }

    public func save(text: String, rawText: String, duration: TimeInterval,
                     appBundleID: String?, engineID: String) {
        guard let stmt = persistence.statement("""
        INSERT INTO transcripts (text, raw_text, created_at, duration, app_bundle_id, engine_id)
        VALUES (?, ?, ?, ?, ?, ?)
        """) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, rawText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, duration)
        if let appBundleID {
            sqlite3_bind_text(stmt, 5, appBundleID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_text(stmt, 6, engineID, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        objectWillChange.send()
    }

    public func records(matching query: String = "", limit: Int = 500) -> [TranscriptRecord] {
        let sql: String
        if query.isEmpty {
            sql = "SELECT id, text, raw_text, created_at, duration, app_bundle_id, engine_id FROM transcripts ORDER BY created_at DESC LIMIT \(limit)"
        } else {
            sql = "SELECT id, text, raw_text, created_at, duration, app_bundle_id, engine_id FROM transcripts WHERE text LIKE ? ORDER BY created_at DESC LIMIT \(limit)"
        }
        guard let stmt = persistence.statement(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        if !query.isEmpty {
            sqlite3_bind_text(stmt, 1, "%\(query)%", -1, SQLITE_TRANSIENT)
        }
        var out: [TranscriptRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TranscriptRecord(
                id: sqlite3_column_int64(stmt, 0),
                text: String(cString: sqlite3_column_text(stmt, 1)),
                rawText: String(cString: sqlite3_column_text(stmt, 2)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                duration: sqlite3_column_double(stmt, 4),
                appBundleID: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                engineID: String(cString: sqlite3_column_text(stmt, 6))
            ))
        }
        return out
    }

    public func delete(id: Int64) {
        guard let stmt = persistence.statement("DELETE FROM transcripts WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        objectWillChange.send()
    }

    public func deleteAll() {
        persistence.exec("DELETE FROM transcripts")
        objectWillChange.send()
    }
}

@MainActor
public final class DictionaryStore: ObservableObject {
    private let persistence: Persistence

    public init(persistence: Persistence = .shared) {
        self.persistence = persistence
    }

    public func entries() -> [DictionaryEntryRecord] {
        guard let stmt = persistence.statement(
            "SELECT id, spoken, replacement, is_snippet, created_at FROM dictionary ORDER BY created_at DESC"
        ) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [DictionaryEntryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(DictionaryEntryRecord(
                id: sqlite3_column_int64(stmt, 0),
                spoken: String(cString: sqlite3_column_text(stmt, 1)),
                replacement: String(cString: sqlite3_column_text(stmt, 2)),
                isSnippet: sqlite3_column_int(stmt, 3) != 0,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return out
    }

    public func add(spoken: String, replacement: String, isSnippet: Bool = false) {
        guard let stmt = persistence.statement(
            "INSERT INTO dictionary (spoken, replacement, is_snippet, created_at) VALUES (?, ?, ?, ?)"
        ) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, spoken, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, replacement, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, isSnippet ? 1 : 0)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
        objectWillChange.send()
    }

    public func delete(id: Int64) {
        guard let stmt = persistence.statement("DELETE FROM dictionary WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        objectWillChange.send()
    }

    /// Rules for the post-transcription replacer.
    public func replacementRules() -> [ReplacementRule] {
        entries().map { ReplacementRule(spoken: $0.spoken, replacement: $0.replacement) }
    }

    /// Free-text vocabulary for Whisper prompt biasing, capped so it can't eat
    /// the decoder's context window (~1 token ≈ 4 chars).
    public func vocabularyPrompt(capTokens: Int = 200) -> String {
        let words = entries().filter { !$0.isSnippet }.map(\.replacement)
        var prompt = ""
        for word in words {
            let candidate = prompt.isEmpty ? word : prompt + ", " + word
            if candidate.count / 4 > capTokens { break }
            prompt = candidate
        }
        return prompt
    }
}
