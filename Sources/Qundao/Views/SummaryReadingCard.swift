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
  /// 并入本卡片的「找你 / 需回应」提醒。
  var tags: [Attention] = []
  var onRead: () -> Void
  var onSnooze: (() -> Void)? = nil
  @Environment(AppStore.self) var store
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
      if !tags.isEmpty { AttentionTags(tags: tags) }
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
        SourceTranscriptSheet(groupName: groupName, messages: messages) { showingSource = false }
      }
  }
}

/// 本批原文弹窗。
struct SourceTranscriptSheet: View {
  @Environment(AppStore.self) var store
  let groupName: String
  let messages: [Message]
  let close: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(groupName).font(.headline)
          Text("本批原文 · \(messages.count) 条消息").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", action: close).keyboardShortcut(.cancelAction)
      }.padding(18)
      Divider()
      ChatTranscript(messages: messages.sorted { $0.timestamp < $1.timestamp },
                     selfID: store.activeAccount?.subjectID ?? "")
      Divider()
      Text("阅读原文不会改变微信未读状态").font(.caption2).foregroundStyle(.secondary).padding(12)
    }.frame(width: 640, height: 560)
  }
}

struct DigestReadingCard: View {
  @Environment(AppStore.self) var store
  let digest: Digest
  var compact = false
  var tags: [Attention] = []
  var body: some View {
    SummaryReadingCard(recordID: digest.id.uuidString, groupName: digest.groupName, text: digest.text, reason: digest.relevanceReason,
      date: digest.messageDate, messages: digest.evidence, viewed: !digest.isAttentionPending,
      compact: compact, stateLabel: digest.attentionReadAt == nil && digest.supersededBy != nil ? "已被更新摘要覆盖" : nil,
      tags: tags, onRead: { store.readRelatedSummary(digest) })
  }
}

/// 「找你 / 需回应」标签：明确提及与模型判断分开显示，悬停查看原因。
struct AttentionTags: View {
  let tags: [Attention]
  var dark = false
  var body: some View {
    HStack(spacing: 6) {
      ForEach(tags.prefix(3), id: \.id) { tag in
        Label(tag.title, systemImage: tag.definite ? "at" : "bubble.left.and.exclamationmark.bubble.right")
          .font(.caption2.weight(.medium)).lineLimit(1)
          .foregroundStyle(tag.definite ? Color.orange : Color.indigo)
          .padding(.horizontal, 7).padding(.vertical, 2)
          .background((tag.definite ? Color.orange : Color.indigo).opacity(dark ? 0.22 : 0.12), in: Capsule())
          .help(tag.reason)
      }
      if tags.count > 3 { Text("+\(tags.count - 3)").font(.caption2).foregroundStyle(.secondary) }
    }.accessibilityElement(children: .combine)
  }
}

struct FocusReadingCard: View {
  @Environment(AppStore.self) var store
  let entry: AttentionEntry
  var compact = false
  var tags: [Attention] = []
  var body: some View {
    switch entry {
    case .summary(let digest): DigestReadingCard(digest: digest, compact: compact, tags: tags)
    case .response(let item):
      SummaryReadingCard(recordID: item.id, groupName: item.groupName, text: item.title, reason: item.reason,
        date: item.message.date, messages: [item.message], viewed: item.status == "done", compact: compact,
        stateLabel: item.status == "snoozed" ? "稍后提醒" : nil,
        onRead: { store.readFocusEntries([entry]) }, onSnooze: item.status == "pending" ? { store.snooze(item) } : nil)
    }
  }
}
