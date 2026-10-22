import QundaoCore
import SwiftUI

/// 刘海 P5 风格的配色与图形：红 / 黑 / 白三色，斜切块、爆炸星、网点与斜条纹。
/// 只用系统图形绘制，不引用游戏素材。
enum P5 {
  static let red = Color(red: 0.902, green: 0, blue: 0.071)
  static let paper = Color(red: 0.969, green: 0.961, blue: 0.941)
  static let ink = Color(red: 0.067, green: 0.067, blue: 0.067)
  static let dark = Color(white: 0.11)
  static let grey = Color(white: 0.55)
  /// 斜切与旋转是静态装饰，减少动态效果时同样保留；动画另由调用方按设置关闭。
  static let snap = Animation.timingCurve(0.7, 0, 0.2, 1, duration: 0.32)
  static let pop = Animation.spring(duration: 0.3, bounce: 0.45)

  static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .black) }
  /// 数字与时间：斜体粗字。
  static func numeral(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).italic().monospacedDigit() }
}

/// 平行四边形：`slant` 为顶边相对底边右移的比例（负值向左倾）。
struct P5Slant: Shape {
  var slant: CGFloat = 0.06
  func path(in rect: CGRect) -> Path {
    let dx = rect.width * slant
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + max(0, dx), y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - max(0, dx), y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// 卡片底板：固定像素的斜切量，不随卡片高度变形。
struct P5CardShape: Shape {
  var inset: CGFloat = 7
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 1))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 2))
    path.closeSubpath()
    return path
  }
}

/// 箭头段：流水线的一节；`first` 时左边是平的。
struct P5Chevron: Shape {
  var first = false
  func path(in rect: CGRect) -> Path {
    let tip = min(7, rect.height * 0.32)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - tip, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX - tip, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    if !first { path.addLine(to: CGPoint(x: rect.minX + tip, y: rect.midY)) }
    path.closeSubpath()
    return path
  }
}

/// 不规则四边形头像底。
struct P5Shard: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.06))
    path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.08))
    path.closeSubpath()
    return path
  }
}

/// 多角爆炸星。
struct P5Burst: Shape {
  var points = 12
  var inner: CGFloat = 0.55
  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outer = min(rect.width, rect.height) / 2
    // 半径交替且略有抖动，形成手撕感；抖动是确定的，不随重绘变化。
    let jitter: [CGFloat] = [1, 0.86, 0.97, 0.9, 1, 0.84, 0.95, 0.92, 0.99, 0.87, 0.94, 0.9]
    var path = Path()
    for index in 0..<(points * 2) {
      let angle = CGFloat(index) * .pi / CGFloat(points) - .pi / 2
      let radius = index.isMultiple(of: 2) ? outer * jitter[(index / 2) % jitter.count] : outer * inner
      let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }
}

/// 四角星徽记（收起态与状态牌使用）。
struct P5Spark: Shape {
  func path(in rect: CGRect) -> Path {
    let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, w = r * 0.26
    var path = Path()
    path.move(to: CGPoint(x: c.x, y: c.y - r))
    path.addLine(to: CGPoint(x: c.x + w, y: c.y - w))
    path.addLine(to: CGPoint(x: c.x + r, y: c.y))
    path.addLine(to: CGPoint(x: c.x + w, y: c.y + w))
    path.addLine(to: CGPoint(x: c.x, y: c.y + r))
    path.addLine(to: CGPoint(x: c.x - w, y: c.y + w))
    path.addLine(to: CGPoint(x: c.x - r, y: c.y))
    path.addLine(to: CGPoint(x: c.x - w, y: c.y - w))
    path.closeSubpath()
    return path
  }
}

