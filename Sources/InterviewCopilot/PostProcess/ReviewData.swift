import Foundation

/// 一场面试(历史列表里的一行)
struct SessionInfo: Identifiable, Hashable {
    let id: Int64
    var startedAt: Date
    var endedAt: Date?
    var mode: LanguageMode
    var dir: URL
    var title: String
    /// 系统声音和麦克风各自开始录的时刻；两者之差就是麦克风录音相对系统录音的偏移
    var systemStart: Double?
    var micStart: Double?
    var segmentCount: Int

    var micOffsetMs: Int {
        guard let systemStart, let micStart else { return 0 }
        return Int((micStart - systemStart) * 1000)
    }
    var systemFile: URL { dir.appendingPathComponent("system.m4a") }
    var micFile: URL { dir.appendingPathComponent("mic.m4a") }
    var durationSeconds: Int { Int((endedAt ?? startedAt).timeIntervalSince(startedAt)) }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let formatter = DateFormatter()
        formatter.dateFormat = L("M 月 d 日 HH:mm")
        return L("%@ 的面试", formatter.string(from: startedAt))
    }
}

/// 复盘页时间轴上的一段发言
struct Utterance: Identifiable, Hashable {
    let id: Int64
    var channel: String      // system 或 mic
    var speaker: String      // 面试官、面试官 A、我 …
    var startMs: Int
    var endMs: Int
    var text: String
    var translation: String
}

/// 一组问答
struct QAItem: Identifiable, Hashable {
    let id: Int64
    var idx: Int
    var question: String
    var kind: String
    var askedMs: Int
    var myAnswer: String
    var suggested: String    // 会中当时给出的建议答案
    var evaluation: String
    var reference: String
    var score: Int           // 1–5，0 表示没有评分
}

/// 会后处理的四个任务，按顺序执行
enum PostTask: String, CaseIterable {
    case transcribe, dedupe, translate, analyze

    var title: String {
        switch self {
        case .transcribe: return L("重新转写")
        case .dedupe: return L("回声去重")
        case .translate: return L("全文翻译")
        case .analyze: return L("问答与纪要")
        }
    }
}

struct JobState: Hashable {
    var status: String       // done、failed、skipped
    var detail: String
}

extension Store {
    private func int(_ value: Any?) -> Int { Int(value as? Int64 ?? 0) }

