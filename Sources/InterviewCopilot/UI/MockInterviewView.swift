import SwiftUI

/// 模拟面试窗口：开始前选语言、级别和题数；进行中显示当前问题、我的回答和点评
struct MockInterviewView: View {
    @ObservedObject var mock: MockInterview
    @ObservedObject var resume: ResumeStore
    var openReview: (Int64?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mock.isActive || mock.phase == .finished { running } else { setup }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 520, alignment: .topLeading)
    }

    // MARK: - 开始前

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("模拟面试").font(.title2.bold())
            Text("根据简历和岗位描述出题，面试官语音提问，你用麦克风回答。每题答完有点评，并按你的回答追问。结束后生成和真实面试一样的复盘。")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("面试语言")
                    Picker("", selection: $mock.config.chinese) {
                        Text("英文").tag(false)
                        Text("中文").tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                GridRow {
                    Text("岗位级别")
                    Picker("", selection: $mock.config.level) {
                        ForEach(MockConfig.Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                GridRow {
                    Text("题目数量")
                    Stepper("\(mock.config.questionCount) 道", value: $mock.config.questionCount, in: 1...12)
                }
                GridRow {
                    Text("每题追问")
                    Stepper(mock.config.maxFollowUps == 0 ? "不追问" : "最多 \(mock.config.maxFollowUps) 轮",
                            value: $mock.config.maxFollowUps, in: 0...2)
                }
                GridRow {
                    Text("点评")
                    Toggle("每次点评后暂停，点\"继续\"再问下一个", isOn: $mock.config.pauseAfterFeedback)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(resumeLine)
                Text(resume.jd.isEmpty ? "岗位描述：未填写(在主窗口\"简历与热词\"里填，题目会更贴近岗位)" : "岗位描述：已填写 \(resume.jd.count) 字")
            }
            .font(.callout).foregroundStyle(.secondary)

            HStack {
                Button("开始模拟面试") { mock.start() }
                    .keyboardShortcut(.defaultAction)
                Text(mock.status).foregroundStyle(.orange)
            }
            Text("建议戴耳机：外放时麦克风会录到面试官的声音。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resumeLine: String {
        let slot: ResumeSlot = mock.config.chinese ? .zh : .en
        let other: ResumeSlot = slot == .zh ? .en : .zh
        if resume.texts[slot] != nil { return "简历：使用\(slot.title)" }
        if resume.texts[other] != nil { return "简历：没有\(slot.title)，改用\(other.title)" }
        return "简历：未导入(只能出通用题)"
    }

    // MARK: - 进行中

    private var current: MockTurn? { mock.turns.last }

    private func label(_ turn: MockTurn) -> String {
        "第 \(turn.number)/\(max(mock.total, turn.number)) 题" + (turn.followUp > 0 ? " · 追问 \(turn.followUp)" : "") + " · \(turn.kind)"
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(current.map(label) ?? "模拟面试").font(.headline)
                Spacer()
                if mock.phase == .preparing || mock.phase == .reviewing || mock.phase == .wrappingUp || mock.phase == .asking {
                    ProgressView().controlSize(.small)
                }
                Text(mock.status).foregroundStyle(.secondary)
            }

            if let turn = current, mock.phase != .finished, mock.phase != .wrappingUp {
                Text(turn.question)
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))

                if mock.phase == .answering {
                    ScrollView {
                        Text(mock.liveAnswer.isEmpty ? "正在听…" : mock.liveAnswer)
                            .foregroundStyle(mock.liveAnswer.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                }
            }

            HStack {
                switch mock.phase {
                case .answering:
                    Button("答完了") { mock.finishAnswer() }.keyboardShortcut(.defaultAction)
                    Button("重听问题") { mock.repeatQuestion() }
                    Button("跳过这题") { mock.skip() }
                case .asking:
                    Button("跳过这题") { mock.skip() }
                case .waiting:
                    Button("继续") { mock.proceed() }.keyboardShortcut(.defaultAction)
                case .finished:
                    if mock.reviewReady || mock.sessionID != nil {
                        Button("打开复盘") { openReview(mock.sessionID) }.keyboardShortcut(.defaultAction)
                    }
                    Button("再来一场") { mock.reset() }
                default:
                    EmptyView()
                }
                Spacer()
                if mock.isActive, mock.phase != .wrappingUp {
                    Button("结束面试") { mock.end() }
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(mock.turns.filter { !$0.answer.isEmpty || !$0.feedback.isEmpty }) { turn in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(turn)).font(.caption).foregroundStyle(.secondary)
                                Text(turn.question).fontWeight(.medium)
                                Text(turn.answer.isEmpty ? "(没有回答)" : turn.answer).foregroundStyle(.secondary)
                                if !turn.feedback.isEmpty {
                                    Text("点评：" + turn.feedback)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.14)))
                                }
                            }
                            .textSelection(.enabled)
                            .id(turn.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: mock.turns.last?.feedback) {
                    if let id = mock.turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
    }
}
