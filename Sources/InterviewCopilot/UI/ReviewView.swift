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

/// 历史复盘页：左边是历史面试，右边是选中那场的时间轴、纪要和问答
struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var post: PostProcessor

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("历史复盘")).font(Theme.display(26)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 12)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField(L("搜索全部面试"), text: $model.search).textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .capsuleGlass()
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.visibleSessions) { session in
                            let selected = model.selectedID == session.id
                            Button {
                                model.selectedID = session.id
                            } label: {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.displayTitle)
                                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                            .foregroundStyle(Theme.ink).lineLimit(1)
                                        Text(Self.subtitle(session)).font(.system(size: 11).monospacedDigit())
                                            .foregroundStyle(Theme.muted).lineLimit(1)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    Spacer(minLength: 0)
                                }
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected ? Theme.accent.opacity(0.12) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                        }
                    }
                }
                if model.visibleSessions.isEmpty {
                    Text(model.sessions.isEmpty ? L("还没有面试记录。完成一场面试或模拟面试后会出现在这里。") : L("没有找到匹配的面试。"))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(18)
                    Spacer()
                }
            }
            .frame(width: 264)
            .background(Theme.surface.opacity(0.4))
            Rectangle().fill(Theme.line).frame(width: 1)

            if let session = model.selected {
                SessionDetailView(model: model, post: post, player: model.player, session: session)
                    .id(session.id)
            } else {
                Text(L("选择左边的一场面试")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.reload() }
        .onChange(of: post.revision) { model.reload() }
    }

    static func subtitle(_ session: SessionInfo) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = L("M 月 d 日 HH:mm")
        let seconds = session.durationSeconds
        return L("%@，%@ 分 %@ 秒", "\(formatter.string(from: session.startedAt))", "\(seconds / 60)", "\(seconds % 60)")
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HSplitView {
                timeline
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .frame(minWidth: 300, idealWidth: 380, maxHeight: .infinity)
                    .background(Theme.paper.opacity(0.5))
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $tab) {
                    Text(L("纪要")).tag(0)
                    Text(L("问答 %@", "\(model.qa.count)")).tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()
                    ScrollView {
                        if tab == 0 { summaryView } else { qaView }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { title = session.title }
        .confirmationDialog(L("删除这场面试的全部记录和录音？删除后无法恢复。"), isPresented: $confirmingDelete) {
            Button(L("删除"), role: .destructive) { model.delete(session) }
            Button(L("取消"), role: .cancel) {}
        }
        .alert(L("修改说话人的名字"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("名字"), text: $newName)
            Button(L("保存")) {
                if let utterance = renaming, let label = Store.shared?.speakerLabel(utterance: utterance.id) {
                    Store.shared?.renameSpeaker(session: session.id, label: label,
                                                name: newName.trimmingCharacters(in: .whitespaces))
                    model.reload()
                }
                renaming = nil
            }
            Button(L("取消"), role: .cancel) { renaming = nil }
        } message: {
            Text(L("这场面试里同一位说话人的所有发言都会改名。"))
        }
    }

    // MARK: 顶部：标题、动作、处理进度

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField(session.displayTitle, text: $title)
                    .textFieldStyle(.plain)
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.ink)
                    .onSubmit {
                        Store.shared?.setTitle(session: session.id, title: title.trimmingCharacters(in: .whitespaces))
                        model.reload()
                    }
                    .help(L("点击可以修改标题，回车保存"))
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                Button(allDone ? L("重新处理") : (model.jobs.isEmpty ? L("开始处理") : L("继续处理"))) {
                    Task { await post.process(session.id, force: allDone) }
                }
                .buttonStyle(allDone ? AnyButtonStyle(QuietButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                .disabled(post.running != nil)
                Menu(L("导出")) {
                    Button("Markdown…") { export(pdf: false) }
                    Button("PDF…") { export(pdf: true) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 5)
                .capsuleGlass()
                Button(L("删除")) { confirmingDelete = true }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isProcessing)
            }

            Text(ReviewView.subtitle(session) + L("，") + session.mode.title)
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted).lineLimit(1)
            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("正在处理：%@", "\(post.stage)")).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            } else {
                // 四个步骤连成一条线：做完的是实心点；窗口窄或者英文较长时换行
                FlowLayout(spacing: 6) {
                    ForEach(Array(PostTask.allCases.enumerated()), id: \.offset) { index, task in
                        let state = model.jobs[task]
                        HStack(spacing: 6) {
                            if index > 0 { Rectangle().fill(Theme.line).frame(width: 18, height: 1) }
                            Circle()
                                .fill(state?.status == "done" ? Theme.good : (state?.status == "failed" ? Theme.live : .clear))
                                .overlay(Circle().strokeBorder(Self.color(state?.status)))
                                .frame(width: 8, height: 8)
                            Text(task.title).font(.system(size: 12)).foregroundStyle(state == nil ? Theme.muted : Theme.ink)
                        }
                        .help(state?.detail ?? L("还没有处理"))
                    }
                }
            }
            if !model.processed, !isProcessing {
                Text(L("下面是面试当时的实时记录。点\"开始处理\"会重新转写、区分说话人、翻译全文，并生成问答评价和纪要。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            if let failed = PostTask.allCases.first(where: { model.jobs[$0]?.status == "failed" }), !isProcessing {
                Text(L("%@失败：%@", "\(failed.title)", "\(model.jobs[failed]?.detail ?? "")")).font(.system(size: 12)).foregroundStyle(Theme.live).lineLimit(2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // MARK: 时间轴

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(player.available ? Theme.accent : Theme.muted.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!player.available)
                Slider(value: Binding(get: { Double(player.currentMs) },
                                      set: { player.play(fromMs: Int($0)) }),
                       in: 0...Double(max(player.durationMs, 1)))
                    .controlSize(.small)
                    .disabled(!player.available)
                Text("\(Exporter.clock(player.currentMs)) / \(Exporter.clock(player.durationMs))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            if !player.available {
                Text(L("这场面试没有录音文件")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.utterances) { utterance in
                        let current = player.currentMs >= utterance.startMs && player.currentMs < utterance.endMs
                            && (player.isPlaying || player.currentMs > 0)
                        HStack(alignment: .top, spacing: 10) {
                            Text(Exporter.clock(utterance.startMs))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                                .frame(width: 38, alignment: .leading)
                                .padding(.top, 2)
                            Rectangle().fill(color(for: utterance.speaker)).frame(width: 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Localized.speaker(utterance.speaker)).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(color(for: utterance.speaker))
                                Text(utterance.text).font(.system(size: 13)).foregroundStyle(Theme.ink)
                                    .lineSpacing(2).textSelection(.enabled)
                                if !utterance.translation.isEmpty {
                                    Text(utterance.translation).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                        .lineSpacing(2).textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.accent.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.play(fromMs: utterance.startMs) }
                        .contextMenu {
                            Button(L("从这里播放")) { player.play(fromMs: utterance.startMs) }
                            if utterance.id > 0 {
                                Button(L("修改说话人的名字…")) {
                                    newName = utterance.speaker
                                    renaming = utterance
                                }
                            }
                        }
                    }
                    if model.utterances.isEmpty {
                        Text(L("这场面试没有转写内容")).font(.system(size: 13)).foregroundStyle(Theme.muted).padding()
                    }
                }
                .padding(.trailing, 8)
            }
            Text(L("双击一段发言从那里开始播放；右键可以改说话人的名字。")).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    /// 我用靛青；面试官按出现顺序用几种区分得开的颜色
    private func color(for speaker: String) -> Color {
        if model.utterances.first(where: { $0.speaker == speaker })?.channel == "mic" { return Theme.accent }
        let others = Array(Set(model.utterances.filter { $0.channel != "mic" }.map(\.speaker))).sorted()
        let palette: [Color] = [Color(red: 0.72, green: 0.38, blue: 0.16), Color(red: 0.16, green: 0.52, blue: 0.5),
                                Color(red: 0.56, green: 0.3, blue: 0.62), Color(red: 0.62, green: 0.5, blue: 0.1)]
        return palette[(others.firstIndex(of: speaker) ?? 0) % palette.count]
    }

    // MARK: 纪要和问答

    private var summaryView: some View {
        Group {
            if model.summary.isEmpty {
                Text(isProcessing ? L("纪要生成中…") : L("还没有纪要。处理完成后会显示在这里。"))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                MarkdownText(model.summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var qaView: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if model.qa.isEmpty {
                Text(L("还没有问答。")).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(model.qa) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(item.idx + 1)").font(Theme.display(20)).foregroundStyle(Theme.muted)
                        Text(item.question).font(Theme.display(16)).foregroundStyle(Theme.ink)
                            .lineSpacing(3).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button(Exporter.clock(item.askedMs)) { player.play(fromMs: item.askedMs) }
                            .buttonStyle(LinkButtonStyle()).disabled(!player.available).help(L("从提问的地方开始播放"))
                    }
                    HStack(spacing: 10) {
                        if !item.kind.isEmpty {
                            Text(L(item.kind)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.muted.opacity(0.12)))
                        }
                        if item.score > 0 {
                            HStack(spacing: 3) {
                                ForEach(1...5, id: \.self) { step in
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(step <= item.score ? Theme.cue : Theme.line)
                                        .frame(width: 14, height: 4)
                                }
                            }
                            Text(L("%@ 分，满分 5 分", "\(item.score)")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                    if !item.myAnswer.isEmpty {
                        section(item.kind == "反问" ? L("面试官的回答") : L("我的回答")) {
                            Text(item.myAnswer).font(.system(size: 13)).foregroundStyle(Theme.ink).lineSpacing(3).textSelection(.enabled)
                        }
                    }
                    if !item.evaluation.isEmpty { section(L("评价")) { MarkdownText(item.evaluation) } }
                    if !item.reference.isEmpty {
                        DisclosureGroup(L("参考答案")) { MarkdownText(item.reference).padding(.top, 6) }
                            .font(.system(size: 13, weight: .medium))
                    }
                    if !item.suggested.isEmpty {
                        DisclosureGroup(L("面试当时给出的建议答案")) {
                            MarkdownText(item.suggested.replacingOccurrences(of: "\n---", with: "\n")).padding(.top, 6)
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
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

    private static func color(_ status: String?) -> Color {
        switch status {
        case "done": return Theme.good
        case "failed": return Theme.live
        default: return Theme.muted.opacity(0.6)
        }
    }
}

/// 让两种按钮样式可以按条件二选一
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 简单的 Markdown 显示：标题、列表、加粗
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") || line.hasPrefix("# ") || line.hasPrefix("### ") {
                    Text(inline(L(String(line.drop { $0 == "#" || $0 == " " }))))
                        .font(Theme.display(15)).foregroundStyle(Theme.ink).padding(.top, 10)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.muted).frame(width: 4, height: 4).offset(y: -3)
                        Text(inline(String(line.dropFirst(2)))).font(.system(size: 13)).foregroundStyle(Theme.ink).lineSpacing(3)
                    }
                } else if !line.isEmpty {
                    Text(inline(line)).font(.system(size: 13)).foregroundStyle(Theme.ink).lineSpacing(3)
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
