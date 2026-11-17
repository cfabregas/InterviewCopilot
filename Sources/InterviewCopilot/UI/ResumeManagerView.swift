import SwiftUI
import UniformTypeIdentifiers

/// 简历管理页：导入、更换、清除两份简历，查看和编辑每份简历带来的热词，以及手动添加的热词和岗位描述。
struct ResumeManagerView: View {
    @ObservedObject var resume: ResumeStore
    @ObservedObject var answers: AnswerEngine
    let locked: Bool          // 面试进行中不允许改
    @AppStorage(Terms.defaultsKey) private var manualTerms = ""

    private var manualList: [String] { Terms.split(manualTerms) }
    private var totalCount: Int { Terms.load().count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L("简历管理"), subtitle: L("答案和题目都从这里来")) {
                Text(locked ? L("面试进行中，结束后才能修改") : L("生效的热词 %@ 个，上限 100 个", "\(totalCount)"))
                    .font(.system(size: 12))
                    .foregroundStyle(locked || totalCount >= 100 ? Theme.warn : Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(L("英文面试优先用英文简历，中文面试优先用中文简历；只导入了一份时两种面试都用它。热词用来提高转写对专有名词的准确率，改动在下次开始面试时生效。"))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .lineSpacing(3)
                        .frame(maxWidth: 720, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // 两份简历左右并排
                    HStack(alignment: .top, spacing: 32) {
                        ForEach(ResumeSlot.allCases) { slot in
                            resumeColumn(slot).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }

                    // 手动热词和岗位描述也左右并排
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionRule(title: L("手动添加的热词"))
                            TermChips(terms: manualList, locked: locked) {
                                manualTerms = $0.joined(separator: ", ")
                            }
                        }
                        .disabled(locked)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 12) {
                            SectionRule(title: L("岗位描述，可以不填"))
                            TextEditor(text: $resume.jd)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .frame(height: 140)
                                .surface(radius: 8, padding: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 一份简历：文件、更换和清除，以及从它抽出来的热词
    private func resumeColumn(_ slot: ResumeSlot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionRule(title: slot.title)
            HStack(spacing: 10) {
                Image(systemName: resume.texts[slot] == nil ? "doc" : "doc.text.fill")
                    .foregroundStyle(resume.texts[slot] == nil ? Theme.muted : Theme.accent)
                Text(resume.summary(slot)).font(.system(size: 13)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(resume.texts[slot] == nil ? L("导入…") : L("更换…")) { importResume(slot) }
                    .buttonStyle(QuietButtonStyle())
                Button(L("清除")) { resume.clear(slot) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(resume.texts[slot] == nil)
            }
            if resume.texts[slot] != nil {
                HStack {
                    Text(L("这份简历的热词")).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(resume.analyzing.contains(slot) ? L("正在抽取…") : L("重新抽取")) { extract(slot) }
                        .buttonStyle(LinkButtonStyle())
                        .disabled(resume.analyzing.contains(slot))
                }
                TermChips(terms: resume.terms[slot] ?? [], locked: locked) {
                    resume.setTerms(slot, $0)
                }
            } else {
                Text(L("还没有导入。导入后会自动从中抽取公司名、项目名和技术名词作为热词。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(locked)
    }

    private func importResume(_ slot: ResumeSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .rtf,
                                     .init(filenameExtension: "docx"), .init(filenameExtension: "doc"),
                                     .init(filenameExtension: "md")].compactMap { $0 }
        panel.message = L("选择%@文件(PDF、Word 或纯文本)", "\(slot.title)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try resume.load(from: url, slot: slot)
        } catch {
            Log.write("简历导入失败：\(error)")
            return
        }
        extract(slot)
    }

    private func extract(_ slot: ResumeSlot) {
        guard let llm = answers.llmLine.makeClient() else {
            Log.write("没有填写\(answers.llmLine.title)的密钥，暂时无法从简历抽取热词")
            return
        }
        Task { await resume.extractTerms(slot, using: llm) }
    }
}

/// 一组热词：每个词一个可删除的标签，下面一个输入框用来添加(可一次粘贴多个，逗号或换行分隔)
struct TermChips: View {
    let terms: [String]
    let locked: Bool
    let onChange: ([String]) -> Void
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if terms.isEmpty {
                Text(L("还没有热词")).font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        HStack(spacing: 3) {
                            Text(term).font(.system(size: 12)).lineLimit(1)
                            Button {
                                onChange(terms.filter { $0 != term })
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(L("删除这个热词"))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                    }
                }
            }
            HStack {
                TextField(L("添加热词，多个用逗号分隔"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(L("添加"), action: add).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                if !terms.isEmpty {
                    Button(L("全部删除")) { onChange([]) }
                }
            }
            .controlSize(.small)
        }
    }

    private func add() {
        var result = terms
        let existing = Set(terms.map { $0.lowercased() })
        for term in Terms.split(input) where !existing.contains(term.lowercased()) && !result.contains(term) {
            result.append(term)
        }
        input = ""
        if result != terms { onChange(result) }
    }
}

/// 从左到右排、放不下就换行的布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (origins, maxWidth, y + rowHeight)
    }
}
