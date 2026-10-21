import QundaoCore
import SwiftUI

struct ContentView: View {
  @EnvironmentObject var store: AppStore
  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "circle.bottomhalf.filled").font(.system(size: 25)).foregroundStyle(.indigo)
          Text("群岛").font(.title3.weight(.semibold))
          Spacer()
        }.padding(18)
        List(selection: $store.page) {
          Section("工作空间") { ForEach([Page.attention, .summary, .groups]) { nav($0) } }
          Section("偏好设置") {
            ForEach([Page.rules, .appearance, .connection, .logs]) { nav($0) }
          }
        }.listStyle(.sidebar)
        VStack(alignment: .leading, spacing: 7) {
          Label(store.running ? "正在监听" : "监听已暂停",
                systemImage: store.running ? "circle.fill" : "pause.circle")
            .font(.caption).foregroundStyle(store.running ? .green : .secondary)
          Text("白名单 \(store.preferences.selectedGroups.count) 个群 · 即时与周期摘要")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
      }.navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 230)
    } detail: {
      VStack(spacing: 0) {
        if let error = store.error { errorBanner(error) }
        pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        HStack(spacing: 8) {
          Circle().fill(store.running ? Color.green : Color.secondary).frame(width: 5, height: 5)
          Text(store.streamStatus).lineLimit(1)
          if store.running { Text("· " + store.decisionStatus).lineLimit(1) }
          Spacer()
          if let time = store.lastSync {
            Text("最近同步 \(time.formatted(date: .omitted, time: .shortened))")
          }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
          .padding(.horizontal, 18).padding(.vertical, 8)
      }
      .navigationTitle(store.page.rawValue)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          HStack(spacing: 10) {
            if store.syncing || store.analyzing { ProgressView().controlSize(.small) }
            Button(store.running ? "暂停监听" : "开始监听",
                   systemImage: store.running ? "pause" : "play") {
              store.running ? store.stop() : store.start()
            }
          }
        }
      }
    }
    .frame(minWidth: 940, minHeight: 620).tint(.indigo)
    .sheet(item: $store.detail) { AttentionDetail(item: $0).environmentObject(store) }
  }
  @ViewBuilder private var pageContent: some View {
    switch store.page {
    case .attention: AttentionPage()
    case .summary: SummaryPage()
    case .groups: GroupsPage()
    case .logs: LogsPage()
    default:
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch store.page {
          case .rules: RulesPage()
          case .appearance: AppearancePage()
          case .connection: ConnectionPage()
          default: EmptyView()
          }
        }.padding(24).frame(maxWidth: 860, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }
  private func nav(_ page: Page) -> some View {
    HStack {
      Label(page.rawValue, systemImage: page.icon)
      Spacer()
      if page == .attention && store.pendingFocusCount > 0 {
        Text("\(store.pendingFocusCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
    }.tag(page).padding(.vertical, 2)
  }
  private func errorBanner(_ error: String) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(error).font(.caption).lineLimit(2).help(error)
      Spacer(minLength: 4)
      Button("查看日志") { store.page = .logs }.buttonStyle(.borderless).font(.caption)
      Button { store.error = nil } label: { Image(systemName: "xmark") }
        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭提示")
    }.padding(.horizontal, 18).padding(.vertical, 10).background(.orange.opacity(0.06))
  }
}

struct PageHeading: View {
  let title: String
  let subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 20, weight: .semibold))
      Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}
struct SoftCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 14) { content }
      .frame(maxWidth: .infinity, alignment: .leading).padding(18)
      .background(.background, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.07)))
  }
}
struct AttentionCard: View {
  @EnvironmentObject var store: AppStore
  let item: Attention
  var compact = false
  var body: some View {
    SoftCard {
      HStack {
        Label(item.groupName, systemImage: "person.2.fill").font(.caption).lineLimit(1)
        Spacer()
        Text(item.message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
      }
      if !compact {
        HStack {
          Text(item.title).font(.headline)
          Spacer()
          Text(item.definite ? "直接命中" : "AI 判断").font(.caption2).foregroundStyle(.indigo)
        }
      }
      Text("\(item.message.sender)：\(item.message.text)").font(compact ? .caption : .callout)
        .lineLimit(compact ? 3 : 5).textSelection(.enabled)
      Text(item.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 2 : nil)
      HStack {
        Button("查看原文") { store.detail = item }
        if item.status == "pending" {
          Button("已处理") { store.resolve(item) }
          Button("稍后 15 分钟") { store.snooze(item) }
        } else {
          Text(item.status == "done" ? "已处理" : "稍后提醒").foregroundStyle(.secondary)
        }
      }.buttonStyle(.bordered).controlSize(.small)
    }
  }
}
struct AttentionDetail: View {
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) var dismiss
  let item: Attention
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text(item.groupName).font(.title2.bold())
        Spacer()
        Button("关闭") { dismiss() }
      }
      let context = store.snapshot.messages.filter {
        $0.accountID == item.message.accountID && $0.groupID == item.message.groupID
          && abs($0.timestamp - item.message.timestamp) < 300000
      }
      let messages = context.contains(where: { $0.key == item.message.key }) ? context : context + [item.message]
      ChatTranscript(messages: messages.sorted { $0.timestamp < $1.timestamp },
                     selfID: store.activeAccount?.subjectID ?? "", highlightedID: item.message.id)
      Text(item.reason).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("标记已处理") {
          store.resolve(item)
          dismiss()
        }.buttonStyle(.borderedProminent)
        Button("稍后提醒") {
          store.snooze(item)
          dismiss()
        }
        Button("复制原文") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(item.message.text, forType: .string)
        }
      }
    }.padding(24).frame(width: 620, height: 550)
  }
}
