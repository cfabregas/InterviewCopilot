import SwiftUI

/// "检测新模型"：列出账号现在能调通的通义千问模型和各自的首字延迟，由用户决定换不换
struct ModelCheckView: View {
    let close: () -> Void
    @AppStorage(LLMModels.key(.qwen, .fast)) private var fast = ""
    @AppStorage(LLMModels.key(.qwen, .strong)) private var strong = ""
    @State private var results: [ModelProbe.Result] = []
    @State private var checking = false
    @State private var message = ""

    private func current(_ tier: LLMTier) -> String { LLMModels.name(.qwen, tier) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测新模型").font(.headline)
            Text("逐个试调版本号不低于当前的通义千问模型，只列出这个账号现在能调通的。首字延迟是单次测量，会有波动。")
                .font(.caption).foregroundStyle(.secondary)
            Text("当前：快档 \(current(.fast))，强档 \(current(.strong))")

            if checking {
                HStack { ProgressView().controlSize(.small); Text("正在试调，大约需要十几秒…") }
            } else if !message.isEmpty {
                Text(message).foregroundStyle(.secondary)
            }

            if !results.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("模型"); Text("首字延迟"); Text(""); Text("")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(results) { result in
                        GridRow {
                            Text(result.model).font(.system(.body, design: .monospaced))
                            Text("\(result.firstTokenMs) 毫秒").monospacedDigit()
                            use(result, .fast)
                            use(result, .strong)
                        }
                    }
                }
            }

            Text("快档用于实时翻译、判断问题和抽取热词，越快越好；强档用于写答案和会后复盘。换代后建议先用一段录音试一遍再上真实面试。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(results.isEmpty ? "开始检测" : "重新检测") { check() }.disabled(checking)
                Spacer()
                Button("完成", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { check() }
    }

    @ViewBuilder
    private func use(_ result: ModelProbe.Result, _ tier: LLMTier) -> some View {
        if current(tier) == result.model {
            Text("当前\(tier.title)").foregroundStyle(.green)
        } else {
            Button("设为\(tier.title)") {
                let value = result.model == LLMModels.defaultName(.qwen, tier) ? "" : result.model
                if tier == .fast { fast = value } else { strong = value }
                Log.write("通义千问\(tier.title)模型改为 \(result.model)")
            }
        }
    }

    private func check() {
        guard let key = KeyStore.get(LLMLine.qwen.keyAccount) else {
            message = "还没有填写阿里云密钥，无法检测。"
            return
        }
        checking = true
        message = ""
        Task {
            let found = await ModelProbe.run(apiKey: key)
            results = found
            checking = false
            let newest = found.map(\.version).max() ?? 0
            let mine = LLMTier.allCases.compactMap { ModelProbe.parse(current($0))?.version }.max() ?? 0
            if found.isEmpty { message = "没有调通任何模型，请检查密钥和网络。" }
            else if newest > mine { message = "发现更新的版本，可以在下面选择。" }
            else { message = "没有发现比当前更新的可用模型。" }
        }
    }
}
