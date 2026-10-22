import QundaoCore
import SwiftUI

struct DecisionSettings: View {
  @Environment(AppStore.self) var store
  var body: some View {
    P5PaperCard {
      P5SectionTitle("判断方式")
      Picker("即时相关性判断", selection: Binding(get: { store.preferences.decisionMethod ?? "local" },
        set: { value in store.update { $0.decisionMethod = value } })) {
        Text("本地识别").tag("local")
        Text("Jev 决策模型").tag("jev")
      }.pickerStyle(.segmented).labelsHidden()
      Text(store.preferences.usesJev
        ? "白名单新消息经 Jev 判断相关性与是否需要回应，命中后才触发 CPA 摘要。明确 @我、@所有人 仍由本地立即提示。"
        : "通过称呼、关键词及本地语义筛选触发即时摘要，CPA 结合上下文补充判断是否需要回应。")
        .font(.caption).foregroundStyle(.secondary)
      if store.preferences.usesJev {
        HStack {
          Text("Jev 提醒阈值")
          // 不用 step：macOS 会为步进绘制刻度，每次进入页面都要重建刻度缓存。写入时取 0.05 的倍数。
          Slider(value: Binding(get: { store.preferences.decisionThreshold },
                               set: { value in store.update { $0.jevThreshold = (value * 20).rounded() / 20 } }), in: 0.5...0.95)
          Text("\(Int(store.preferences.decisionThreshold * 100))%").monospacedDigit().frame(width: 36)
        }
        Text("较低阈值会保留更多候选。模型概率不代表一定有人找你；网络故障时回退本地筛选并保留重试。")
          .font(.caption).foregroundStyle(.secondary)
        if store.jevKey.isEmpty {
          HStack {
            Label("尚未配置决策服务密钥，当前使用本地识别", systemImage: "info.circle").font(.caption)
            Spacer()
            Button("配置 Jev") { store.page = .connection }.buttonStyle(.borderless)
          }.foregroundStyle(.orange)
        }
      }
    }
  }
}

struct JevConnectionCard: View {
  @Environment(AppStore.self) var store
  @Environment(\.pageActive) private var pageActive
  @State private var key = ""
  @State private var baseURL = JevConfiguration.openRouter.baseURL
  @State private var api = JevAPI.decisions
  @State private var model = JevConfiguration.openRouter.model
  @State private var testing = false
  @State private var notice = ""
  private var config: JevConfiguration {
    JevConfiguration(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), api: api,
                     model: model.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  var body: some View {
    P5PaperCard {
      HStack {
        P5SectionTitle("决策模型 · Jev")
        Spacer()
        Menu("填入预设") {
          Button("OpenRouter") { apply(.openRouter) }
          Button("TypeSafe 官方") { apply(.typeSafe) }
        }.fixedSize()
      }
      Text("支持 OpenRouter、TypeSafe 及兼容代理。摘要内容仍由 CPA 生成。")
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent("Base URL") {
        TextField("https://openrouter.ai/api", text: $baseURL).textFieldStyle(P5TextFieldStyle())
      }
      Picker("接口协议", selection: $api) {
        ForEach(JevAPI.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      LabeledContent("模型") {
        TextField("~typesafe/jev-latest", text: $model).textFieldStyle(P5TextFieldStyle())
      }
      SecureField("决策服务 API Key", text: $key).textFieldStyle(P5TextFieldStyle())
      if let endpoint = try? config.endpoint() {
        Text("请求地址：\(endpoint.absoluteString)").font(.caption.monospaced())
          .foregroundStyle(.secondary).textSelection(.enabled)
      } else {
        Text("请输入有效地址，并选择对应接口协议。").font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Button("保存决策配置") { saveConnection() }.disabled(testing || store.loadingCredentials)
        Button("保存并测试连接") {
          guard saveConnection() else { return }
          let savedConfig = config, savedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
          let savedPrompt = store.preferences.jevSystemPrompt
          testing = true
          notice = "正在用合成消息测试…"
          Task {
            defer { testing = false }
            do {
              let sample = Message(id: "test", accountID: "test", groupID: "test", senderID: "colleague",
                sender: "测试同事", text: "@测试用户 请确认本次版本上线时间。", timestamp: 1)
              _ = try await JevClient(key: savedKey, configuration: savedConfig, systemPrompt: savedPrompt,
                trace: { EventLog.shared.record($0) }).decide(messages: [sample], context: [],
                names: ["测试用户"], keywords: ["版本上线"], selfID: "test-user")
              notice = "连接成功。可在关键词与规则中选择 Jev 决策模型。"
              store.log.write("信息", "Jev 合成消息连接测试通过")
            } catch { notice = error.localizedDescription }
          }
        }.buttonStyle(P5ButtonStyle(kind: .primary)).disabled(testing || store.loadingCredentials || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if testing { ProgressView().controlSize(.small) }
        Spacer()
        Link("OpenRouter 文档", destination: URL(string: "https://openrouter.ai/docs/guides/community/jev")!).font(.caption)
      }
      if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      Text("地址、协议、模型与密钥在保存后一起生效。白名单新消息及必要上下文会发送至已保存的决策服务；密钥保存在 ~/.config/qundao/config.toml。")
        .font(.caption).foregroundStyle(.secondary)
    }.onAppear { key = store.jevKey; apply(store.preferences.jevConfiguration) }
      // 页面保留后不会再次 onAppear；重新显示时从当前配置刷新。
      .onChange(of: pageActive) { _, active in
        if active { key = store.jevKey; apply(store.preferences.jevConfiguration) }
      }
      .onChange(of: store.loadingCredentials) { _, loading in
        if !loading, key.isEmpty { key = store.jevKey }
      }
  }
  private func apply(_ config: JevConfiguration) {
    baseURL = config.baseURL; api = config.api; model = config.model
  }
  @discardableResult private func saveConnection() -> Bool {
    do {
      try store.saveDecisionConnection(config, key: key.trimmingCharacters(in: .whitespacesAndNewlines))
      notice = "决策配置已保存。"
      return true
    } catch { notice = error.localizedDescription; return false }
  }
}
