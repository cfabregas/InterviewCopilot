import Foundation
import SQLite3

/// 会话和句段的本地存储(SQLite)。
final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "copilot.store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw AppError("打开数据库失败：\(url.path)")
        }
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS session (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at REAL NOT NULL,
            ended_at REAL,
            mode TEXT NOT NULL,
            dir TEXT NOT NULL,
            system_audio_started_at REAL,
            mic_audio_started_at REAL
        );
        CREATE TABLE IF NOT EXISTS segment (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES session(id),
            channel TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            lang TEXT NOT NULL,
            text_rt TEXT NOT NULL,
            translation_rt TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS segment_session ON segment(session_id, start_ms);
        """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    func createSession(mode: String, dir: String) -> Int64 {
        run("INSERT INTO session (started_at, mode, dir) VALUES (?, ?, ?)",
            [Date().timeIntervalSince1970, mode, dir])
    }

    func setAudioStart(session: Int64, system: Date?, mic: Date?) {
        run("UPDATE session SET system_audio_started_at = ?, mic_audio_started_at = ? WHERE id = ?",
            [system?.timeIntervalSince1970, mic?.timeIntervalSince1970, session])
    }

    func endSession(_ id: Int64) {
        run("UPDATE session SET ended_at = ? WHERE id = ?", [Date().timeIntervalSince1970, id])
    }

    func insertSegment(session: Int64, channel: String, startMs: Int, endMs: Int, lang: String, text: String) -> Int64 {
        run("INSERT INTO segment (session_id, channel, start_ms, end_ms, lang, text_rt, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [session, channel, startMs, endMs, lang, text, Date().timeIntervalSince1970])
    }

    func setTranslation(segment: Int64, translation: String) {
        run("UPDATE segment SET translation_rt = ? WHERE id = ?", [translation, segment])
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Any?]) -> Int64 {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                Log.write("SQL 准备失败：\(String(cString: sqlite3_errmsg(db)))")
                return -1
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
                case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
                case let v as Int64: sqlite3_bind_int64(statement, index, v)
                case let v as Double: sqlite3_bind_double(statement, index, v)
                default: sqlite3_bind_null(statement, index)
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Log.write("SQL 执行失败：\(String(cString: sqlite3_errmsg(db)))")
                return -1
            }
            return sqlite3_last_insert_rowid(db)
        }
    }
}
