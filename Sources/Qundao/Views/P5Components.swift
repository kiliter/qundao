import SwiftUI

/// 主窗口的纸片控件。正文保持正向，倾斜只用于标题、标签和选中态。
struct P5ButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, quiet }
  var kind: Kind = .secondary
  var compact = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: compact ? 11 : 12, weight: .semibold))
      .lineLimit(1).padding(.horizontal, compact ? 9 : 13).padding(.vertical, compact ? 6 : 8)
      .foregroundStyle(kind == .primary ? Color.white : P5.ink)
      .background {
        if kind != .quiet {
          P5Slant(slant: 0.035).fill(kind == .primary ? P5.ink : .white)
            .shadow(color: kind == .primary ? P5.red : .clear, radius: 0, x: 3, y: 3)
          P5Slant(slant: 0.035).stroke(P5.ink, lineWidth: 1.2)
        }
      }
      .contentShape(Rectangle())
      .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
      .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
  }
}

struct P5TextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    P5FieldSurface { configuration.textFieldStyle(.plain) }
  }
}

private struct P5FieldSurface<Content: View>: View {
  @ViewBuilder var content: Content
  @FocusState private var focused: Bool
  var body: some View {
    content.focused($focused).padding(.horizontal, 10).padding(.vertical, 9)
      .background(.white)
      .overlay(Rectangle().stroke(focused ? P5.red : P5.ink.opacity(0.3), lineWidth: focused ? 2 : 1))
  }
}

struct P5PaperCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 16) { content }
      .frame(maxWidth: .infinity, alignment: .leading).padding(20)
      .background(.white)
      .overlay(Rectangle().stroke(P5.ink, lineWidth: 1.2))
      .background(P5.ink.offset(x: 4, y: 4))
      .padding(.trailing, 4).padding(.bottom, 4)
  }
}

struct P5SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(P5.heavy(14)).foregroundStyle(.white)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(P5.ink, in: P5Slant(slant: 0.04))
      .accessibilityAddTraits(.isHeader)
  }
}

struct P5Badge: View {
  let text: String
  var color: Color = P5.red
  var body: some View {
    Text(text).font(.system(size: 10, weight: .bold)).lineLimit(1)
      .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
      .background(color, in: P5Slant(slant: 0.035))
  }
}

struct P5PageHeader<Actions: View>: View {
  let title: String
  let subtitle: String
  var count: Int? = nil
  @ViewBuilder var actions: Actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 17) {
          P5Ransom(text: title, scale: 1.5)
          if let count {
            Text(verbatim: count < 10 ? "0\(count)" : "\(count)")
              .font(P5.numeral(count > 999 ? 18 : 24)).foregroundStyle(.white)
              .minimumScaleFactor(0.7).lineLimit(1).padding(10)
              .frame(width: 58, height: 58).background(P5Burst().fill(P5.ink))
              .contentTransition(.numericText())
              .animation(reduceMotion ? nil : P5.pop, value: count)
              .accessibilityLabel("\(count) 条待关注")
          }
        }.frame(height: 48, alignment: .leading)
        Text(subtitle).font(.system(size: 11)).foregroundStyle(P5.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }.layoutPriority(1)
      Spacer(minLength: 0)
      actions
    }.padding(.horizontal, 26).padding(.vertical, 17)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        P5.paper
        GeometryReader { proxy in
          P5Slant(slant: 0.2).fill(P5.red.opacity(0.94))
            .frame(width: 105, height: 120).rotationEffect(.degrees(10))
            .offset(x: proxy.size.width - 57, y: -34)
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
      }
      .overlay(alignment: .bottom) { Rectangle().fill(P5.ink).frame(height: 2) }
  }
}

struct PageHeading: View {
  let title: String
  let subtitle: String
  var body: some View { P5PageHeader(title: title, subtitle: subtitle) { EmptyView() } }
}

/// 随可用宽度切换一列 / 两列，不重建表单节点，保留输入和焦点。
struct P5SettingsColumns: Layout {
  var minimum: CGFloat = 330
  var spacing: CGFloat = 22
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? minimum
    return CGSize(width: width, height: measurements(width: width, subviews: subviews).height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let m = measurements(width: bounds.width, subviews: subviews)
    var y = bounds.minY
    for row in m.rows {
      for (column, index) in row.indices.enumerated() {
        subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (m.columnWidth + spacing), y: y),
                             proposal: ProposedViewSize(width: m.columnWidth, height: row.height))
      }
      y += row.height + spacing
    }
  }
  private struct Row { let indices: [Int]; let height: CGFloat }
  private func measurements(width: CGFloat, subviews: Subviews) -> (columnWidth: CGFloat, rows: [Row], height: CGFloat) {
    let columns = width >= minimum * 2 + spacing ? 2 : 1
    let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    var rows: [Row] = []
    for start in stride(from: 0, to: subviews.count, by: columns) {
      let indices = Array(start..<min(start + columns, subviews.count))
      let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
      rows.append(Row(indices: indices, height: height))
    }
    return (columnWidth, rows, rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing)
  }
}

struct P5EmptyState: View {
  let title: String
  let message: String
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "text.bubble").font(.system(size: 25, weight: .bold))
        .foregroundStyle(.white).frame(width: 66, height: 66).background(P5Burst().fill(P5.ink))
      Text(title).font(.headline)
      Text(message).font(.caption).foregroundStyle(P5.secondary).multilineTextAlignment(.center)
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// 阅读底纸仅画静态网点；不添加持续时钟或逐帧更新。
struct P5ReadingBackground: View {
  var body: some View {
    P5.paper.overlay {
      Canvas(rendersAsynchronously: true) { context, size in
        var dots = Path()
        for y in stride(from: CGFloat(3), to: size.height, by: 7) {
          for x in stride(from: CGFloat(3), to: size.width, by: 7) {
            dots.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
          }
        }
        context.fill(dots, with: .color(P5.ink.opacity(0.06)))
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
