import Foundation
import NaturalLanguage

/// 只用系统本地嵌入做候选筛选；最终相关性仍由 CPA 结合原文核对。
final class SemanticFilter {
  private let embedding = NLEmbedding.wordEmbedding(for: .simplifiedChinese)
  var available: Bool { embedding != nil }
  func matches(_ text: String, keywords: [String]) -> Bool {
    guard let embedding, !keywords.isEmpty else { return false }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = String(text.prefix(1000))
    tokenizer.setLanguage(.simplifiedChinese)
    var words: [String] = []
    tokenizer.enumerateTokens(in: tokenizer.string!.startIndex..<tokenizer.string!.endIndex) {
      range, _ in
      let word = String(tokenizer.string![range])
      if word.count > 1, embedding.contains(word) { words.append(word) }
      return words.count < 60
    }
    var topics = Set(keywords.filter { embedding.contains($0) })
    let topicTokenizer = NLTokenizer(unit: .word)
    topicTokenizer.string = keywords.joined(separator: " ")
    topicTokenizer.setLanguage(.simplifiedChinese)
    if let topicText = topicTokenizer.string {
      topicTokenizer.enumerateTokens(in: topicText.startIndex..<topicText.endIndex) { range, _ in
        let term = String(topicText[range])
        if term.count > 1, embedding.contains(term) { topics.insert(term) }
        return topics.count < 60
      }
    }
    for keyword in topics {
      for word in words
      where embedding.distance(between: keyword, and: word, distanceType: .cosine) < 0.35 {
        return true
      }
    }
    return false
  }
}