    func sessions() -> [SessionInfo] {
        query("""
        SELECT s.*, (SELECT COUNT(*) FROM segment WHERE session_id = s.id) AS segment_count
        FROM session s ORDER BY s.id DESC
        """).map { row in
            SessionInfo(id: row["id"] as? Int64 ?? 0,
                        startedAt: Date(timeIntervalSince1970: row["started_at"] as? Double ?? 0),
                        endedAt: (row["ended_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                        mode: LanguageMode(rawValue: row["mode"] as? String ?? "") ?? .enToZh,
                        dir: URL(fileURLWithPath: row["dir"] as? String ?? ""),
                        title: row["title"] as? String ?? "",
                        systemStart: row["system_audio_started_at"] as? Double,
                        micStart: row["mic_audio_started_at"] as? Double,
                        segmentCount: int(row["segment_count"]))
        }
    }

    func session(_ id: Int64) -> SessionInfo? { sessions().first { $0.id == id } }

    func setTitle(session: Int64, title: String) {
        run("UPDATE session SET title = ? WHERE id = ?", [title, session])
    }

    /// 会后处理过的发言；显示用的说话人名字已经换成用户改过的名字
    func utterances(session: Int64) -> [Utterance] {
        let names = Dictionary(uniqueKeysWithValues: query("SELECT label, name FROM speaker_name WHERE session_id = ?", [session])
            .compactMap { row -> (String, String)? in
                guard let label = row["label"] as? String, let name = row["name"] as? String else { return nil }
                return (label, name)
            })
        return query("SELECT * FROM utterance WHERE session_id = ? ORDER BY start_ms, id", [session]).map { row in
            let label = row["speaker"] as? String ?? ""
            return Utterance(id: row["id"] as? Int64 ?? 0, channel: row["channel"] as? String ?? "",
                             speaker: names[label] ?? label, startMs: int(row["start_ms"]), endMs: int(row["end_ms"]),
                             text: row["text"] as? String ?? "", translation: row["translation"] as? String ?? "")
        }
    }

    /// 会中的实时句段，会后处理完成前先拿它顶上
    func realtimeUtterances(session: Int64) -> [Utterance] {
        query("SELECT * FROM segment WHERE session_id = ? ORDER BY start_ms, id", [session]).map { row in
            Utterance(id: -(row["id"] as? Int64 ?? 0), channel: "system", speaker: ["面试官"][0],
                      startMs: int(row["start_ms"]), endMs: int(row["end_ms"]),
                      text: row["text_rt"] as? String ?? "", translation: row["translation_rt"] as? String ?? "")
        }
    }

    @discardableResult
    func insertUtterance(session: Int64, channel: String, speaker: String, startMs: Int, endMs: Int, text: String) -> Int64 {
        run("INSERT INTO utterance (session_id, channel, speaker, start_ms, end_ms, text) VALUES (?, ?, ?, ?, ?, ?)",
            [session, channel, speaker, startMs, endMs, text])
    }

    /// 改说话人的名字。label 是数据库里原始的标签。
    func renameSpeaker(session: Int64, label: String, name: String) {
        if name.isEmpty || name == label {
            run("DELETE FROM speaker_name WHERE session_id = ? AND label = ?", [session, label])
        } else {
            run("INSERT OR REPLACE INTO speaker_name (session_id, label, name) VALUES (?, ?, ?)", [session, label, name])
        }
    }

    /// 某条发言在数据库里原始的说话人标签
    func speakerLabel(utterance: Int64) -> String? {
        query("SELECT speaker FROM utterance WHERE id = ?", [utterance]).first?["speaker"] as? String
    }

    func qaItems(session: Int64) -> [QAItem] {
        query("SELECT * FROM qa_item WHERE session_id = ? ORDER BY idx", [session]).map { row in
            QAItem(id: row["id"] as? Int64 ?? 0, idx: int(row["idx"]), question: row["question"] as? String ?? "",
                   kind: row["kind"] as? String ?? "", askedMs: int(row["asked_ms"]),
                   myAnswer: row["my_answer"] as? String ?? "", suggested: row["suggested"] as? String ?? "",
                   evaluation: row["evaluation"] as? String ?? "", reference: row["reference"] as? String ?? "",
                   score: int(row["score"]))
        }
    }

    /// 会中实时生成的答案(问题、答案、问题结束时的音频位置)
    func realtimeQA(session: Int64) -> [QAItem] {
        query("SELECT * FROM qa WHERE session_id = ? ORDER BY asked_ms", [session]).enumerated().map { index, row in
            QAItem(id: -(row["id"] as? Int64 ?? 0), idx: index, question: row["question"] as? String ?? "", kind: "",
                   askedMs: int(row["asked_ms"]), myAnswer: "", suggested: row["answer"] as? String ?? "",
                   evaluation: "", reference: "", score: 0)
        }
    }

    func insertQAItem(session: Int64, _ item: QAItem) {
        run("""
        INSERT INTO qa_item (session_id, idx, question, kind, asked_ms, my_answer, suggested, evaluation, reference, score)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [session, item.idx, item.question, item.kind, item.askedMs, item.myAnswer, item.suggested,
              item.evaluation, item.reference, item.score])
    }

    func summary(session: Int64) -> String {
        query("SELECT markdown FROM summary WHERE session_id = ?", [session]).first?["markdown"] as? String ?? ""
    }

    func setSummary(session: Int64, markdown: String) {
        run("INSERT OR REPLACE INTO summary (session_id, markdown, created_at) VALUES (?, ?, ?)",
            [session, markdown, Date().timeIntervalSince1970])
    }

    func jobs(session: Int64) -> [PostTask: JobState] {
        var result: [PostTask: JobState] = [:]
        for row in query("SELECT task, status, detail FROM job WHERE session_id = ?", [session]) {
            guard let task = PostTask(rawValue: row["task"] as? String ?? "") else { continue }
            result[task] = JobState(status: row["status"] as? String ?? "", detail: row["detail"] as? String ?? "")
        }
        return result
    }

    func setJob(session: Int64, task: PostTask, status: String, detail: String) {
        run("INSERT OR REPLACE INTO job (session_id, task, status, detail, updated_at) VALUES (?, ?, ?, ?, ?)",
            [session, task.rawValue, status, detail, Date().timeIntervalSince1970])
    }

    /// 清掉会后处理的全部产物(重新处理前用)；会中的实时记录和录音不动
    func clearPostResults(session: Int64) {
        for table in ["utterance", "qa_item", "summary", "job", "speaker_name"] {
            run("DELETE FROM \(table) WHERE session_id = ?", [session])
        }
    }

    /// 删除一场面试的全部记录(录音文件由调用方删)
    func deleteSession(_ id: Int64) {
        clearPostResults(session: id)
        run("DELETE FROM segment WHERE session_id = ?", [id])
        run("DELETE FROM qa WHERE session_id = ?", [id])
        run("DELETE FROM session WHERE id = ?", [id])
    }

    /// 在全部历史面试里按关键词搜索，返回命中的会话编号
    func search(_ keyword: String) -> Set<Int64> {
        let pattern = "%\(keyword)%"
        let rows = query("""
        SELECT id AS sid FROM session WHERE title LIKE ?1
        UNION SELECT session_id FROM utterance WHERE text LIKE ?1 OR translation LIKE ?1
        UNION SELECT session_id FROM segment WHERE text_rt LIKE ?1 OR translation_rt LIKE ?1
        UNION SELECT session_id FROM qa_item WHERE question LIKE ?1 OR my_answer LIKE ?1 OR reference LIKE ?1
        UNION SELECT session_id FROM qa WHERE question LIKE ?1
        UNION SELECT session_id FROM summary WHERE markdown LIKE ?1
        """, [pattern])
        return Set(rows.compactMap { $0["sid"] as? Int64 })
    }
}
