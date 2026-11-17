import AVFoundation
import SwiftUI
import Translation

/// 设置页：线路与密钥、悬浮窗、快捷键、权限自检
struct SettingsView: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: OverlaySettings
    @ObservedObject var answers: AnswerEngine
    @ObservedObject var resume: ResumeStore
    @ObservedObject var checkup: Checkup
    @AppStorage("settingsTab") private var tab = "lines"

    private let tabs = [("lines", L("线路与密钥")), ("overlay", L("悬浮窗")), ("hotkeys", L("快捷键")), ("checkup", L("权限自检"))]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L("设置"), subtitle: L("线路、密钥、悬浮窗、快捷键和权限")) {
                Picker("", selection: $tab) {
                    ForEach(tabs, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)
            }
            Group {
                switch tab {
                case "overlay": OverlaySettingsPane(controller: controller, settings: settings)
                case "hotkeys": HotKeySettings()
                case "checkup": CheckupPane(checkup: checkup, resume: resume)
                default: LinesSettings(controller: controller, answers: answers)
                }
            }
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 两列的分组表单：窗口宽的时候左右并排，右边不会留下一大片空白
private struct TwoColumnForm<Left: View, Right: View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form { left() }.formStyle(.grouped).frame(maxWidth: .infinity)
            Form { right() }.formStyle(.grouped).frame(maxWidth: .infinity)
        }
    }
}

/// 一个密钥输入行：不回显已保存的内容，重新输入即替换，留空保存即清除。
/// 同一个密钥可能在几处出现(比如阿里云密钥同时给转写和大模型用)，保存后通知其他行刷新。
private struct KeyRow: View {
    static let changed = Notification.Name("KeyRow.changed")
    let title: String
    let account: String
    @State private var input = ""
    @State private var saved = false

