import QundaoCore
import SwiftUI

struct ConversationRow: Identifiable {
  let id: String
  let name: String
  let preview: String
  let date: Date
  let count: Int
  let related: Bool
  let unreadState: ConversationUnreadState
  var countLabel = "条关注"
}

/// 调用方必须明确小点的含义，避免将微信未读误当成本地待阅。
enum ConversationUnreadState {
  case attention(Int)
  case wechat(Int?)

  var count: Int? {
    switch self {
    case .attention(let count): return count
    case .wechat(let count): return count
    }
  }
  var badgeText: String {
    let number = (count ?? 0) > 99 ? "99+" : "\(count ?? 0)"
    switch self {
    case .attention: return number
    case .wechat: return "微信 \(number)"
    }
  }
  var description: String {
    switch self {
    case .attention(let count): return "本群 \(count) 条待阅关注"
    case .wechat(let count): return "微信未读 \(count ?? 0) 条，来自 Alpha"
    }
  }
}

/// 摘要和待关注消息共用群列表、搜索及双栏尺寸。
struct ConversationBrowser<Detail: View>: View {
  let rows: [ConversationRow]
  @Binding var selection: String?
  @Binding var search: String
  let emptyTitle: String
  var compact = false
  @ViewBuilder var detail: (String) -> Detail
  private var filtered: [ConversationRow] {
    rows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
  }
  var body: some View {
    let filtered = self.filtered
    HSplitView {
      VStack(spacing: 0) {
        SearchBox(placeholder: compact ? "群聊" : "搜索群聊", text: $search).padding(compact ? 6 : 12)
        Divider()
        if filtered.isEmpty {
          ContentUnavailableView(search.isEmpty ? emptyTitle : "没有匹配的群聊",
                                 systemImage: "bubble.left.and.bubble.right",
                                 description: Text(search.isEmpty ? "有新内容时会出现在这里。" : "试试其他群名称。"))
            .frame(maxHeight: .infinity)
        } else {
          List(selection: $selection) {
            ForEach(filtered) { row in
              HStack(alignment: .top, spacing: 10) {
                if !compact { GroupAvatar(name: row.name, size: 36) }
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text(row.name).font(.system(size: compact ? 11 : 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    if let unread = row.unreadState.count, unread > 0 {
                      HStack(spacing: 4) {
                        Circle().fill(.indigo).frame(width: 6, height: 6)
                        Text(row.unreadState.badgeText)
                          .font(.system(size: 10, weight: .medium)).foregroundStyle(.indigo)
                      }.fixedSize().help(row.unreadState.description)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.unreadState.description)
                    } else if row.unreadState.count == nil {
                      Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("该群微信未读状态尚未从 Alpha 同步，不能据此判断是否已读")
                        .accessibilityLabel("微信未读状态尚未同步")
                    }
                  }
                  // 单行预览只取开头，避免整段长摘要参与排版。
                  Text(String(row.preview.prefix(140)).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  HStack {
                    if row.related {
                      Text("与你相关").foregroundStyle(.indigo)
                    } else if !compact {
                      Text(row.date, format: .dateTime.month().day().hour().minute())
                    }
                    Spacer()
                    Text("\(row.count) \(row.countLabel)")
                  }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
              }.padding(.vertical, compact ? 4 : 7).tag(row.id)
            }
          }.listStyle(.inset).scrollContentBackground(.hidden)
        }
        Divider()
        Text("\(filtered.count) 个群聊").font(.caption2).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }.frame(minWidth: compact ? 100 : 230, idealWidth: compact ? 115 : 265, maxWidth: compact ? 150 : 290, maxHeight: .infinity)
      Group {
        if let id = selection, filtered.contains(where: { $0.id == id }) {
          detail(id)
        } else {
          ContentUnavailableView("选择一个群聊", systemImage: "text.bubble",
                                 description: Text("左侧选择群聊，在这里阅读内容。"))
        }
      }.frame(minWidth: compact ? 195 : 400, maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear { reconcile(filtered) }
    .onChange(of: filtered.map(\.id)) { _, ids in reconcile(filtered) }
  }
  private func reconcile(_ filtered: [ConversationRow]) {
    if !filtered.contains(where: { $0.id == selection }) { selection = filtered.first?.id }
  }
}

/// 未读状态由 Alpha 提供，与相关性、摘要批数和关注处理状态分别展示。
struct GroupReadSyncStatus: View {
  @Environment(AppStore.self) var store
  var compact = false
  private var status: String {
    if store.groupStatesRefreshing { return "正在同步 Alpha 未读…" }
    if store.groupStatesError != nil { return compact ? "未读同步失败" : "未读同步失败 · 保留上次状态" }
    if let date = store.groupStatesLastSync {
      return "Alpha 未读 · \(date.formatted(date: .omitted, time: .standard))"
    }
    return "未读状态尚未同步"
  }
  var body: some View {
    HStack(spacing: 8) {
      Label(status, systemImage: store.groupStatesError == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
        .font(.caption2).foregroundStyle(store.groupStatesError == nil ? Color.secondary : Color.orange)
        .lineLimit(1)
        .help(store.groupStatesError ?? "小点及未读数来自 Alpha。微信已读后随 Alpha 更新；此处阅读不会修改微信未读。")
      Spacer(minLength: 2)
      Button {
        Task { await store.refreshGroupStates() }
      } label: {
        if compact { Image(systemName: "arrow.clockwise") }
        else { Label("刷新未读", systemImage: "arrow.clockwise") }
      }.buttonStyle(.borderless).font(.caption2)
        .disabled(store.groupStatesRefreshing || store.preferences.accountID.isEmpty)
        .help("从 Alpha 重新获取群聊未读状态，不触发摘要")
        .accessibilityLabel("刷新 Alpha 未读状态")
    }.padding(.horizontal, compact ? 10 : 16).padding(.vertical, compact ? 6 : 9)
  }
}

struct SearchBox: View {
  let placeholder: String
  @Binding var text: String
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(placeholder, text: $text).textFieldStyle(.plain)
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清空搜索")
      }
    }.padding(.horizontal, 10).padding(.vertical, 8)
      .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
  }
}
struct GroupAvatar: View {
  let name: String
  var size: CGFloat = 36
  var body: some View {
    Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .medium))
      .foregroundStyle(.indigo).frame(width: size, height: size)
      .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.25))
      .accessibilityHidden(true)
  }
}
