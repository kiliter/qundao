import Foundation
import QundaoCore

extension AppStore {
  func attentionEntries(includeHistory: Bool = false) -> [AttentionEntry] {
    AttentionFeed.entries(attentions: snapshot.attentions, digests: snapshot.digests,
                          account: preferences.accountID, includeHistory: includeHistory)
  }

  var pendingFocusCount: Int { attentionEntries().count }
  func readFocusEntries(_ entries: [AttentionEntry]) {
    var digests: Set<UUID> = [], attentions: Set<String> = []
    for entry in entries {
      switch entry {
      case .summary(let item) where item.accountID == preferences.accountID: digests.insert(item.id)
      case .response(let item) where item.message.accountID == preferences.accountID: attentions.insert(item.id)
      default: break
      }
    }
    setViewed(digestIDs: digests, attentionIDs: attentions)
  }
}