    var body: some View {
        // 不用 LabeledContent：标签长一点时它会把输入框挤到下一行
        HStack(spacing: 8) {
            Text(title).fixedSize().padding(.trailing, 4)
            HStack(spacing: 8) {
                SecureField("", text: $input, prompt: Text(saved ? L("已保存，重新输入可替换") : L("粘贴 API Key")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(minWidth: 120, maxWidth: .infinity)
                Button(input.isEmpty && saved ? L("清除") : L("保存")) {
                    saved = KeyStore.set(input, for: account) && !input.isEmpty
                    input = ""
                    Log.write("\(title)的密钥\(saved ? "已保存" : "已清除")")
                    NotificationCenter.default.post(name: Self.changed, object: account)
                }
                .disabled(input.isEmpty && !saved)
                Text(saved ? L("已保存") : L("未填")).foregroundStyle(saved ? Theme.good : Theme.warn)
                    .frame(minWidth: 44, alignment: .leading).fixedSize()
            }
        }
        .onAppear { saved = KeyStore.has(account) }
        .onReceive(NotificationCenter.default.publisher(for: Self.changed)) { note in
            if note.object as? String == account { saved = KeyStore.has(account) }
        }
    }
}

private struct LinesSettings: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var answers: AnswerEngine
    @AppStorage(LLMModels.key(.qwen, .fast)) private var qwenFast = ""
    @AppStorage(LLMModels.key(.qwen, .strong)) private var qwenStrong = ""
    @AppStorage(LLMModels.key(.claude, .fast)) private var claudeFast = ""
    @AppStorage(LLMModels.key(.claude, .strong)) private var claudeStrong = ""
    @AppStorage(AliyunASR.endpointDefaultsKey) private var aliyunEndpoint = ""
    @AppStorage("autoPostProcess") private var autoPost = true
    @State private var showingModelCheck = false

    /// 当前转写线路要用到的密钥；自动线路会在填了密钥的云端线路里挑最快的，所以三个都列出来
    private var asrKeyLines: [ASRLine] {
        switch controller.line {
        case .local: return []
        case .auto: return [.aliyun, .deepgram, .assemblyai]
        default: return [controller.line]
        }
    }

    private func keyTitle(_ line: ASRLine) -> String {
        switch line {
        case .aliyun: return L("阿里云百炼")
        case .deepgram: return "Deepgram"
        case .assemblyai: return "AssemblyAI"
        default: return line.title
        }
    }

    var body: some View {
        TwoColumnForm {
            Section {
                Picker(L("转写线路"), selection: $controller.line) {
                    ForEach(ASRLine.allCases) { Text($0.title).tag($0) }
                }
                ForEach(asrKeyLines) { line in
                    KeyRow(title: L("%@ 密钥", keyTitle(line)), account: line.keyAccount ?? "")
                }
                if controller.line == .local {
                    Text(L("本地线路在本机离线转写，不需要密钥。")).font(.caption).foregroundStyle(.secondary)
                }
                if asrKeyLines.contains(.aliyun) {
                    TextField(L("阿里云接入地址"), text: $aliyunEndpoint, prompt: Text(AliyunASR.defaultEndpoint))
                }
                Toggle(L("录制麦克风(会后处理用)"), isOn: $controller.recordMic)
            } header: {
                Text(L("转写"))
            } footer: {
                Text(L("密钥明文存在本机应用数据目录。")).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(controller.isRunning || controller.isBusy)

            Section(L("会后")) {
                Toggle(L("结束后自动整理(重新转写、翻译、问答评价和纪要)"), isOn: $autoPost)
                if autoPost {
                    // 转写那边已经列出 AssemblyAI 密钥时不再重复
                    if !asrKeyLines.contains(.assemblyai) {
                        KeyRow(title: L("%@ 密钥", "AssemblyAI"), account: ASRLine.assemblyai.keyAccount ?? "")
                    }
                    Text(L("会后用 AssemblyAI 重新转写整场录音，区分说话人更准；不填就用本机离线转写。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } right: {
            Section(L("大模型")) {
                Picker(L("线路"), selection: $answers.llmLine) {
                    ForEach(LLMLine.allCases) { Text($0.title).tag($0) }
                }
                if answers.llmLine == .qwen {
                    KeyRow(title: L("%@ 密钥", L("阿里云百炼")), account: LLMLine.qwen.keyAccount)
                } else {
                    KeyRow(title: L("%@ 密钥", "Anthropic"), account: LLMLine.claude.keyAccount)
                }
                TextField(L("快档模型"), text: answers.llmLine == .qwen ? $qwenFast : $claudeFast,
                          prompt: Text(LLMModels.defaultName(answers.llmLine, .fast)))
                TextField(L("强档模型"), text: answers.llmLine == .qwen ? $qwenStrong : $claudeStrong,
                          prompt: Text(LLMModels.defaultName(answers.llmLine, .strong)))
                HStack {
                    Text(answers.llmLine == .qwen ? L("阿里云密钥和转写共用，也用于模拟面试的语音合成。模型名留空用默认值。") : L("模型名留空用默认值"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if answers.llmLine == .qwen { Button(L("检测新模型…")) { showingModelCheck = true } }
                }
            }
            .disabled(controller.isRunning)
        }
        .onAppear { if CommandLine.arguments.contains("--show-model-check") { showingModelCheck = true } }
        .sheet(isPresented: $showingModelCheck) { ModelCheckView { showingModelCheck = false } }
    }
}

private struct OverlaySettingsPane: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var settings: OverlaySettings

    var body: some View {
        TwoColumnForm {
            Section(L("显示")) {
                Toggle(L("面试进行中显示悬浮窗"), isOn: $settings.visible)
                Toggle(L("显示原文"), isOn: $settings.showSource)
                Stepper(L("显示最近 %@ 段", "\(settings.maxLines)"), value: $settings.maxLines, in: 1...8)
                Slider(value: $settings.fontSize, in: 12...36) { Text(L("字号 %@", "\(Int(settings.fontSize))")) }
                // 从 0 开始，滑块位置和百分比才对得上
                Slider(value: $settings.opacity, in: 0...1) {
                    Text(L("背景不透明度 %@%%", "\(Int((settings.opacity * 100).rounded()))"))
                }
            }
        } right: {
            Section(L("交互")) {
                Toggle(L("共享和截屏时隐藏"), isOn: $settings.hideFromSharing)
                Toggle(L("鼠标穿透(点击落到下面的窗口)"), isOn: $settings.clickThrough)
                Text(L("悬浮窗在开始面试后出现，结束后收起。关闭鼠标穿透后可以直接拖动，拖边缘可调整大小。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HotKeySettings: View {
    @ObservedObject private var hotKeys = HotKeys.shared
    @State private var recording: HotKeyAction?
    @State private var monitor: Any?
    @State private var message = ""

    var body: some View {
        TwoColumnForm {
            Section(L("全局快捷键(在任何应用里都有效)")) {
                ForEach(HotKeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Button(recording == action ? L("按下新的组合键…") : hotKeys.display(action)) { toggleRecording(action) }
                            .frame(minWidth: 130)
                        Button(L("恢复默认")) {
                            stopRecording()
                            report(hotKeys.set(action.defaultCombo, for: action), action.defaultCombo)
                        }
                        .disabled(hotKeys.combos[action] == action.defaultCombo)
                    }
                }
            }
        } right: {
            Section(L("怎么改")) {
                Text(message.isEmpty ? L("点组合键按钮后按下新的组合，必须带 ⌃、⌥ 或 ⌘；按 Esc 取消。") : message)
                    .foregroundStyle(message.isEmpty ? Color.secondary : Color.orange)
                Text(L("面试进行中这些快捷键在任何应用里都能用，主窗口不需要在前台。"))
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func report(_ clash: HotKeyAction?, _ combo: KeyCombo) {
        message = clash.map { L("%@ 已经用于\"%@\"，没有修改。", "\(combo.display)", "\($0.title)") } ?? ""
    }

    private func toggleRecording(_ action: HotKeyAction) {
        if recording == action {
            stopRecording()
            return
        }
        stopRecording()
        recording = action
        message = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {   // Esc
                stopRecording()
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                message = L("组合键必须带 ⌃、⌥ 或 ⌘。")
                return nil
            }
            stopRecording()
            report(hotKeys.set(combo, for: action), combo)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

// MARK: - 权限自检

/// 启动时和设置页里检查：麦克风权限、系统声音采集、密钥、翻译语言包
@MainActor
final class Checkup: ObservableObject {
    enum State: Equatable {
        case ok(String), warning(String), failed(String), unknown(String)

        var text: String {
            switch self {
            case .ok(let text), .warning(let text), .failed(let text), .unknown(let text): return text
            }
        }
    }

    @Published private(set) var microphone: State = .unknown(L("未检查"))
    @Published private(set) var systemAudio: State = .unknown(L("还没测试"))
    @Published private(set) var keys: State = .unknown(L("未检查"))
    @Published private(set) var translation: State = .unknown(L("未检查"))
    @Published private(set) var testingAudio = false
    /// 真实面试进行时不能测系统声音(会抢采集)
    var sessionRunning: () -> Bool = { false }

    /// 需要用户处理的问题，显示在主窗口
    var problems: [String] {
        var list: [String] = []
        if case .failed(let text) = microphone { list.append(text) }
        if case .warning(let text) = microphone { list.append(text) }
        if case .failed(let text) = systemAudio { list.append(text) }
        if case .failed(let text) = keys { list.append(text) }
        return list
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .ok(L("已允许"))
        case .notDetermined: microphone = .warning(L("麦克风还没有授权：录制自己的发言和模拟面试都需要"))
        default: microphone = .failed(L("麦克风权限被拒绝：请在系统设置里允许千人千面"))
        }
        let names = [(L("阿里云"), ASRLine.aliyun.keyAccount), ("Deepgram", ASRLine.deepgram.keyAccount),
                     ("AssemblyAI", ASRLine.assemblyai.keyAccount), ("Anthropic", Optional(LLMLine.claude.keyAccount))]
        let filled = names.filter { $0.1.map(KeyStore.has) ?? false }.map(\.0)
        if filled.isEmpty {
            keys = .failed(L("一个密钥都没有填：只能本地转写，没有答案和复盘"))
        } else if !KeyStore.has(LLMLine.saved.keyAccount) {
            keys = .failed(L("当前大模型线路(%@)没有填密钥：没有答案和复盘", "\(LLMLine.saved.title)"))
        } else {
            keys = .ok(L("已填：") + filled.joined(separator: "、"))
        }
        Task {
            var parts: [String] = []
            var missing = false
            for mode in LanguageMode.allCases {
                switch await AppleTranslator(source: mode.sourceLanguage, target: mode.targetLanguage).prepare() {
                case .ready: parts.append(L("%@ 已安装", "\(mode.title)"))
                case .needsDownload:
                    parts.append(L("%@ 未下载", "\(mode.title)"))
                    missing = true
                case .unsupported: parts.append(L("%@ 系统不支持", "\(mode.title)"))
                }
            }
            translation = missing ? .warning(parts.joined(separator: L("，"))) : .ok(parts.joined(separator: L("，")))
        }
    }

    func requestMicrophone() {
        Task {
            _ = await MicRecorder.requestPermission()
            refresh()
        }
    }

    /// 试着采集两秒系统声音。采集启动不了、或者一直卡着，多半是"系统音频录制"权限没给。
    func testSystemAudio() {
        guard !testingAudio else { return }
        guard !sessionRunning() else {
            systemAudio = .unknown(L("面试进行中，结束后再测"))
            return
        }
        testingAudio = true
        systemAudio = .unknown(L("正在测试(如有权限弹窗请点允许)…"))
        Task {
            let tap = SystemAudioTap()
            final class Outcome: @unchecked Sendable { var error: String?; var started = false; var peak: Float = 0 }
            let outcome = Outcome()
            let finished = await waitUpTo(8) {
                do {
                    _ = try tap.start()
                    outcome.started = true
                    for _ in 0..<10 {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        outcome.peak = max(outcome.peak, tap.takePeak())
                    }
                } catch {
                    outcome.error = "\(error)"
                }
            }
            if outcome.started { tap.stop() }
            if !finished && !outcome.started {
                systemAudio = .failed(L("系统声音采集没有响应：请在系统设置里允许千人千面录制系统音频"))
            } else if let error = outcome.error {
                systemAudio = .failed(L("系统声音采集启动失败：%@", "\(error)"))
            } else if outcome.peak > 0.001 {
                systemAudio = .ok(L("正常，采集到了声音"))
            } else {
                systemAudio = .ok(L("采集已启动，这两秒里电脑没有出声。如果当时正在播放声音，说明权限没给"))
            }
            testingAudio = false
            Log.write("权限自检 · 系统声音：\(systemAudio.text)")
        }
    }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct CheckupPane: View {
    @ObservedObject var checkup: Checkup
    @ObservedObject var resume: ResumeStore

    private func icon(_ state: Checkup.State) -> some View {
        let (name, color): (String, Color) = {
            switch state {
            case .ok: return ("checkmark.circle.fill", .green)
            case .warning: return ("exclamationmark.triangle.fill", .orange)
            case .failed: return ("xmark.circle.fill", .red)
            case .unknown: return ("questionmark.circle", .secondary)
            }
        }()
        return Image(systemName: name).foregroundStyle(color)
    }

    private func row(_ title: String, _ state: Checkup.State, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top) {
            icon(state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(state.text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
    }

    var body: some View {
        TwoColumnForm {
            Section(L("系统权限")) {
                row(L("麦克风"), checkup.microphone) {
                    if case .warning = checkup.microphone { Button(L("请求授权")) { checkup.requestMicrophone() } }
                    Button(L("打开系统设置")) { Checkup.openPrivacy("Privacy_Microphone") }
                }
                row(L("系统声音录制"), checkup.systemAudio) {
                    Button(checkup.testingAudio ? L("测试中…") : L("测试")) { checkup.testSystemAudio() }.disabled(checkup.testingAudio)
                    Button(L("打开系统设置")) { Checkup.openPrivacy("Privacy_AudioCapture") }
                }
            }
            Section {
                HStack {
                    Text(L("系统没有提供查询\"系统声音录制\"权限的办法，只能实际采集一下来判断。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("重新检查")) { checkup.refresh() }
                }
            }
        } right: {
            Section(L("配置")) {
                row(L("密钥"), checkup.keys) { EmptyView() }
                row(L("本地翻译语言包"), checkup.translation) { EmptyView() }
                row(L("简历"), .ok(ResumeSlot.allCases.map { L("%@%@", $0.title, resume.texts[$0] == nil ? L("未导入") : L("已导入")) }.joined(separator: L("，")))) { EmptyView() }
            }
        }
        .onAppear { checkup.refresh() }
    }
}
