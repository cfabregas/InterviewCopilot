import SwiftUI

/// 模拟面试页：开始前选语言、级别和题数；进行中显示当前问题、我的回答和点评
struct MockInterviewView: View {
    @ObservedObject var mock: MockInterview
    @ObservedObject var resume: ResumeStore
    @ObservedObject var navigator: Navigator
    var openReview: (Int64?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L("模拟面试"), subtitle: L("按简历和岗位出题，语音提问，答完有点评和追问")) {
                if mock.isActive, mock.phase != .wrappingUp {
                    Button(L("结束面试")) { mock.end() }.buttonStyle(QuietButtonStyle())
                }
            }
            Group {
                if mock.isActive || mock.phase == .finished { running } else { setup }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
    }

    // MARK: - 开始前

    private func field(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(width: L10n.shared.isSource ? 84 : 170, alignment: .leading)
                control()
                Spacer()
            }
            .padding(.vertical, 9)
            Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("坐下来，像真的一样答一遍。"))
                    .font(Theme.script(24))
                    .foregroundStyle(Theme.onCurtain)
                Text(resumeLine + L("。") + (resume.jd.isEmpty ? L("还没有填岗位描述，填了题目会更贴近岗位。") : L("岗位描述已填写 %@ 字。", "\(resume.jd.count)")))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.onCurtainMuted)
                HStack(spacing: 14) {
                    Button(L("开始模拟面试")) { mock.start() }
                        .buttonStyle(PrimaryButtonStyle(large: true))
                        .keyboardShortcut(.defaultAction)
                    Button(L("管理简历和岗位描述")) { navigator.page = .resume }
                        .buttonStyle(QuietButtonStyle(onCurtain: true))
                    if !mock.status.isEmpty {
                        Text(mock.status).font(.system(size: 13)).foregroundStyle(Theme.cue)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stage(padding: 24)

            VStack(alignment: .leading, spacing: 0) {
                SectionRule(title: L("这一场怎么面")).padding(.bottom, 4)
                field(L("面试语言")) {
                    Picker("", selection: $mock.config.chinese) {
                        Text(L("英文")).tag(false)
                        Text(L("中文")).tag(true)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                field(L("岗位级别")) {
                    Picker("", selection: $mock.config.level) {
                        ForEach(MockConfig.Level.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                field(L("题目数量")) {
                    Stepper(L("%@ 道", "\(mock.config.questionCount)"), value: $mock.config.questionCount, in: 1...12)
                }
                field(L("每题追问")) {
                    Stepper(mock.config.maxFollowUps == 0 ? L("不追问") : L("最多 %@ 轮", "\(mock.config.maxFollowUps)"),
                            value: $mock.config.maxFollowUps, in: 0...2)
                }
                field(L("点评之后")) {
                    Toggle(L("暂停，等我点\"继续\"再问下一个"), isOn: $mock.config.pauseAfterFeedback)
                }
            }
            Text(L("建议戴耳机：外放时麦克风会录到面试官的声音。"))
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
        }
    }

    private var resumeLine: String {
        let slot: ResumeSlot = mock.config.chinese ? .zh : .en
        let other: ResumeSlot = slot == .zh ? .en : .zh
        if resume.texts[slot] != nil { return L("出题用%@", "\(slot.title)") }
        if resume.texts[other] != nil { return L("没有%@，出题改用%@", "\(slot.title)", "\(other.title)") }
        return L("还没有导入简历，只能出通用题")
    }

    // MARK: - 进行中

    private var current: MockTurn? { mock.turns.last }

    private func label(_ turn: MockTurn) -> String {
        L("第 %@ 题，共 %@ 题", "\(turn.number)", "\(max(mock.total, turn.number))") + (turn.followUp > 0 ? L("，追问 %@", "\(turn.followUp)") : "") + L("，") + L(turn.kind)
    }

    private var busy: Bool {
        [.preparing, .reviewing, .wrappingUp, .asking].contains(mock.phase)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TallyLamp(on: mock.phase == .answering)
                    Text(mock.status).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.onCurtain).lineLimit(1)
                    if busy { ProgressView().controlSize(.small).colorScheme(.dark) }
                    Spacer()
                    if let turn = current, mock.phase != .finished {
                        Text(label(turn)).font(.system(size: 12)).foregroundStyle(Theme.onCurtainMuted)
                    }
                }

                if let turn = current, mock.phase != .finished, mock.phase != .wrappingUp {
                    Text(turn.question)
                        .font(Theme.script(21))
                        .foregroundStyle(Theme.onCurtain)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: 760, alignment: .leading)

                    if mock.phase == .answering {
                        ScrollView {
                            Text(mock.liveAnswer.isEmpty ? L("正在听你回答…") : mock.liveAnswer)
                                .font(.system(size: 13))
                                .foregroundStyle(mock.liveAnswer.isEmpty ? Theme.onCurtainMuted : Theme.onCurtain.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 72)
                    }
                } else if mock.phase == .finished {
                    Text(mock.reviewReady ? L("这一场结束了，复盘已经生成。") : L("这一场结束了。"))
                        .font(Theme.script(21)).foregroundStyle(Theme.onCurtain)
                }

                HStack(spacing: 10) {
                    switch mock.phase {
                    case .answering:
                        Button(L("答完了")) { mock.finishAnswer() }
                            .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                        Button(L("重听问题")) { mock.repeatQuestion() }.buttonStyle(QuietButtonStyle(onCurtain: true))
                        Button(L("跳过这题")) { mock.skip() }.buttonStyle(QuietButtonStyle(onCurtain: true))
                    case .asking:
                        Button(L("跳过这题")) { mock.skip() }.buttonStyle(QuietButtonStyle(onCurtain: true))
                    case .waiting:
                        Button(L("继续")) { mock.proceed() }
                            .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                    case .finished:
                        if mock.sessionID != nil {
                            Button(L("打开复盘")) { openReview(mock.sessionID) }
                                .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                        }
                        Button(L("再来一场")) { mock.reset() }.buttonStyle(QuietButtonStyle(onCurtain: true))
                    default:
                        EmptyView()
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stage(padding: 22)

            SectionRule(title: L("已经答过的"))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        let answered = mock.turns.filter { !$0.answer.isEmpty || !$0.feedback.isEmpty }
                        if answered.isEmpty {
                            Text(L("答完第一题后，回答和点评会列在这里。")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        ForEach(answered) { turn in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(label(turn)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                Text(turn.question).font(Theme.script(16)).foregroundStyle(Theme.ink)
                                Text(turn.answer.isEmpty ? L("没有回答") : turn.answer)
                                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                if !turn.feedback.isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Rectangle().fill(Theme.cue).frame(width: 3)
                                        Text(turn.feedback).font(.system(size: 13)).foregroundStyle(Theme.ink).lineSpacing(3)
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: 760, alignment: .leading)
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
