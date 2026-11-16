import AVFoundation
import SwiftUI

/// 同时播放系统声音和麦克风两份录音，按各自开始录的时刻对齐
@MainActor
final class DualPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentMs = 0
    @Published private(set) var durationMs = 0

    private var system: AVPlayer?
    private var mic: AVPlayer?
    private var micOffsetMs = 0
    private var observer: Any?

    func load(_ session: SessionInfo?) {
        stop()
        if let observer { system?.removeTimeObserver(observer) }
        observer = nil
        system = nil
        mic = nil
        currentMs = 0
        durationMs = 0
        guard let session, FileManager.default.fileExists(atPath: session.systemFile.path) else { return }
        let player = AVPlayer(url: session.systemFile)
        system = player
        durationMs = session.durationSeconds * 1000
        if FileManager.default.fileExists(atPath: session.micFile.path) {
            mic = AVPlayer(url: session.micFile)
            micOffsetMs = session.micOffsetMs
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            let ms = Int(CMTimeGetSeconds(time) * 1000)
            Task { @MainActor in
                guard let self else { return }
                self.currentMs = ms
                if self.durationMs > 0, ms >= self.durationMs { self.stop() }
            }
        }
    }

    var available: Bool { system != nil }

    func play(fromMs ms: Int) {
        guard let system else { return }
        currentMs = ms
        system.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        mic?.seek(to: CMTime(value: CMTimeValue(max(ms - micOffsetMs, 0)), timescale: 1000),
                  toleranceBefore: .zero, toleranceAfter: .zero)
        system.play()
        mic?.play()
        isPlaying = true
    }

    func toggle() {
        if isPlaying { stop() } else { play(fromMs: currentMs) }
    }

    func stop() {
        system?.pause()
        mic?.pause()
        isPlaying = false
    }
}

@MainActor
final class ReviewModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var selectedID: Int64? {
        didSet { if selectedID != oldValue { loadDetail(resetPlayer: true) } }
    }
    @Published var search = "" {
        didSet { hits = search.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Store.shared?.search(search) }
    }
    @Published private(set) var hits: Set<Int64>?
    @Published private(set) var utterances: [Utterance] = []
    @Published private(set) var qa: [QAItem] = []
    @Published private(set) var summary = ""
    @Published private(set) var jobs: [PostTask: JobState] = [:]
    /// 显示的是会后处理过的结果，还是会中的实时记录
    @Published private(set) var processed = false
    let player = DualPlayer()

    var selected: SessionInfo? { sessions.first { $0.id == selectedID } }
    var visibleSessions: [SessionInfo] {
        guard let hits else { return sessions }
        return sessions.filter { hits.contains($0.id) }
    }

    func reload() {
        sessions = Store.shared?.sessions() ?? []
        if selectedID == nil || selected == nil { selectedID = sessions.first?.id }
        // 选中的会话是在列表加载前就指定的：这时录音还没装进播放器
        loadDetail(resetPlayer: !player.available)
    }

    private func loadDetail(resetPlayer: Bool) {
        if resetPlayer { player.load(selected) }
        guard let store = Store.shared, let id = selectedID else {
            utterances = []; qa = []; summary = ""; jobs = [:]
            return
        }
        let post = store.utterances(session: id)
        processed = !post.isEmpty
        utterances = processed ? post : store.realtimeUtterances(session: id)
        let items = store.qaItems(session: id)
        qa = items.isEmpty ? store.realtimeQA(session: id) : items
        summary = store.summary(session: id)
        jobs = store.jobs(session: id)
    }

    func delete(_ session: SessionInfo) {
        player.load(nil)
        Store.shared?.deleteSession(session.id)
        // 只删应用自己的会话目录，防止数据库里的路径指到别处
        if session.dir.path.hasPrefix(AppPaths.sessions.path + "/") {
            try? FileManager.default.removeItem(at: session.dir)
        }
        Log.write("已删除面试记录：\(session.displayTitle)")
        selectedID = nil
        reload()
    }
}

