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

/// 主窗口：开始和结束会话，调整悬浮窗
struct ControlView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: OverlaySettings
    @ObservedObject var log: LogStore
    @ObservedObject var answers: AnswerEngine
    @ObservedObject var resume: ResumeStore
    @State private var llmKeyInput = ""
    @State private var llmKeySaved = false

    @State private var showingResumeManager = false
    /// 日志区域是否展开(记住上次的选择)
    @AppStorage("showLog") private var showLog = true

    /// 收起日志时把窗口缩到刚好放下控件，展开时恢复高度；窗口顶边保持不动
    private func resizeWindowForLog() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "面试助手" }),
                  let content = window.contentView else { return }
            let target = showLog ? max(content.fittingSize.height, 680) : content.fittingSize.height
            var frame = window.frame
            let delta = target - window.contentLayoutRect.height
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true, animate: true)
        }
    }
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var keyInput = ""
    @State private var keySaved = false
    /// 热词表：提高专有名词的转写准确率，下次开始听译时生效
    @AppStorage(Terms.defaultsKey) private var terms = ""
    /// 实际生效的热词数(手动的加两份简历的，去重后)
    private var termCount: Int {
        _ = terms; _ = resume.terms
        return Terms.load().count
    }
    /// 阿里云接入地址，留空用默认地址(控制台给了专属地址时填这里)
    @AppStorage(AliyunASR.endpointDefaultsKey) private var aliyunEndpoint = ""

    private func refreshKeyState() {
        keyInput = ""
        keySaved = controller.line.keyAccount.map(KeyStore.has) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("听译方向", selection: $controller.mode) {
                    ForEach(LanguageMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 240)
                .disabled(controller.isRunning || controller.isBusy)

                Button(controller.isRunning ? "结束" : "开始听译") {
                    Task {
                        if controller.isRunning { await controller.stop() } else { await controller.start() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy)

                Text(controller.status).foregroundStyle(.secondary)
            }

            HStack {
                Picker("转写线路", selection: $controller.line) {
                    ForEach(ASRLine.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 300)
                .disabled(controller.isRunning || controller.isBusy)

                if let account = controller.line.keyAccount {
                    SecureField(keySaved ? "已保存，重新输入可替换" : "粘贴 API Key", text: $keyInput)
                        .frame(width: 200)
                    Button("保存") {
                        keySaved = KeyStore.set(keyInput, for: account) && !keyInput.isEmpty
                        keyInput = ""
                        Log.write(keySaved ? "API Key 已保存" : "API Key 已清除")
                    }
                    Text(keySaved ? "密钥已保存" : "未填密钥").foregroundStyle(keySaved ? .green : .orange)
                }
            }
            .onAppear { refreshKeyState() }
            .onChange(of: controller.line) { refreshKeyState() }

            if controller.line == .aliyun {
                HStack {
                    Text("接入地址").foregroundStyle(.secondary)
                    TextField(AliyunASR.defaultEndpoint, text: $aliyunEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .disabled(controller.isRunning)
                }
                .font(.caption)
            }

            Divider()

            HStack {
                Toggle("实时答案", isOn: $answers.enabled)
                Picker("大模型", selection: $answers.llmLine) {
                    ForEach(LLMLine.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 300)
                .disabled(controller.isRunning)
                if answers.llmLine == .claude {
                    SecureField(llmKeySaved ? "已保存，重新输入可替换" : "粘贴 Anthropic API Key", text: $llmKeyInput)
                        .frame(width: 180)
                    Button("保存") {
                        llmKeySaved = KeyStore.set(llmKeyInput, for: LLMLine.claude.keyAccount) && !llmKeyInput.isEmpty
                        llmKeyInput = ""
                    }
                }
            }
            .onAppear { llmKeySaved = KeyStore.has(LLMLine.claude.keyAccount) }

            HStack {
                Button("简历与热词…") { showingResumeManager = true }
                Text(ResumeSlot.allCases.map { "\($0.title)\(resume.texts[$0] == nil ? "未导入" : "已导入")" }.joined(separator: "，")
                     + "，热词 \(termCount) 个")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌃⌥A 回答上一句，⌃⌥X 关闭答案").font(.caption).foregroundStyle(.secondary)
            }
            // 调试用：启动后直接打开管理界面，方便截图检查
            .onAppear { if CommandLine.arguments.contains("--show-resume-manager") { showingResumeManager = true } }
            .sheet(isPresented: $showingResumeManager) {
                ResumeManagerView(resume: resume, answers: answers, locked: controller.isRunning) {
                    showingResumeManager = false
                }
            }

            if controller.translationNeedsDownload {
                HStack {
                    Text("翻译语言包未安装，当前只能转写。")
                    Button("下载翻译语言包") {
                        downloadConfig = TranslationSession.Configuration(source: controller.mode.sourceLanguage,
                                                                          target: controller.mode.targetLanguage)
                    }
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Toggle("显示悬浮窗", isOn: $settings.visible)
                    Toggle("共享和截屏时隐藏", isOn: $settings.hideFromSharing)
                }
                GridRow {
                    Toggle("显示原文", isOn: $settings.showSource)
                    Toggle("鼠标穿透", isOn: $settings.clickThrough)
                }
                GridRow {
                    Toggle("录制麦克风(会后处理用)", isOn: $controller.recordMic)
                        .disabled(controller.isRunning)
                    Stepper("显示 \(settings.maxLines) 段", value: $settings.maxLines, in: 1...8)
                }
                GridRow {
                    Slider(value: $settings.fontSize, in: 12...36) { Text("字号 \(Int(settings.fontSize))") }
                    // 从 0 开始，滑块位置和百分比才对得上
                    Slider(value: $settings.opacity, in: 0...1) {
                        Text("背景不透明度 \(Int((settings.opacity * 100).rounded()))%")
                    }
                }
            }

            HStack {
                Text("快捷键：⌃⌥H 显示或隐藏悬浮窗，⌃⌥T 切换鼠标穿透。悬浮窗可直接拖动，拖边缘可调整大小。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出应用") { NSApp.terminate(nil) }
            }

            HStack(spacing: 4) {
                Button {
                    showLog.toggle()
                    resizeWindowForLog()
                } label: {
                    Label("日志", systemImage: showLog ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showLog ? "收起日志" : "展开日志")
                Spacer()
            }

            if showLog {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: log.text) { proxy.scrollTo("end") }
            }
            .frame(minHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: showLog ? 600 : nil, alignment: .top)
        // 上次是收起状态时，启动后也把窗口缩到合适的高度
        .onAppear { if !showLog { resizeWindowForLog() } }
        .translationTask(downloadConfig) { session in
            do {
                try await session.prepareTranslation()
                controller.translationNeedsDownload = false
                Log.write("翻译语言包已就绪，下次开始听译时生效")
            } catch {
                Log.write("翻译语言包下载未完成：\(error)")
            }
        }
    }
}
