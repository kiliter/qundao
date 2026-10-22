import QundaoCore
import SwiftUI

struct GroupsPage: View {
  @Environment(AppStore.self) var store
  @Environment(\.controlActiveState) private var controlActiveState
  @State private var search = ""
  @State private var selection: Set<String> = []
  @State private var sortOrder = [KeyPathComparator(\ChatGroup.name)]
  @State private var adding = false
  private var groups: [ChatGroup] {
    store.groups.filter {
      store.preferences.selectedGroups.contains($0.id)
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
    }.sorted(using: sortOrder)
  }
  var body: some View {
    let groups = self.groups
    // 每组最近摘要时间一次算好，避免每行都过滤排序全部摘要。
    let latest = store.digests.reduce(into: [String: Date]()) { map, digest in
      if map[digest.groupID] == nil { map[digest.groupID] = digest.date }
    }
    VStack(spacing: 0) {
      P5PageHeader(title: "监听群聊", subtitle: "只处理白名单内的群，重要的事不漏看。") {
        Button("添加群聊", systemImage: "plus") { adding = true }.buttonStyle(P5ButtonStyle(kind: .primary))
      }
      HStack(spacing: 12) {
        SearchBox(placeholder: "搜索白名单", text: $search).frame(maxWidth: 350)
        Spacer()
        Button("移出白名单", systemImage: "minus") {
          store.setWhitelist(store.preferences.selectedGroups.subtracting(selection))
          selection = []
        }.disabled(selection.isEmpty)
        Button { Task { await store.connect() } } label: { Image(systemName: "arrow.clockwise") }
          .disabled(store.busy).help("刷新群列表")
      }.padding(.horizontal, 20).padding(.vertical, 14)
      Divider()
      Table(groups, selection: $selection, sortOrder: $sortOrder) {
        TableColumn("群聊", value: \.name) { group in
          HStack(spacing: 10) {
            GroupAvatar(name: group.name, size: 27, selected: selected(group))
            Text(group.name).lineLimit(1).help(group.name)
              .foregroundStyle(selected(group) ? .white : P5.ink)
          }.padding(.vertical, 5)
        }.width(min: 220, ideal: 360)
        TableColumn("微信未读", value: \.unread) { group in
          Text(group.unread.formatted()).monospacedDigit()
            .foregroundStyle(selected(group) ? .white : P5.secondary)
        }.width(80)
        TableColumn("即时识别") { group in
          Label("已开启", systemImage: "checkmark.circle.fill").font(.caption)
            .foregroundStyle(selected(group) ? .white : Color.green)
        }.width(85)
        TableColumn("最近摘要") { group in
          if let date = latest[group.id] {
            Text(date, format: .dateTime.month().day().hour().minute()).font(.caption)
              .foregroundStyle(selected(group) ? .white : P5.secondary)
          } else { Text("暂无").font(.caption).foregroundStyle(selected(group) ? .white : P5.grey) }
        }.width(min: 100, ideal: 130)
      }
      .scrollContentBackground(.hidden).background(.white)
      .overlay {
        if groups.isEmpty {
          VStack(spacing: 16) {
            ContentUnavailableView(search.isEmpty ? "添加你想关注的群" : "没有匹配的群聊",
              systemImage: "person.2.badge.plus",
              description: Text(search.isEmpty ? "白名单默认不全选。打开群列表，按需勾选添加。" : "这里只搜索已加入白名单的群。"))
            if search.isEmpty { Button("添加群聊") { adding = true }.buttonStyle(P5ButtonStyle()) }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      Divider()
      HStack {
        Text("白名单 \(store.preferences.selectedGroups.count) 个群")
        if !selection.isEmpty { Text("· 已选 \(selection.count) 个") }
        Spacer()
        Text("支持 ⌘ / ⇧ 多选")
      }.font(.caption2).foregroundStyle(.secondary).padding(14)
    }
    .sheet(isPresented: $adding) { AddGroupsSheet().environment(store) }
    .onChange(of: groups.map(\.id)) { _, ids in selection.formIntersection(ids) }
  }
  private func selected(_ group: ChatGroup) -> Bool {
    selection.contains(group.id) && controlActiveState != .inactive
  }
}

private struct AddGroupsSheet: View {
  @Environment(AppStore.self) var store
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @State private var selected: Set<String> = []
  private var results: [ChatGroup] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.groups.filter {
      !store.preferences.selectedGroups.contains($0.id) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          P5Ransom(text: "添加群聊", scale: 1.35)
          Text("直接勾选要监听的群聊，也可搜索筛选。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack {
        SearchBox(placeholder: "筛选群名称", text: $search)
        Button("全选当前列表") { selected.formUnion(results.map(\.id)) }.disabled(results.isEmpty)
        Button("清空选择") { selected = [] }.disabled(selected.isEmpty)
        Button { Task { await store.connect() } } label: { Image(systemName: "arrow.clockwise") }
          .disabled(store.busy).help("刷新群列表")
      }
      Table(results) {
        TableColumn("选择") { group in
          Toggle("选择 \(group.name)", isOn: Binding(
            get: { selected.contains(group.id) },
            set: { on in if on { selected.insert(group.id) } else { selected.remove(group.id) } }))
            .labelsHidden().toggleStyle(.checkbox)
        }.width(40)
        TableColumn("群聊") { group in Text(group.name).lineLimit(1).help(group.name) }
        TableColumn("未读") { group in Text(group.unread.formatted()).foregroundStyle(.secondary) }.width(60)
      }.overlay {
        if results.isEmpty {
          ContentUnavailableView(search.isEmpty ? "暂无可添加的群聊" : "没有匹配的群聊",
            systemImage: "magnifyingglass",
            description: Text(store.groups.isEmpty ? "请先连接 Alpha 或刷新群列表。" : "已加入白名单的群不会重复显示。"))
        }
      }
      HStack {
        Text("可添加 \(results.count) 个群 · 已选 \(selected.count) 个")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("添加已选 \(selected.count) 个群") {
          store.setWhitelist(store.preferences.selectedGroups.union(selected))
          dismiss()
        }.buttonStyle(P5ButtonStyle(kind: .primary)).disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
      }
    }.padding(22).frame(width: 680, height: 520)
      .background(P5.mainPaper).foregroundStyle(P5.ink).tint(P5.red)
      .buttonStyle(P5ButtonStyle(compact: true)).preferredColorScheme(.light)
      .onChange(of: store.groups.map(\.id)) { _, ids in selected.formIntersection(ids) }
  }
}
