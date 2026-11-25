import SwiftUI
import UniformTypeIdentifiers
import Translation

@MainActor
final class LogStore: ObservableObject {
    @Published var text = ""

    func append(_ line: String) {
        text += line
        if text.count > 40_000 { text = String(text.suffix(30_000)) }
    }
}

/// 面试助手页：一块玻璃面板放开始按钮、提示灯、计时和字幕预览，下面是准备情况、快捷键和运行日志
struct ListenPage: View {
    @ObservedObject var navigator: Navigator
    @ObservedObject var controller: SessionController
    @ObservedObject var log: LogStore
    @ObservedObject var answers: AnswerEngine
    @ObservedObject var resume: ResumeStore
    @ObservedObject var checkup: Checkup
    @ObservedObject private var hotKeys = HotKeys.shared

    /// 日志区域是否展开(记住上次的选择)
    @AppStorage("showLog") private var showLog = false
    /// 点"下载"时加一，触发系统的翻译语言包下载
    @State private var downloadRequest = 0
    /// 热词表：提高专有名词的转写准确率，下次开始面试时生效
    @AppStorage(Terms.defaultsKey) private var terms = ""
    @AppStorage(LLMModels.key(.qwen, .strong)) private var qwenStrong = ""
    @AppStorage(LLMModels.key(.claude, .strong)) private var claudeStrong = ""
    /// 实际生效的热词数(手动的加两份简历的，去重后)
    private var termCount: Int {
        _ = terms; _ = resume.terms
        return Terms.load().count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 内容可以滚动，日志固定在底部：日志展开后窗口不够高时也不会把整页顶出窗口
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: L("面试助手"), subtitle: L("听对方说话，实时出字幕、译文和回答提示"))
                    VStack(alignment: .leading, spacing: 22) {
                        stagePanel
                        readiness
                        shortcuts
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
            }
            logDrawer
        }
        .onAppear {
            checkup.refresh()
            if CommandLine.arguments.contains("--show-log") { showLog = true }
        }
        .modifier(TranslationDownload(request: downloadRequest, mode: controller.mode) {
            controller.translationNeedsDownload = false
        })
    }

    // MARK: 台口

    private var stagePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                TallyLamp(on: controller.isRunning)
                Text(controller.isRunning ? controller.status : (controller.isBusy ? controller.status : L("待机")))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.timecode(navigator.runningSince.map { context.date.timeIntervalSince($0) } ?? 0))
                        .font(.system(size: 22, weight: .light).monospacedDigit())
                        .foregroundStyle(controller.isRunning ? Theme.ink : Theme.muted)
                }
            }

            // 字幕预览：和悬浮窗里显示的是同一份内容
            VStack(alignment: .leading, spacing: 8) {
                if controller.lines.isEmpty {
                    Text(controller.isRunning ? L("正在听…") : L("开始后，对方说的话会出现在这里和悬浮窗里。"))
                        .font(Theme.script(19))
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(controller.lines.suffix(2)) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            if !controller.mode.translates {
                                Text(line.source).font(Theme.script(19)).foregroundStyle(Theme.ink).lineLimit(2)
                            } else {
                                Text(line.source).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            if !line.translation.isEmpty {
                                Text(line.translation).font(Theme.script(19)).foregroundStyle(Theme.ink).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .bottomLeading)

            Rectangle().fill(Theme.line).frame(height: 1)

            HStack(spacing: 16) {
                LanguageSwapControl(mode: $controller.mode)
                    .disabled(controller.isRunning || controller.isBusy)

                Toggle(L("实时答案"), isOn: $answers.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .foregroundStyle(Theme.ink)

                Spacer()

                Button(controller.isRunning ? L("结束") : L("开始面试")) {
                    Task {
                        if controller.isRunning { await controller.stop() } else { await controller.start() }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(live: controller.isRunning, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy)
            }
        }
        .stage(padding: 22)
    }

    static func timecode(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval), 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    // MARK: 准备情况

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRule(title: L("准备情况")).padding(.bottom, 8)
            VStack(spacing: 0) {
            row(L("转写线路"), controller.line.title, good: true) {
                Button(L("更改")) { open("lines") }.buttonStyle(LinkButtonStyle())
            }
            row(L("大模型"), L("%@，写答案用 %@", "\(answers.llmLine == .qwen ? L("通义千问") : "Claude")", "\(LLMModels.name(answers.llmLine, .strong))"),
                good: KeyStore.has(answers.llmLine.keyAccount)) {
                Button(L("更改")) { open("lines") }.buttonStyle(LinkButtonStyle())
            }
            row(L("简历"), ResumeSlot.allCases.map { L("%@%@", $0.title, resume.texts[$0] == nil ? L("未导入") : L("已导入")) }.joined(separator: L("，"))
                + L("，热词 %@ 个", "\(termCount)"), good: !resume.texts.isEmpty) {
                Button(L("管理")) { navigator.page = .resume }.buttonStyle(LinkButtonStyle())
            }
            jdRow
            ForEach(checkup.problems, id: \.self) { problem in
                row(L("需要处理"), problem, good: false) {
                    Button(L("去处理")) { open("checkup") }.buttonStyle(LinkButtonStyle())
                }
            }
            if controller.translationNeedsDownload && controller.mode.translates {
                row(L("翻译语言包"), L("还没有安装，现在只能转写"), good: false) {
                    Button(L("下载")) {
                        downloadRequest += 1
                    }
                    .buttonStyle(LinkButtonStyle())
                }
            }
            }
            .groupedRows()
        }
    }

    /// 岗位描述：每场面试前贴进来，开始面试时交给答案生成；不保存，关掉 app 就清空
    private var jdRow: some View {
        GroupedRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Circle().fill(resume.jd.isEmpty ? Theme.muted.opacity(0.5) : Theme.good).frame(width: 7, height: 7)
                    Text(L("岗位描述")).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        .frame(width: L10n.shared.isSource ? 76 : 150, alignment: .leading)
                    Text(resume.jd.isEmpty ? L("可以不填，填了回答会更贴近岗位") : L("已填写 %@ 字", "\(resume.jd.count)"))
                        .font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    if !resume.jd.isEmpty && !controller.isRunning {
                        Button(L("清空")) { resume.jd = "" }.buttonStyle(LinkButtonStyle())
                    }
                }
                ZStack(alignment: .topLeading) {
                    if resume.jd.isEmpty {
                        Text(L("把这次面试的岗位描述(JD)粘贴到这里。只在这次打开 app 期间有效，关掉 app 就清空。"))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted.opacity(0.8))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $resume.jd)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                }
                .frame(height: 84)
                .padding(.leading, 19)
                .disabled(controller.isRunning)
                .help(controller.isRunning ? L("面试进行中，岗位描述已经交给答案生成，结束后可以修改") : "")
            }
        }
    }

    private func open(_ tab: String) {
        UserDefaults.standard.set(tab, forKey: "settingsTab")
        checkup.refresh()
        navigator.page = .settings
    }

    private func row(_ title: String, _ value: String, good: Bool, @ViewBuilder action: () -> some View) -> some View {
        GroupedRow {
            HStack(spacing: 12) {
                Circle().fill(good ? Theme.good : Theme.warn).frame(width: 7, height: 7)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(width: L10n.shared.isSource ? 76 : 150, alignment: .leading)
                Text(value).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                action()
            }
        }
    }

    // MARK: 快捷键

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionRule(title: L("面试中用得到的快捷键"))
            FlowLayout(spacing: 18) {
                ForEach(HotKeyAction.allCases) { action in
                    HStack(spacing: 6) {
                        KeyCap(text: hotKeys.display(action))
                        Text(action.title).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Text(L("开始后悬浮窗出现，这个窗口收进程序坞；结束后恢复。"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: 运行日志

    private var logDrawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showLog.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showLog ? 90 : 0)).font(.system(size: 10, weight: .semibold))
                    Text(L("运行日志")).font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 28)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showLog ? L("收起日志") : L("展开日志"))

            if showLog {
                // 新日志进来时滚到最底下，最后一行下面留出边距，不会被窗口底边切掉
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(log.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.ink.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Color.clear.frame(height: 16).id("end")
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 4)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: log.text) {
                        // 等这一轮布局完成再滚，否则新内容的高度还没算进去，会差最后几行
                        DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .frame(height: 190)
            }
        }
        .background(.bar)
    }
}

