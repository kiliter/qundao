import QundaoCore
import SwiftUI

struct RulesPage: View {
  @Environment(AppStore.self) var store
  @State private var name = ""
  @State private var keyword = ""
  var body: some View {
    P5SettingsColumns {
      P5PaperCard {
        P5SectionTitle("我的称呼")
        Text("姓名、群昵称、同事常用称呼。文字 @ 和点名请求命中后立即提醒，并保留原文。").font(.caption).foregroundStyle(.secondary)
        tags(store.preferences.names, keyPath: \.names)
        HStack {
          TextField("添加称呼", text: $name).textFieldStyle(P5TextFieldStyle()).onSubmit { addName() }
          Button("添加") { addName() }
        }
      }
      P5PaperCard {
        P5SectionTitle("关注关键词与职责")
        Text("例如：签字接口、版本上线、客户验收。相关语义先在本机筛选，最终由 AI 核对。").font(.caption).foregroundStyle(.secondary)
        tags(store.preferences.keywords, keyPath: \.keywords)
        HStack {
          TextField("添加关键词", text: $keyword).textFieldStyle(P5TextFieldStyle()).onSubmit { addKeyword() }
          Button("添加") { addKeyword() }
        }
      }
    }
    DecisionSettings()
    P5PaperCard {
      Toggle("明确 @我、@所有人 或点名找我时立即提示", isOn: binding(\.immediateMentions))
      Toggle("启用本地相关语义筛选", isOn: binding(\.semanticEnabled))
      Text(
        store.semantic.available
          ? "本机中文语义模型可用。相近含义只作为候选，不直接判定有人找你。" : "本机中文语义模型不可用；当前使用称呼和关键词筛选，周期摘要仍由 AI 判断相关性。"
      ).font(.caption).foregroundStyle(.secondary)
      Toggle("启用 AI 即时与周期摘要", isOn: binding(\.aiEnabled))
    }
    P5PaperCard {
      P5SectionTitle("同群合并，避免重复摘要")
      Stepper("同时摘要：\(store.preferences.concurrentSummaries) 个群", value: Binding(
        get: { store.preferences.concurrentSummaries }, set: { value in store.update { $0.summaryConcurrency = value } }), in: 1...8)
      Stepper("实时缓冲容量：\(store.preferences.bufferCapacity) 条", value: Binding(
        get: { store.preferences.bufferCapacity }, set: { value in store.update { $0.realtimeCapacity = value } }), in: 1...500)
      Stepper("最长等待：\(store.preferences.bufferInterval, specifier: "%.1f") 秒", value: Binding(
        get: { store.preferences.bufferInterval }, set: { value in store.update { $0.realtimeFlushSeconds = value } }), in: 0.5...30, step: 0.5)
      Text("实时消息达到容量或首条等待到期后批量判断，相关才触发。即时与周期共用任务池，同群串行、即时优先。每次读取该群完整未读，旧未读仍参与摘要；只有成功保存后才记录末条标记。失败保留任务并退避重试。").font(.callout)
        .foregroundStyle(.secondary)
    }
  }
  func tags(_ values: [String], keyPath: WritableKeyPath<Preferences, [String]>) -> some View {
    TagFlowLayout(spacing: 8) {
      ForEach(values, id: \.self) { value in
        HStack(spacing: 7) {
          Text(value).lineLimit(1).help(value)
          Button {
            store.update { $0[keyPath: keyPath].removeAll { $0 == value } }
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).accessibilityLabel("移除 \(value)")
        }.font(.callout).padding(.horizontal, 10).padding(.vertical, 7).background(
          P5.mainPaper, in: P5Slant(slant: 0.03))
      }
    }
  }
  func binding(_ key: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
    Binding(
      get: { store.preferences[keyPath: key] }, set: { v in store.update { $0[keyPath: key] = v } })
  }
  func addName() {
    let v = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !v.isEmpty, !store.preferences.names.contains(v) else { return }
    store.update { $0.names.append(v) }
    name = ""
  }
  func addKeyword() {
    let v = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !v.isEmpty, !store.preferences.keywords.contains(v) else { return }
    store.update { $0.keywords.append(v) }
    keyword = ""
  }
}
struct AppearancePage: View {
  @Environment(AppStore.self) var store
  var body: some View {
    P5SettingsColumns {
      P5PaperCard {
        IslandMiniPreview()
        P5SectionTitle("刘海尺寸")
        IslandSizeControls()
        Divider()
        P5SectionTitle("交互")
        Toggle("鼠标悬停展开", isOn: binding(\.hover))
        Toggle("相关提醒到达时短暂展开", isOn: binding(\.autoExpand))
        Text("点击顶部状态固定面板，移开自动收起；外接屏使用顶部悬浮岛。").font(.caption).foregroundStyle(.secondary)
        Button("预览刘海") { NotchController.shared?.expand(pin: true) }
      }
      P5PaperCard {
        P5SectionTitle("通知")
        Toggle(
          "允许系统通知",
          isOn: Binding(
            get: { store.preferences.notifications },
            set: { on in
              if on {
                Task { await store.requestNotifications() }
              } else {
                store.update { $0.notifications = false }
              }
            }))
        Toggle("通知隐藏消息正文", isOn: binding(\.hideNotificationText))
        HStack {
          Text("免打扰 1 小时")
          Spacer()
          Button(store.isQuiet ? "关闭免打扰" : "开启免打扰") { store.toggleQuiet() }
        }
        Text("免打扰期间继续整理摘要，不弹出刘海和系统通知。").font(.caption).foregroundStyle(.secondary)
        Divider().padding(.vertical, 4)
        StartupSettings()
      }
    }.toggleStyle(.switch).controlSize(.small)
  }
  func binding(_ key: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
    Binding(
      get: { store.preferences[keyPath: key] }, set: { v in store.update { $0[keyPath: key] = v } })
  }
}
struct ConnectionPage: View {
  @Environment(AppStore.self) var store
  @Environment(\.pageActive) private var pageActive
  @State private var alpha = ""
  @State private var cpa = ""
  @State private var notice = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      P5SettingsColumns(minimum: 400) {
        P5PaperCard {
          P5SectionTitle("消息来源 · Alpha")
          LabeledContent("服务地址", value: "http://127.0.0.1:9527")
          SecureField("Alpha 访问令牌", text: $alpha).textFieldStyle(P5TextFieldStyle())
          HStack {
            Button("保存并连接") {
              do {
                try store.saveCredentials(alpha: alpha, cpa: cpa)
                Task { await store.connect() }
              } catch { store.error = error.localizedDescription }
            }.buttonStyle(P5ButtonStyle(kind: .primary)).disabled(store.busy || store.loadingCredentials)
            Text(store.status).font(.caption).foregroundStyle(.secondary)
          }
          if !store.accounts.isEmpty {
            Picker(
              "微信账号",
              selection: Binding(
                get: { store.preferences.accountID }, set: { store.selectAccount($0) })
            ) { ForEach(store.accounts) { a in Text(a.name.isEmpty ? "微信账号" : a.name).tag(a.id) } }
          }
        }
        P5PaperCard {
          P5SectionTitle("摘要模型 · CPA")
          LabeledContent("接口地址", value: "https://cpa.bgp.kiliter.cn/v1")
          VStack(alignment: .leading, spacing: 4) {
            Text("model_catalog_url").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("https://cpa.bgp.kiliter.cn/v1/models").font(.callout.monospaced()).textSelection(
              .enabled)
          }
          SecureField("CPA API Key", text: $cpa).textFieldStyle(P5TextFieldStyle())
          TagFlowLayout(spacing: 10) {
            Button("从 Codex 导入 CPA 密钥") {
              do {
                cpa = try KeychainStore.codexCPAKey()
                notice = "已读入密钥，请点击保存并获取模型。"
              } catch { store.error = error.localizedDescription }
            }
            Button("保存并获取模型") {
              do {
                try store.saveCredentials(alpha: alpha, cpa: cpa)
                Task { await store.loadCatalog() }
              } catch { store.error = error.localizedDescription }
            }.buttonStyle(P5ButtonStyle(kind: .primary)).disabled(store.busy || store.loadingCredentials)
          }
          if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
          if !store.models.isEmpty {
            Picker(
              "选择模型",
              selection: Binding(
                get: { store.preferences.model },
                set: { value in
                  store.update { $0.model = value }
                  store.normalizeReasoning()
                  store.save()
                })
            ) { ForEach(store.models) { m in Text(m.name).tag(m.id) } }
            if let m = store.models.first(where: { $0.id == store.preferences.model }) {
              HStack(spacing: 25) {
                modelMetric("上下文窗口", value: m.context)
                modelMetric("最大上下文", value: m.maxContext)
                modelMetric("输出上限", value: m.outputLimit)
              }.padding(.vertical, 8)
              if !m.reasoningLevels.isEmpty {
                Picker(
                  "推理强度",
                  selection: Binding(
                    get: { store.preferences.reasoning },
                    set: { v in store.update { $0.reasoning = v } })
                ) { ForEach(m.reasoningLevels, id: \.self) { Text($0).tag($0) } }
              }
              Text(m.native ? "已使用 Codex 目录协议获取能力，按模型上下文预算分批分析。" : "服务返回普通模型列表，未提供上下文参数；将使用保守预算。")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      JevConnectionCard()
      ModelPromptSettings()
      Text("密钥保存在 ~/.config/qundao/config.toml（仅本人可读，权限 600），也可直接编辑该文件，保存后自动生效。开始监听后，仅白名单群的未读消息会在周期摘要时发送至 CPA；即时命中后也发送该群当时的完整未读。私聊和白名单外群聊在入口丢弃。诊断日志会保存白名单群入参和出参中的聊天正文，令牌和模型密钥会隐藏。").font(
        .caption
      ).foregroundStyle(.secondary)
    }.onAppear {
      alpha = store.alphaToken
      cpa = store.cpaKey
    }.onChange(of: pageActive) { _, active in
      // 页面保留后不会再次 onAppear；重新显示时从当前配置刷新。
      if active { alpha = store.alphaToken; cpa = store.cpaKey }
    }.onChange(of: store.loadingCredentials) { _, loading in
      if !loading { if alpha.isEmpty { alpha = store.alphaToken }; if cpa.isEmpty { cpa = store.cpaKey } }
    }
  }
  func modelMetric(_ label: String, value: Int?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value.map { $0.formatted() } ?? "目录未提供").font(.headline.monospacedDigit())
    }
  }
}
