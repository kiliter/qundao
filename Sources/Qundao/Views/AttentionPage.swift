import QundaoCore
import SwiftUI

struct AttentionPage: View {
  var body: some View { AttentionBrowser() }
}

struct AttentionBrowser: View {
  @Environment(AppStore.self) var store
  var compact = false
  @State private var showHistory = false
  @State private var search = ""
  private var threads: [AttentionThread] {
    if !showHistory { return store.pendingAttention.threads }
    return AttentionFeed.threads(attentions: store.allAttentions, digests: store.allDigests,
                          account: store.preferences.accountID, includeHistory: showHistory)
  }
  private func rows(_ threads: [AttentionThread]) -> [ConversationRow] {
    threads.map { thread in
      let latest = thread.entries[0]
      return ConversationRow(id: thread.id, name: latest.groupName, preview: latest.preview,
                             date: latest.date, count: thread.entries.count, related: false,
                             unreadState: .attention(thread.pendingCount), countLabel: "条关注")
    }
  }
  var body: some View {
    let threads = self.threads
    let digestGroups = Set(store.digests.map(\.groupID))
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("\(store.pendingFocusCount) 条待关注").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if !compact {
          Toggle("包含历史", isOn: $showHistory).toggleStyle(.checkbox).font(.caption)
            .help("显示已阅和稍后提醒的记录")
        }
        Button("一键已阅", systemImage: "checkmark.circle") {
          store.readFocusEntries(store.attentionEntries())
        }.buttonStyle(.borderless).font(.caption).disabled(store.pendingFocusCount == 0)
          .help("将当前账号所有待关注内容标记已阅；不改变微信未读")
      }.padding(.horizontal, compact ? 8 : 16).padding(.vertical, compact ? 8 : 13)
      Divider()
      ConversationBrowser(rows: rows(threads), selection: Bindable(store).attentionGroupID, search: $search,
                          emptyTitle: "暂无待关注内容", compact: compact) { id in
        let thread = threads.first(where: { $0.id == id })
        let entries = thread?.entries ?? []
        VStack(spacing: 0) {
          HStack {
            Text(entries.first?.groupName ?? "群聊")
              .font(compact ? .caption.bold() : .headline).lineLimit(1)
            Spacer(minLength: 4)
            if !compact {
              Button("查看群聊摘要") { store.summaryGroupID = id; store.page = .summary }
                .buttonStyle(.borderless).font(.caption)
                .disabled(!digestGroups.contains(id))
            }
          }.padding(compact ? 10 : 18)
          Divider()
          ScrollView {
            LazyVStack(alignment: .leading, spacing: compact ? 10 : 18) {
              ForEach(entries) { entry in
                FocusReadingCard(entry: entry, compact: compact, tags: thread?.tags(for: entry) ?? [])
              }
            }.padding(compact ? 10 : 20)
          }
        }
      }
      Divider()
      Label(compact ? "小点表示待阅关注" : "小点表示待阅关注；已阅和稍后提醒的历史记录不计入",
            systemImage: "info.circle")
        .font(.caption2).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 6 : 9)
    }
  }
}