/// 下载系统翻译语言包(macOS 26 起才用系统翻译；更早的系统用大模型翻译，不需要下载)
private struct TranslationDownload: ViewModifier {
    let request: Int
    let mode: LanguageMode
    let done: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.modifier(Downloader(request: request, mode: mode, done: done))
        } else {
            content
        }
    }

    @available(macOS 26, *)
    private struct Downloader: ViewModifier {
        let request: Int
        let mode: LanguageMode
        let done: () -> Void
        @State private var config: TranslationSession.Configuration?

        func body(content: Content) -> some View {
            content
                .onChange(of: request) {
                    config = TranslationSession.Configuration(source: mode.sourceLanguage, target: mode.targetLanguage)
                }
                .translationTask(config) { session in
                    do {
                        try await session.prepareTranslation()
                        done()
                        Log.write("翻译语言包已就绪，下次开始面试时生效")
                    } catch {
                        Log.write("翻译语言包下载未完成：\(error)")
                    }
                }
        }
    }
}

/// 听译方向：左边「自动」只转写不翻译；右边「英文 ⇄ 中文」两种语言位置固定，
/// 中间上下两支箭头只亮当前方向那支。点右边：从自动切过来时用上次的方向，已经在翻译时互换方向。
struct LanguageSwapControl: View {
    @Binding var mode: LanguageMode
    @Environment(\.isEnabled) private var enabled
    /// 上次用的翻译方向，从自动切回翻译时沿用
    @AppStorage("lastTranslateMode") private var lastTranslate = LanguageMode.enToZh.rawValue

