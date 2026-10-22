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
  var highlightedIDs: Set<String> = []
  var onRead: () -> Void
  var onSnooze: (() -> Void)? = nil
  @State private var showingSource = false
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 9 : 14) {
      HStack(spacing: 7) {
        P5Badge(text: stateLabel ?? (viewed ? "已阅" : "待阅"), color: viewed ? P5.secondary : P5.red)
        if !tags.isEmpty { AttentionTags(tags: tags) }
        Spacer()
        Text(date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
          .help("本批最新消息时间")
      }
      Text(text).font(.system(size: compact ? 12 : 14)).lineSpacing(compact ? 4 : 6)
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      if !reason.isEmpty {
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: "link").foregroundStyle(P5.red)
          Text(reason).textSelection(.enabled)
        }.font(.system(size: 11)).foregroundStyle(P5.secondary)
      }
      Divider()
      HStack(spacing: 8) {
        Button("查看原文", systemImage: "text.bubble") { showingSource = true }.disabled(messages.isEmpty)
          .buttonStyle(P5ButtonStyle(kind: .quiet, compact: true))
          .help("弹出显示本批聊天记录")
          .accessibilityIdentifier("reading-source-\(recordID)")
        Text("本批 \(messages.count) 条").font(.system(size: 10)).foregroundStyle(P5.secondary)
        Spacer(minLength: 0)
        if !viewed {
          Button("已阅", systemImage: "checkmark", action: onRead).help("仅标记群岛内容已阅，不改变微信未读")
            .accessibilityIdentifier("reading-viewed-\(recordID)")
        }
        if !compact, !viewed, let onSnooze {
          Button("稍后", action: onSnooze).help("15 分钟后再次提醒")
        }
      }.buttonStyle(P5ButtonStyle(compact: true))
    }.padding(compact ? 12 : 22)
      .background(.white)
      .overlay(Rectangle().stroke(P5.ink, lineWidth: 1.4))
      .background((viewed ? P5.ink : P5.red).offset(x: 5, y: 5))
      .overlay(alignment: .topLeading) {
        Rectangle().fill(P5.ink).frame(width: 36, height: 7).rotationEffect(.degrees(-4))
          .offset(x: 22, y: -3).accessibilityHidden(true)
      }
      .padding(.trailing, 5).padding(.top, 4).padding(.bottom, 5)
      .sheet(isPresented: $showingSource) {
        SourceTranscriptSheet(groupName: groupName, messages: messages,
          highlightedIDs: highlightedIDs.union(tags.filter(\.definite).map { $0.message.id })) { showingSource = false }
      }
  }
}

/// 本批原文弹窗。
struct SourceTranscriptSheet: View {
  @Environment(AppStore.self) var store
  let groupName: String
  let messages: [Message]
  var highlightedIDs: Set<String> = []
  let close: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(groupName).font(P5.heavy(20))
          Text("本批原文 · \(messages.count) 条消息").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("关闭", systemImage: "xmark", action: close).keyboardShortcut(.cancelAction)
          .buttonStyle(P5ButtonStyle(compact: true))
      }.padding(22).background(P5.mainPaper)
      Rectangle().fill(P5.ink).frame(height: 2)
      ChatTranscript(messages: messages.sorted { $0.timestamp < $1.timestamp },
                     selfID: store.activeAccount?.subjectID ?? "", highlightedIDs: highlightedIDs)
      Divider()
      Label("阅读原文不会改变微信未读状态", systemImage: "checkmark.shield")
        .font(.caption2).foregroundStyle(P5.secondary).padding(14)
    }.frame(width: 640, height: 560).background(P5.mainPaper)
      .foregroundStyle(P5.ink).tint(P5.red).preferredColorScheme(.light)
      .onChange(of: store.preferences.accountID) { _, _ in close() }
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
        P5Badge(text: tag.title, color: tag.definite ? P5.ink : P5.secondary).help(tag.reason)
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
        highlightedIDs: item.definite ? [item.message.id] : [],
        onRead: { store.readFocusEntries([entry]) }, onSnooze: item.status == "pending" ? { store.snooze(item) } : nil)
    }
  }
}
