import Foundation
import QundaoCore

extension AppStore {
  func attentionEntries(includeHistory: Bool = false) -> [AttentionEntry] {
    if includeHistory {
      return AttentionFeed.entries(attentions: allAttentions, digests: allDigests,
                                   account: preferences.accountID, includeHistory: true)
    }
    return pendingAttention.entries
  }

  /// 仅待阅记录；快照或账号变化后重新计算。
  var pendingAttention: (entries: [AttentionEntry], threads: [AttentionThread]) {
    _ = digestsRevision; _ = attentionsRevision
    let account = preferences.accountID
    if let cache = attentionCache, cache.account == account { return (cache.entries, cache.threads) }
    let entries = AttentionFeed.entries(attentions: snapshot.attentions, digests: snapshot.digests, account: account)
    let threads = AttentionFeed.threads(attentions: snapshot.attentions, digests: snapshot.digests, account: account)
    attentionCache = (account, entries, threads)
    return (entries, threads)
  }

  func summaryThreads(onlyRelated: Bool) -> [SummaryThread] {
    _ = digestsRevision; _ = groupsRevision
    let account = preferences.accountID, synced = groupStatesSynced
    if let cache = summaryThreadCache[onlyRelated], cache.account == account, cache.synced == synced { return cache.threads }
    let threads = SummaryTimeline.threads(digests: snapshot.digests, groups: snapshot.groups, account: account,
                                          onlyRelated: onlyRelated)
    summaryThreadCache[onlyRelated] = (account, synced, threads)
    return threads
  }

  var pendingFocusCount: Int { pendingAttention.entries.count }
  func readFocusEntries(_ entries: [AttentionEntry]) {
    var digests: Set<UUID> = [], attentions: Set<String> = []
    for entry in entries {
      switch entry {
      case .summary(let item) where item.accountID == preferences.accountID:
        digests.insert(item.id)
        // 并入卡片的「找你 / 需回应」提醒随摘要一起已阅，避免标签消失后提醒仍留在后台。
        let keys = Set(item.evidence.map(\.key))
        for attention in snapshot.attentions where attention.status != "done" && attention.message.accountID == item.accountID
          && attention.message.groupID == item.groupID && keys.contains(attention.message.key) {
          attentions.insert(attention.id)
        }
      case .response(let item) where item.message.accountID == preferences.accountID: attentions.insert(item.id)
      default: break
      }
    }
    setViewed(digestIDs: digests, attentionIDs: attentions)
  }
}
