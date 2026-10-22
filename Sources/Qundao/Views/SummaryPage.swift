import QundaoCore
import SwiftUI

struct SummaryPage: View {
  @Environment(AppStore.self) var store
  @State private var onlyRelated = false
  private var displayed: [Digest] { store.digests.filter { !onlyRelated || $0.related } }
  var body: some View {
    let displayed = self.displayed
    VStack(spacing: 0) {
      P5PageHeader(title: "群聊摘要", subtitle: "未读消息的来龙去脉，一起看清。") {
        HStack(spacing: 10) {
          Button("生成未读摘要", systemImage: "sparkles") { store.requestAllAnalysis() }
            .buttonStyle(P5ButtonStyle(kind: .primary))
            .help("检查白名单群的完整未读，有新增才生成摘要；不改变微信已读状态")
            .disabled(!store.running || !store.preferences.aiEnabled || store.preferences.selectedGroups.isEmpty)
          Button("一键已阅", systemImage: "checkmark") { store.readSummaries(displayed) }
            .buttonStyle(P5ButtonStyle())
            .help("将当前筛选范围的全部摘要标记已阅；不改变微信未读")
            .disabled(!displayed.contains { $0.attentionReadAt == nil })
        }
      }
      HStack(spacing: 12) {
        Toggle("只看与我相关", isOn: $onlyRelated).toggleStyle(.checkbox).font(.caption)
        Spacer()
        Picker("周期摘要", selection: Binding(get: { store.preferences.intervalMinutes },
          set: { value in store.update { $0.intervalMinutes = value } })) {
          Text("每 5 分钟").tag(5)
          Text("每 15 分钟").tag(15)
          Text("每 30 分钟").tag(30)
        }.frame(width: 170).controlSize(.small)
      }.padding(.horizontal, 20).padding(.vertical, 10)
      Divider()
      SummaryBrowser(selection: Bindable(store).summaryGroupID, onlyRelated: onlyRelated)
    }
  }
}

struct SummaryBrowser: View {
  @Environment(AppStore.self) var store
  @Binding var selection: String?
  let onlyRelated: Bool
  var compact = false
  @State private var search = ""
  private var threads: [SummaryThread] { store.summaryThreads(onlyRelated: onlyRelated) }
  private func rows(_ threads: [SummaryThread]) -> [ConversationRow] {
    threads.map { thread in
      let latest = thread.digests[0]
      return ConversationRow(id: thread.id, name: latest.groupName, preview: latest.text, date: thread.messageDate,
                             count: thread.digests.count, related: false,
                             unreadState: .wechat(!store.groupStatesSynced ? nil : thread.unread.map { max(0, $0) }), countLabel: "批摘要")
    }
  }
  var body: some View {
    let threads = self.threads
    VStack(spacing: 0) {
      ConversationBrowser(rows: rows(threads), selection: $selection, search: $search,
                          emptyTitle: onlyRelated ? "暂无相关摘要" : "暂无群聊摘要", compact: compact) { id in
        if let thread = threads.first(where: { $0.id == id }) {
          SummaryConversation(thread: thread, compact: compact).id(id)
        }
      }
      Divider()
      GroupReadSyncStatus(compact: compact)
    }.task(id: store.preferences.accountID) { await store.refreshGroupStates() }
  }
}

private struct SummaryConversation: View {
  @Environment(AppStore.self) var store
  let thread: SummaryThread
  var compact = false
  private var pending: Int { thread.digests.filter { $0.attentionReadAt == nil }.count }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        if !compact { GroupAvatar(name: thread.digests.first?.groupName ?? "群", size: 34) }
        VStack(alignment: .leading, spacing: 5) {
          Text(thread.digests.first?.groupName ?? "群聊")
            .font(compact ? .caption.bold() : .headline).lineLimit(1)
          Text("\(thread.digests.count) 批摘要 · \(pending) 批待阅 · \(unreadDescription)")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        if !compact {
          Button("本群已阅") { store.readSummaries(thread.digests) }
            .buttonStyle(P5ButtonStyle(compact: true)).disabled(pending == 0)
            .help("将本群摘要标记已阅，不改变微信未读")
        }
      }.padding(compact ? 10 : 18)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: compact ? 10 : 18) {
          ForEach(thread.digests) { digest in DigestReadingCard(digest: digest, compact: compact) }
        }.padding(compact ? 10 : 20)
      }
    }
  }
  private var unreadDescription: String {
    guard let unread = store.groupUnreadCount(thread.id) else { return "微信未读待同步" }
    return unread > 0 ? "微信未读 \(unread) 条" : "微信无未读"
  }
}

struct ChatTranscript: View {
  let messages: [Message]
  let selfID: String
  var highlightedID: String? = nil
  var highlightedIDs: Set<String> = []
  var startAtLatest = false
  var compact = false
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          if messages.isEmpty {
            ContentUnavailableView("暂无已同步原文", systemImage: "bubble.left",
                                   description: Text("开始监听并同步消息后，可在此阅读。"))
          }
          ForEach(messages, id: \.key) { message in
            let mine = !selfID.isEmpty && message.senderID == selfID
            let highlighted = message.id == highlightedID || highlightedIDs.contains(message.id)
            HStack(alignment: .top, spacing: 9) {
              if mine { Spacer(minLength: compact ? 0 : 45) }
              if !mine { GroupAvatar(name: message.sender.isEmpty ? "群" : message.sender, size: compact ? 20 : 28) }
              VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                Text("\(message.sender) · \(message.date.formatted(date: .abbreviated, time: .shortened))")
                  .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(message.text.isEmpty ? "[非文字消息]" : message.text)
                  .font(.system(size: compact ? 12 : 13)).lineSpacing(4).textSelection(.enabled)
                  .padding(.horizontal, 13).padding(.vertical, 10)
                  .foregroundStyle(mine ? Color.white : Color.primary)
                  .background(mine ? P5.ink : Color.white)
                  .overlay(Rectangle()
                    .stroke(highlighted ? P5.red : P5.ink.opacity(0.2), lineWidth: highlighted ? 2 : 1))
                  .background((mine ? P5.red : P5.ink.opacity(0.12)).offset(x: 3, y: 3))
              }
              if !mine { Spacer(minLength: compact ? 0 : 45) }
              if mine { GroupAvatar(name: "我", size: compact ? 20 : 28) }
            }.id(message.key)
          }
        }.padding(compact ? 8 : 20)
      }.onAppear {
        if let highlightedID, let message = messages.first(where: { $0.id == highlightedID }) {
          proxy.scrollTo(message.key, anchor: .center)
        } else if startAtLatest, let last = messages.last {
          proxy.scrollTo(last.key, anchor: .bottom)
        }
      }
    }
  }
}
