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
                            Text(line.source).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
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
                SlidingPicker(selection: $controller.mode, options: LanguageMode.allCases.map { ($0, $0.title) })
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
            ForEach(checkup.problems, id: \.self) { problem in
                row(L("需要处理"), problem, good: false) {
                    Button(L("去处理")) { open("checkup") }.buttonStyle(LinkButtonStyle())
                }
            }
            if controller.translationNeedsDownload {
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
