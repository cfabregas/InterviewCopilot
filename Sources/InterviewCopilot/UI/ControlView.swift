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

    private func importResume(_ slot: ResumeSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .rtf,
                                     .init(filenameExtension: "docx"), .init(filenameExtension: "doc"),
                                     .init(filenameExtension: "md")].compactMap { $0 }
        panel.message = "选择\(slot.title)文件(PDF、Word 或纯文本)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try resume.load(from: url, slot: slot)
        } catch {
            Log.write("简历导入失败：\(error)")
            return
        }
        guard let llm = answers.llmLine.makeClient() else {
            Log.write("没有填写\(answers.llmLine.title)的密钥，暂时无法从简历抽取热词")
            return
        }
        Task { await resume.extractTerms(slot, using: llm) }
    }
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var keyInput = ""
    @State private var keySaved = false
    /// 热词表：提高专有名词的转写准确率，下次开始听译时生效
    @AppStorage(Terms.defaultsKey) private var terms = ""
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

            HStack {
                Text("热词").foregroundStyle(.secondary)
                TextField("公司名、产品名、技术名词，逗号分隔(如 Kubernetes, rate limiter, 限流器)", text: $terms)
                    .textFieldStyle(.roundedBorder)
                    .disabled(controller.isRunning)
            }
            .font(.caption)

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

            ForEach(ResumeSlot.allCases) { slot in
                HStack {
                    Text(slot.title).frame(width: 60, alignment: .leading)
                    Button(resume.analyzing.contains(slot) ? "正在分析…" : (resume.texts[slot] == nil ? "导入…" : "更换…")) {
                        importResume(slot)
                    }
                    .disabled(resume.analyzing.contains(slot) || controller.isRunning)
                    Button("清除") { resume.clear(slot) }
                        .disabled(resume.texts[slot] == nil || controller.isRunning)
                    Text(resume.summary(slot)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }
            Text("英文面试优先用英文简历，中文面试优先用中文简历；只导入了一份时两种面试都用它。⌃⌥A 回答上一句，⌃⌥X 关闭答案。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text("岗位描述").foregroundStyle(.secondary).font(.caption)
                TextEditor(text: $resume.jd)
                    .font(.system(size: 11))
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
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
                    Slider(value: $settings.fontSize, in: 12...36) { Text("字号") }
                    Slider(value: $settings.opacity, in: 0.2...1) { Text("背景不透明度") }
                }
            }

            HStack {
                Text("快捷键：⌃⌥H 显示或隐藏悬浮窗，⌃⌥T 切换鼠标穿透。悬浮窗可直接拖动，拖边缘可调整大小。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出应用") { NSApp.terminate(nil) }
            }

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
        .padding(16)
        .frame(minWidth: 720, minHeight: 600)
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
