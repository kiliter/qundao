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
  func captureFocusSelection(_ entries: [AttentionEntry]) -> ReadingSelection {
    ReadingSelection(entries: entries, attentions: snapshot.attentions, account: preferences.accountID)
  }
  func readFocusSelection(_ selection: ReadingSelection) {
    guard selection.account == preferences.accountID else { return }
    setViewed(digestIDs: selection.digestIDs, attentionIDs: selection.attentionIDs)
  }
  func readFocusEntries(_ entries: [AttentionEntry]) {
    readFocusSelection(captureFocusSelection(entries))
  }
}
