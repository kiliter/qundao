import SwiftUI

/// 标签按文字实际宽度从左向右换行，不使用等宽网格。
struct TagFlowLayout: Layout {
  var spacing: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? 600, subviews: subviews).size
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for (index, item) in result.frames.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + item.minX, y: bounds.minY + item.minY),
                           proposal: ProposedViewSize(item.size))
    }
  }
  private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
    var frames: [CGRect] = []
    for subview in subviews {
      var size = subview.sizeThatFits(.unspecified)
      size.width = min(width, size.width)
      if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
    }
    return (CGSize(width: width, height: y + rowHeight), frames)
  }
}
