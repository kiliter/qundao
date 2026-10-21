import QundaoCore
import SwiftUI

/// 需要关注、群聊摘要和刘海使用相同的阅读卡片和原文弹窗。
struct SummaryReadingCard: View {
  let recordID: String
  let groupName: String
  let text: String
  let reason: String
  let date: Date
  let messages: [Message]
  let viewed: Bool
  var compact = false
  var stateLabel: String? = nil
  var onRead: () -> Void
  var onSnooze: (() -> Void)? = nil
  @EnvironmentObject var store: AppStore
  @State private var showingSource = false
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 9 : 14) {
      HStack {
        Label(stateLabel ?? (viewed ? "已阅" : "待阅"), systemImage: viewed ? "checkmark.circle" : "text.alignleft")
          .font(.caption.weight(.medium)).foregroundStyle(viewed ? Color.secondary : .indigo)
        Spacer()
        Text(date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
          .help("本批最新消息时间")
      }
      Text(text).font(.system(size: compact ? 12 : 14)).lineSpacing(compact ? 4 : 6)
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      if !reason.isEmpty {
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack(spacing: 8) {
        Button("查看原文") { showingSource = true }.disabled(messages.isEmpty)
          .help("弹出显示本批聊天记录")
          .accessibilityIdentifier("reading-source-\(recordID)")
        Spacer(minLength: 0)
        if !viewed {
          Button("已阅", action: onRead).help("仅标记群岛内容已阅，不改变微信未读")
            .accessibilityIdentifier("reading-viewed-\(recordID)")
        }
        if !compact, !viewed, let onSnooze {
          Button("稍后", action: onSnooze).help("15 分钟后再次提醒")
        }
      }.buttonStyle(.borderless).font(.caption)
      Text("本批 \(messages.count) 条消息").font(.caption2).foregroundStyle(.secondary)
    }.padding(compact ? 10 : 18)
      .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
      .sheet(isPresented: $showingSource) {
        VStack(spacing: 0) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(groupName).font(.headline)
              Text("本批原文 · \(messages.count) 条消息").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { showingSource = false }.keyboardShortcut(.cancelAction)
          }.padding(18)
          Divider()
          ChatTranscript(messages: messages.sorted { $0.timestamp < $1.timestamp },
                         selfID: store.activeAccount?.subjectID ?? "")
          Divider()
          Text("阅读原文不会改变微信未读状态").font(.caption2).foregroundStyle(.secondary).padding(12)
        }.frame(width: 640, height: 560)
      }
  }
}

struct DigestReadingCard: View {
  @EnvironmentObject var store: AppStore
  let digest: Digest
  var compact = false
  var body: some View {
    SummaryReadingCard(recordID: digest.id.uuidString, groupName: digest.groupName, text: digest.text, reason: digest.relevanceReason,
      date: digest.messageDate, messages: digest.evidence, viewed: digest.attentionReadAt != nil,
      compact: compact, onRead: { store.readRelatedSummary(digest) })
  }
}

struct FocusReadingCard: View {
  @EnvironmentObject var store: AppStore
  let entry: AttentionEntry
  var compact = false
  var body: some View {
    switch entry {
    case .summary(let digest): DigestReadingCard(digest: digest, compact: compact)
    case .response(let item):
      SummaryReadingCard(recordID: item.id, groupName: item.groupName, text: item.title, reason: item.reason,
        date: item.message.date, messages: [item.message], viewed: item.status == "done", compact: compact,
        stateLabel: item.status == "snoozed" ? "稍后提醒" : nil,
        onRead: { store.readFocusEntries([entry]) }, onSnooze: item.status == "pending" ? { store.snooze(item) } : nil)
    }
  }
}
