import SwiftUI
import UniformTypeIdentifiers

/// 简历与热词管理：导入、更换、清除两份简历，查看和编辑每份简历带来的热词，以及手动添加的热词和岗位描述。
struct ResumeManagerView: View {
    @ObservedObject var resume: ResumeStore
    @ObservedObject var answers: AnswerEngine
    let locked: Bool          // 听译进行中不允许改
    let close: () -> Void
    @AppStorage(Terms.defaultsKey) private var manualTerms = ""

    private var manualList: [String] { Terms.split(manualTerms) }
    private var totalCount: Int { Terms.load().count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("简历与热词").font(.title3.weight(.semibold))
                Spacer()
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("英文面试优先用英文简历，中文面试优先用中文简历；只导入了一份时两种面试都用它。热词用来提高转写对专有名词的准确率，改动在下次开始听译时生效。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(ResumeSlot.allCases) { slot in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(resume.summary(slot)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button(resume.texts[slot] == nil ? "导入…" : "更换…") { importResume(slot) }
                                    Button("清除") { resume.clear(slot) }
                                        .disabled(resume.texts[slot] == nil)
                                }
                                if resume.texts[slot] != nil {
                                    HStack {
                                        Text("这份简历的热词").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Button(resume.analyzing.contains(slot) ? "正在抽取…" : "重新抽取") { extract(slot) }
                                            .controlSize(.small)
                                            .disabled(resume.analyzing.contains(slot))
                                    }
                                    TermChips(terms: resume.terms[slot] ?? [], locked: locked) {
                                        resume.setTerms(slot, $0)
                                    }
                                }
                            }
                            .padding(6)
                        } label: {
                            Text(slot.title).font(.headline)
                        }
                        .disabled(locked)
                    }

                    GroupBox {
                        TermChips(terms: manualList, locked: locked) {
                            manualTerms = $0.joined(separator: ", ")
                        }
                        .padding(6)
                    } label: {
                        Text("手动添加的热词").font(.headline)
                    }
                    .disabled(locked)

                    GroupBox {
                        TextEditor(text: $resume.jd)
                            .font(.system(size: 12))
                            .frame(height: 90)
                            .padding(4)
                    } label: {
                        Text("岗位描述(JD，可选)").font(.headline)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Text("实际生效的热词共 \(totalCount) 个(去重后，上限 100 个)")
                    .font(.caption).foregroundStyle(totalCount >= 100 ? .orange : .secondary)
                Spacer()
                if locked { Text("听译进行中，结束后才能修改").font(.caption).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 640, height: 640)
    }

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
                Text("还没有热词").font(.caption).foregroundStyle(.tertiary)
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
                            .help("删除这个热词")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                }
            }
            HStack {
                TextField("添加热词，多个用逗号分隔", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("添加", action: add).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                if !terms.isEmpty {
                    Button("全部删除") { onChange([]) }
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
