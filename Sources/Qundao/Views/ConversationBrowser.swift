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
  @FocusState private var listFocused: Bool
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
          P5EmptyState(title: search.isEmpty ? emptyTitle : "没有匹配的群聊",
                       message: search.isEmpty ? "有新内容时会出现在这里。" : "试试其他群名称。")
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(spacing: 8) {
                ForEach(filtered) { row in
                  Button { selection = row.id; listFocused = true } label: {
                    ConversationListRow(row: row, selected: selection == row.id, compact: compact)
                  }.buttonStyle(.plain).id(row.id)
                    .accessibilityAddTraits(selection == row.id ? .isSelected : [])
                }
              }.padding(.horizontal, 12).padding(.vertical, 12)
            }
            .focusable().focused($listFocused).focusEffectDisabled()
            .onMoveCommand { direction in
              guard direction == .up || direction == .down else { return }
              let index = filtered.firstIndex { $0.id == selection } ?? 0
              selection = filtered[min(filtered.count - 1, max(0, index + (direction == .up ? -1 : 1)))].id
            }
            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
          }
        }
        Divider()
        Text("\(filtered.count) 个群聊").font(.caption2).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }.frame(minWidth: compact ? 100 : 225, idealWidth: compact ? 115 : 250, maxWidth: compact ? 150 : 260, maxHeight: .infinity)
        .background(P5.mainPaper)
      Group {
        if let id = selection, filtered.contains(where: { $0.id == id }) {
          detail(id)
        } else {
          P5EmptyState(title: "选择一个群聊", message: "左侧选择群聊，在这里阅读内容。")
        }
      }.frame(minWidth: compact ? 195 : 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(P5ReadingBackground())
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
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField(placeholder, text: $text).textFieldStyle(.plain).focused($focused)
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清空搜索")
      }
    }.padding(.horizontal, 10).padding(.vertical, 8)
      .background(.white)
      .overlay(Rectangle().stroke(focused ? P5.red : P5.ink.opacity(0.24), lineWidth: focused ? 2 : 1))
  }
}
struct GroupAvatar: View {
  let name: String
  var size: CGFloat = 36
  var selected = false
  var body: some View {
    Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .heavy))
      .foregroundStyle(selected ? P5.red : .white).frame(width: size, height: size)
      .background(selected ? .white : P5.ink, in: P5Shard())
      .accessibilityHidden(true)
  }
}

private struct ConversationListRow: View {
  let row: ConversationRow
  let selected: Bool
  let compact: Bool
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      if !compact { GroupAvatar(name: row.name, size: 31, selected: selected) }
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(row.name).font(.system(size: compact ? 11 : 12, weight: .bold)).lineLimit(1)
          Spacer(minLength: 0)
          Text(row.date, format: .dateTime.hour().minute()).font(.system(size: 9)).monospacedDigit()
            .foregroundStyle(selected ? .white.opacity(0.8) : P5.secondary)
        }
        Text(String(row.preview.prefix(140)).replacingOccurrences(of: "\n", with: " "))
          .font(.system(size: 11)).lineSpacing(3).lineLimit(2)
          .foregroundStyle(selected ? .white.opacity(0.85) : P5.secondary)
        HStack(spacing: 4) {
          Text("\(row.count) \(row.countLabel)").font(.system(size: 9))
            .foregroundStyle(selected ? .white.opacity(0.8) : P5.secondary)
          Spacer(minLength: 2)
          if let unread = row.unreadState.count, unread > 0 {
            Text(row.unreadState.badgeText).font(P5.numeral(10))
              .padding(.horizontal, 5).padding(.vertical, 2)
              .foregroundStyle(selected ? P5.red : .white)
              .background(selected ? .white : P5.red, in: P5Slant())
              .help(row.unreadState.description).accessibilityLabel(row.unreadState.description)
          } else if row.unreadState.count == nil {
            Image(systemName: "clock").font(.system(size: 10))
              .help("微信未读状态尚未从 Alpha 同步").accessibilityLabel("微信未读状态尚未同步")
          }
        }
      }
    }.padding(.horizontal, 12).padding(.vertical, compact ? 10 : 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(selected ? .white : P5.ink)
      .background { if selected { P5Slant(slant: 0.022).fill(P5.red) } }
      .contentShape(Rectangle())
  }
}