/// 展开面板背景：右上红色斜块与白条、渐隐网点、左下红斜纹。静态绘制，只在尺寸变化时重绘。
struct P5Backdrop: View {
  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      // 网点：右上浓、向左下渐隐。
      let step: CGFloat = 8
      var y: CGFloat = 4
      while y < min(size.height, 260) {
        var x: CGFloat = 4
        while x < size.width {
          let fade = max(0, 1 - (size.width - x) / size.width * 0.9 - y / 260)
          if fade > 0.04 {
            context.fill(Path(ellipseIn: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)),
                         with: .color(.white.opacity(0.08 * fade)))
          }
          x += step
        }
        y += step
      }
      // 右上红色斜块：只占标题区右侧，下沿斜切，不压住状态条。
      var slash = Path()
      slash.move(to: CGPoint(x: size.width - 178, y: 0))
      slash.addLine(to: CGPoint(x: size.width, y: 0))
      slash.addLine(to: CGPoint(x: size.width, y: 48))
      slash.addLine(to: CGPoint(x: size.width - 196, y: 66))
      slash.closeSubpath()
      context.fill(slash, with: .color(P5.red))
      var bar = Path()
      bar.move(to: CGPoint(x: size.width - 120, y: 70))
      bar.addLine(to: CGPoint(x: size.width - 14, y: 59))
      bar.addLine(to: CGPoint(x: size.width - 14, y: 64))
      bar.addLine(to: CGPoint(x: size.width - 120, y: 75))
      bar.closeSubpath()
      context.fill(bar, with: .color(.white))
      // 左下红斜纹。
      context.drawLayer { layer in
        var clip = Path()
        clip.move(to: CGPoint(x: 0, y: size.height - 120))
        clip.addLine(to: CGPoint(x: 120, y: size.height - 170))
        clip.addLine(to: CGPoint(x: 90, y: size.height))
        clip.addLine(to: CGPoint(x: 0, y: size.height))
        clip.closeSubpath()
        layer.clip(to: clip)
        var stripe = CGFloat(-300)
        while stripe < 300 {
          var line = Path()
          line.move(to: CGPoint(x: stripe, y: size.height))
          line.addLine(to: CGPoint(x: stripe + 6, y: size.height))
          line.addLine(to: CGPoint(x: stripe + 6 + 300, y: size.height - 430))
          line.addLine(to: CGPoint(x: stripe + 300, y: size.height - 430))
          line.closeSubpath()
          layer.fill(line, with: .color(P5.red.opacity(0.13)))
          stripe += 16
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// 剪报拼贴标题：每个字一块，底色、字号、角度各不相同。
struct P5Ransom: View {
  let text: String
  private static let styles: [(bg: Color, fg: Color, size: CGFloat, angle: Double, dy: CGFloat)] = [
    (.white, .black, 18, -6, 0), (.black, .white, 14.5, 4, -2), (P5.red, .white, 19, -3, 1), (.white, P5.red, 15.5, 7, 0),
  ]
  var body: some View {
    HStack(alignment: .bottom, spacing: 2) {
      ForEach(Array(text.enumerated()), id: \.offset) { index, char in
        let style = Self.styles[index % Self.styles.count]
        Text(String(char)).font(P5.heavy(style.size)).foregroundStyle(style.fg)
          .padding(.horizontal, 3.5).padding(.vertical, 2.5)
          .background(style.bg)
          .overlay { if style.bg == .black { Rectangle().stroke(.white, lineWidth: 1.5) } }
          .rotationEffect(.degrees(style.angle))
          .offset(y: style.dy)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .accessibilityAddTraits(.isHeader)
  }
}

/// 「找你 / 需回应」贴纸：明确提及为红底，需回应为黑底；角度略歪。
struct P5Tags: View {
  let tags: [Attention]
  var inverted = false
  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(tags.prefix(3).enumerated()), id: \.element.id) { index, tag in
        Text(tag.title).font(P5.heavy(10)).lineLimit(1)
          .foregroundStyle(tag.definite ? .white : (inverted ? .black : .white))
          .padding(.horizontal, 7).padding(.vertical, 3)
          .background(tag.definite ? P5.red : (inverted ? .white : .black), in: P5Slant(slant: 0.04))
          .rotationEffect(.degrees(index.isMultiple(of: 2) ? -3 : 2))
          .help(tag.reason)
      }
      if tags.count > 3 { Text("+\(tags.count - 3)").font(P5.heavy(10)).foregroundStyle(P5.grey) }
    }.accessibilityElement(children: .combine)
  }
}