    private var auto: Bool { mode == .auto }
    private var forward: Bool { mode == .enToZh }

    var body: some View {
        HStack(spacing: 0) {
            Button { select(.auto) } label: {
                Text(L("自动"))
                    .font(.system(size: 14, weight: auto ? .semibold : .regular))
                    .foregroundStyle(auto && enabled ? Theme.accent : Theme.muted)
                    .fixedSize()
                    .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("自动识别中英文，只转写不翻译"))
            .accessibilityLabel(LanguageMode.auto.title)
            .accessibilityAddTraits(auto ? .isSelected : [])

            Rectangle().fill(Theme.line).frame(width: 1, height: 16)

            Button(action: translateTapped) {
                HStack(spacing: 10) {
                    label(L("英文"), active: !auto && forward)
                    VStack(spacing: 4) {
                        harpoon(.right, lit: !auto && forward)
                        harpoon(.left, lit: !auto && !forward)
                    }
                    label(L("中文"), active: !auto && !forward)
                }
                .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(auto ? L("切换到翻译") : L("互换翻译方向"))
            .accessibilityLabel(auto ? L("翻译") : mode.title)
            .accessibilityHint(auto ? L("切换到翻译") : L("互换翻译方向"))
        }
        .capsuleGlass()
        .opacity(enabled ? 1 : 0.6)
    }

    /// 当前方向的源语言加粗；自动模式下两边都是常规字重、浅色
    private func label(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 14, weight: active ? .semibold : .regular))
            .foregroundStyle(auto ? Theme.muted : Theme.ink)
            .fixedSize()
    }

    private func harpoon(_ direction: Harpoon.Direction, lit: Bool) -> some View {
        Harpoon(direction: direction)
            .stroke(lit && enabled ? Theme.accent : Theme.muted.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 5)
    }

    private func translateTapped() {
        if auto {
            select(LanguageMode(rawValue: lastTranslate) ?? .enToZh)
        } else {
            select(forward ? .zhToEn : .enToZh)
        }
    }

    private func select(_ new: LanguageMode) {
        withAnimation(.easeInOut(duration: 0.2)) { mode = new }
        LanguageMode.saved = new
        if new != .auto { lastTranslate = new.rawValue }
    }
}

/// 只有一侧倒钩的半箭头（⇌ 那种）：朝右的倒钩在上，朝左的倒钩在下，两支叠起来像一对互换箭头。
struct Harpoon: Shape {
    enum Direction { case left, right }
    var direction: Direction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.height * 1.2, y: rect.minY))
        case .left:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.height * 1.2, y: rect.maxY))
        }
        return path
    }
}
