import Foundation

/// 可编辑的业务指导；协议、证据和安全约束由客户端固定补充。
public enum ModelPrompts {
  public static let maximumBytes = 16_000
  public static let summaryDefault = """
    你是中文群聊阅读助手。整理全部输入，概括重点、当前待办及是否与用户实际相关。
    分段阶段保留任务、答复和已解决信息，简洁压缩，避免丢失后续汇总依据；长消息和中间整理可能跨片段，需结合完整输入判断。
    汇总阶段整合所有片段，结合后续答复消除已经解决的请求，去重重复事项。用户自己的发言、只转述他人、关键词出现但与职责无关都不能判为需要回应。
    不确定时注明不确定，不编造职责、紧急程度或完成状态。摘要和判断依据使用中文，尽量简洁。
    """
  public static let jevDefault = """
    结合当前用户的账号、称呼、关注职责、本地命中以及上下文，分别判断消息是否相关、是否需要当前用户回应。
    相关规则：消息正文提到用户的称呼或关注职责（见“本地命中”）、涉及用户负责的事项、明确向用户求助或面向全群的工作通知，判为相关。纯闲聊、与用户称呼及关注职责都无关、只针对其他人或用户自己的发言，判为不相关。发送人昵称中含有关键词不算正文命中。
    回应规则：有依据向当前用户提出仍未完成的请求，或面向全体成员并要求每人确认、回应或行动，判为需要回应。仅知会、引用或转述他人的请求、已得到答复或已解决的请求、用户自己发言、向其他人求助或证据不足，判为不需要回应。
    """
  public static func effectiveSummary(_ value: String?) -> String { effective(value, fallback: summaryDefault) }
  public static func effectiveJev(_ value: String?) -> String { effective(value, fallback: jevDefault) }
  private static func effective(_ value: String?, fallback: String) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
    return value
  }
  public static func validate(summary: String?, jev: String?) throws {
    for (label, prompt) in [("AI 摘要", summary), ("Jev", jev)] {
      if let prompt, prompt.utf8.count > maximumBytes {
        throw AppFailure.message("\(label) 系统提示词不能超过 \(maximumBytes) 个 UTF-8 字节，请缩短后保存")
      }
    }
  }
}
