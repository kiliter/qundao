import QundaoCore
import SwiftUI

/// 编辑期间保留草稿，避免每次按键都改动正在执行的模型任务。
struct ModelPromptSettings: View {
  @Environment(AppStore.self) private var store
  @Environment(\.pageActive) private var pageActive
  @State private var summary = ""
  @State private var jev = ""
  @State private var baselineSummary = ""
  @State private var baselineJev = ""
  @State private var loaded = false
  @State private var notice = ""
  @State private var failed = false

  private var isDirty: Bool { summary != baselineSummary || jev != baselineJev }
  private var validationError: String? {
    do { try ModelPrompts.validate(summary: summary, jev: jev); return nil }
    catch { return error.localizedDescription }
  }

  var body: some View {
    P5PaperCard {
      P5SectionTitle("模型系统提示词")
      Text("分别调整摘要的表达方式和 Jev 的判断标准。编辑后点击保存；留空使用默认提示词。")
        .font(.caption).foregroundStyle(.secondary)
      ModelPromptEditor(title: "AI 摘要 · CPA", text: $summary,
        defaultText: ModelPrompts.summaryDefault,
        help: "控制摘要重点、待办整理和相关性判断。完整未读、分段汇总及 JSON 输出与证据约束由程序保留。")
      ModelPromptEditor(title: "相关性决策 · Jev", text: $jev,
        defaultText: ModelPrompts.jevDefault,
        help: "同时用于“是否相关”和“是否需要回应”两个问题。消息编号与概率格式由程序保留，本地明确命中规则仍然有效。")
      HStack(spacing: 12) {
        Button("保存提示词") { save() }
          .buttonStyle(P5ButtonStyle(kind: .primary))
          .disabled(!isDirty || store.loadingCredentials || validationError != nil)
        Button("重新载入") { reload(); notice = "已载入当前保存的提示词。"; failed = false }
          .disabled(store.loadingCredentials)
        if isDirty { Text("有未保存的修改").font(.caption).foregroundStyle(.secondary) }
        Spacer(minLength: 0)
      }
      if let validationError {
        Text(validationError).font(.caption).foregroundStyle(.red)
      } else if !notice.isEmpty {
        Text(notice).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
          .textSelection(.enabled)
      }
      Text("保存到 ~/.config/qundao/config.toml，也可直接编辑文件。新摘要任务使用保存后的提示词；正在执行的摘要沿用启动时的版本。Jev 会按新提示词重新判断待处理批次。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { if !loaded { reload() } }
    .onChange(of: pageActive) { _, active in if active { synchronize() } }
    .onChange(of: store.preferences.cpaSystemPrompt) { _, _ in synchronize() }
    .onChange(of: store.preferences.jevSystemPrompt) { _, _ in synchronize() }
    .onChange(of: store.loadingCredentials) { _, loading in if !loading { synchronize() } }
  }

  private func reload() {
    summary = ModelPrompts.effectiveSummary(store.preferences.cpaSystemPrompt)
    jev = ModelPrompts.effectiveJev(store.preferences.jevSystemPrompt)
    baselineSummary = summary; baselineJev = jev; loaded = true
  }
  private func synchronize() {
    guard loaded else { reload(); return }
    let latestSummary = ModelPrompts.effectiveSummary(store.preferences.cpaSystemPrompt)
    let latestJev = ModelPrompts.effectiveJev(store.preferences.jevSystemPrompt)
    guard latestSummary != baselineSummary || latestJev != baselineJev else { return }
    if !isDirty { reload() }
    else {
      notice = "已保存的配置发生变化，当前草稿已保留。可重新载入，或保存当前草稿。"
      failed = false
    }
  }
  private func save() {
    do {
      try store.saveModelPrompts(summary: summary, jev: jev)
      reload(); notice = "提示词已保存。"; failed = false
    } catch { notice = error.localizedDescription; failed = true }
  }
}

struct ModelPromptEditor: View {
  let title: String
  @Binding var text: String
  let defaultText: String
  let help: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button("恢复默认") { text = defaultText }
          .disabled(text == defaultText)
          .accessibilityLabel("\(title)恢复默认")
      }
      TextEditor(text: $text)
        .font(.system(size: 12))
        .scrollContentBackground(.hidden)
        .padding(8).frame(height: 180)
        .background(.white)
        .overlay(Rectangle().stroke(P5.ink.opacity(0.3), lineWidth: 1))
        .accessibilityLabel("\(title)系统提示词")
      Text(help).font(.caption).foregroundStyle(.secondary)
    }
  }
}
