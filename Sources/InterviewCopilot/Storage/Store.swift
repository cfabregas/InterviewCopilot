import Foundation
import SQLite3

/// 会话和句段的本地存储(SQLite)。
final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "copilot.store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// 全应用共用一个连接
    static let shared: Store? = {
        do { return try Store(url: AppPaths.database) } catch {
            Log.write("数据库打不开：\(error)")
            return nil
        }
    }()

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
        CREATE TABLE IF NOT EXISTS qa (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES session(id),
            asked_ms INTEGER NOT NULL,
            question TEXT NOT NULL,
            answer TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        -- 以下是会后处理的产物
        CREATE TABLE IF NOT EXISTS utterance (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES session(id),
            channel TEXT NOT NULL,
            speaker TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            translation TEXT
        );
        CREATE INDEX IF NOT EXISTS utterance_session ON utterance(session_id, start_ms);
        CREATE TABLE IF NOT EXISTS speaker_name (
            session_id INTEGER NOT NULL,
            label TEXT NOT NULL,
            name TEXT NOT NULL,
            PRIMARY KEY (session_id, label)
        );
        CREATE TABLE IF NOT EXISTS qa_item (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL REFERENCES session(id),
            idx INTEGER NOT NULL,
            question TEXT NOT NULL,
            kind TEXT NOT NULL,
            asked_ms INTEGER NOT NULL,
            my_answer TEXT NOT NULL,
            suggested TEXT NOT NULL,
            evaluation TEXT NOT NULL,
            reference TEXT NOT NULL,
            score INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS summary (
            session_id INTEGER PRIMARY KEY,
            markdown TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS job (
            session_id INTEGER NOT NULL,
            task TEXT NOT NULL,
            status TEXT NOT NULL,
            detail TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (session_id, task)
        );
        """, nil, nil, nil)
        // 老数据库没有标题列；已经有了时这句会失败，忽略即可
        sqlite3_exec(db, "ALTER TABLE session ADD COLUMN title TEXT", nil, nil, nil)
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

    func insertQA(session: Int64, askedMs: Int, question: String, answer: String) {
        run("INSERT INTO qa (session_id, asked_ms, question, answer, created_at) VALUES (?, ?, ?, ?, ?)",
            [session, askedMs, question, answer, Date().timeIntervalSince1970])
    }

    func setTranslation(segment: Int64, translation: String) {
        run("UPDATE segment SET translation_rt = ? WHERE id = ?", [translation, segment])
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
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
    }

    /// 查询，每行一个字典。整数是 Int64，小数是 Double，文本是 String，空值不出现在字典里。
    func query(_ sql: String, _ values: [Any?] = []) -> [[String: Any]] {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                Log.write("SQL 准备失败：\(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, values)
            var rows: [[String: Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                    default: break
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    @discardableResult
    func run(_ sql: String, _ values: [Any?] = []) -> Int64 {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                Log.write("SQL 准备失败：\(String(cString: sqlite3_errmsg(db)))")
                return -1
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, values)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Log.write("SQL 执行失败：\(String(cString: sqlite3_errmsg(db)))")
                return -1
            }
            return sqlite3_last_insert_rowid(db)
        }
    }
}