/// 历史与复盘窗口：左边是历史面试，右边是选中那场的时间轴、纪要和问答
struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var post: PostProcessor

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("搜索全部面试", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(model.visibleSessions, selection: $model.selectedID) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayTitle).lineLimit(1)
                        Text(Self.subtitle(session)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
                if model.visibleSessions.isEmpty {
                    Text(model.sessions.isEmpty ? "还没有面试记录" : "没有找到").foregroundStyle(.secondary).padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if let session = model.selected {
                SessionDetailView(model: model, post: post, player: model.player, session: session)
                    .id(session.id)
            } else {
                Text("选择左边的一场面试").foregroundStyle(.secondary)
            }
        }
        .onAppear { model.reload() }
        .onChange(of: post.revision) { model.reload() }
        .frame(minWidth: 1000, minHeight: 640)
    }

    static func subtitle(_ session: SessionInfo) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d HH:mm"
        let seconds = session.durationSeconds
        return "\(formatter.string(from: session.startedAt)) · \(seconds / 60) 分 \(seconds % 60) 秒 · \(session.segmentCount) 句"
    }
}

private struct SessionDetailView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var post: PostProcessor
    @ObservedObject var player: DualPlayer
    let session: SessionInfo

    @State private var title = ""
    /// --review-qa：调试用，打开时直接显示问答页
    @State private var tab = CommandLine.arguments.contains("--review-qa") ? 1 : 0
    @State private var confirmingDelete = false
    @State private var renaming: Utterance?
    @State private var newName = ""

    private var isProcessing: Bool { post.running == session.id }
    private var allDone: Bool { PostTask.allCases.allSatisfy { ["done", "skipped"].contains(model.jobs[$0]?.status ?? "") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(session.displayTitle, text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit {
                        Store.shared?.setTitle(session: session.id, title: title.trimmingCharacters(in: .whitespaces))
                        model.reload()
                    }
                Spacer()
                Button(allDone ? "重新处理" : (model.jobs.isEmpty ? "开始处理" : "继续处理")) {
                    Task { await post.process(session.id, force: allDone) }
                }
                .disabled(post.running != nil)
                Menu("导出") {
                    Button("Markdown…") { export(pdf: false) }
                    Button("PDF…") { export(pdf: true) }
                }
                .frame(width: 80)
                Button("删除", role: .destructive) { confirmingDelete = true }
                    .disabled(isProcessing)
            }

            HStack(spacing: 10) {
                Text(ReviewView.subtitle(session) + " · " + session.mode.title).font(.caption).foregroundStyle(.secondary)
                if isProcessing {
                    ProgressView().controlSize(.small)
                    Text("正在处理：\(post.stage)").font(.caption)
                } else {
                    ForEach(PostTask.allCases, id: \.self) { task in
                        let state = model.jobs[task]
                        Label(task.title, systemImage: Self.icon(state?.status))
                            .font(.caption)
                            .foregroundStyle(Self.color(state?.status))
                            .help(state?.detail ?? "还没有处理")
                    }
                }
                Spacer()
            }
            if !model.processed, !isProcessing {
                Text("下面显示的是会中的实时记录。点\"开始处理\"后会重新转写、区分说话人、翻译全文，并生成问答评价和纪要。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let failed = PostTask.allCases.first(where: { model.jobs[$0]?.status == "failed" }), !isProcessing {
                Text("\(failed.title)失败：\(model.jobs[failed]?.detail ?? "")").font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            Divider()

            HSplitView {
                timeline.frame(minWidth: 380, idealWidth: 460)
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $tab) {
                        Text("纪要").tag(0)
                        Text("问答(\(model.qa.count))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    ScrollView {
                        if tab == 0 { summaryView } else { qaView }
                    }
                }
                .padding(.leading, 12)
                .frame(minWidth: 380, idealWidth: 520)
            }
        }
        .padding(16)
        .onAppear { title = session.title }
        .confirmationDialog("删除这场面试的全部记录和录音？删除后无法恢复。", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { model.delete(session) }
            Button("取消", role: .cancel) {}
        }
        .alert("修改说话人的名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名字", text: $newName)
            Button("保存") {
                if let utterance = renaming, let label = Store.shared?.speakerLabel(utterance: utterance.id) {
                    Store.shared?.renameSpeaker(session: session.id, label: label,
                                                name: newName.trimmingCharacters(in: .whitespaces))
                    model.reload()
                }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("这场面试里同一位说话人的所有发言都会改名。")
        }
    }

    // MARK: 时间轴

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .disabled(!player.available)
                Text("\(Exporter.clock(player.currentMs)) / \(Exporter.clock(player.durationMs))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(player.currentMs) },
                                      set: { player.play(fromMs: Int($0)) }),
                       in: 0...Double(max(player.durationMs, 1)))
                    .disabled(!player.available)
            }
            if !player.available {
                Text("这场面试没有录音文件").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.utterances) { utterance in
                        let current = player.currentMs >= utterance.startMs && player.currentMs < utterance.endMs
                            && (player.isPlaying || player.currentMs > 0)
                        HStack(alignment: .top, spacing: 8) {
                            Text(Exporter.clock(utterance.startMs))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(utterance.speaker).font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: utterance.speaker))
                                Text(utterance.text).textSelection(.enabled)
                                if !utterance.translation.isEmpty {
                                    Text(utterance.translation).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.accentColor.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.play(fromMs: utterance.startMs) }
                        .contextMenu {
                            Button("从这里播放") { player.play(fromMs: utterance.startMs) }
                            if utterance.id > 0 {
                                Button("修改说话人的名字…") {
                                    newName = utterance.speaker
                                    renaming = utterance
                                }
                            }
                        }
                    }
                    if model.utterances.isEmpty {
                        Text("这场面试没有转写内容").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.trailing, 8)
            }
            Text("双击一段发言从那里开始播放；右键可以改说话人的名字。").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func color(for speaker: String) -> Color {
        if model.utterances.first(where: { $0.speaker == speaker })?.channel == "mic" { return .green }
        let others = Array(Set(model.utterances.filter { $0.channel != "mic" }.map(\.speaker))).sorted()
        let palette: [Color] = [.blue, .orange, .purple, .pink, .teal]
        return palette[(others.firstIndex(of: speaker) ?? 0) % palette.count]
    }

    // MARK: 纪要和问答

    private var summaryView: some View {
        Group {
            if model.summary.isEmpty {
                Text(isProcessing ? "纪要生成中…" : "还没有纪要。处理完成后会显示在这里。").foregroundStyle(.secondary)
            } else {
                MarkdownText(model.summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var qaView: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if model.qa.isEmpty {
                Text("还没有问答。").foregroundStyle(.secondary)
            }
            ForEach(model.qa) { item in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text("\(item.idx + 1). \(item.question)").font(.headline).textSelection(.enabled)
                            Spacer()
                            Button(Exporter.clock(item.askedMs)) { player.play(fromMs: item.askedMs) }
                                .controlSize(.small).disabled(!player.available).help("从提问的地方开始播放")
                        }
                        HStack(spacing: 8) {
                            if !item.kind.isEmpty {
                                Text(item.kind).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            }
                            if item.score > 0 {
                                Text(String(repeating: "★", count: item.score) + String(repeating: "☆", count: 5 - item.score))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if !item.myAnswer.isEmpty {
                            section(item.kind == "反问" ? "面试官的回答" : "我的回答") {
                                Text(item.myAnswer).textSelection(.enabled)
                            }
                        }
                        if !item.evaluation.isEmpty { section("评价") { MarkdownText(item.evaluation) } }
                        if !item.reference.isEmpty {
                            DisclosureGroup("参考答案") { MarkdownText(item.reference).padding(.top, 4) }
                        }
                        if !item.suggested.isEmpty {
                            DisclosureGroup("会中给出的建议答案") {
                                MarkdownText(item.suggested.replacingOccurrences(of: "\n---", with: "\n")).padding(.top, 4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: 导出

    private func export(pdf: Bool) {
        guard let store = Store.shared, let current = store.session(session.id) else { return }
        let markdown = Exporter.markdown(session: current, summary: model.summary, qa: model.qa, utterances: model.utterances)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = current.displayTitle.replacingOccurrences(of: "/", with: "-") + (pdf ? ".pdf" : ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if pdf {
                try Exporter.writePDF(markdown: markdown, to: url)
            } else {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            }
            Log.write("已导出：\(url.path)")
        } catch {
            Log.write("导出失败：\(error)")
        }
    }

    private static func icon(_ status: String?) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "skipped": return "minus.circle"
        case "failed": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private static func color(_ status: String?) -> Color {
        switch status {
        case "done": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

/// 简单的 Markdown 显示：标题、列表、加粗
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") || line.hasPrefix("# ") || line.hasPrefix("### ") {
                    Text(inline(String(line.drop { $0 == "#" || $0 == " " }))).font(.headline).padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else if !line.isEmpty {
                    Text(inline(line))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }
}
