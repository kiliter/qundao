import AppKit

// 群岛 P5 图标：本地矢量绘制，所有尺寸直接渲染，不依赖字体或外部素材。
// 运行：swift script/make_icon.swift [输出目录]，默认输出到仓库 Resources。
let output = CommandLine.arguments.count > 1
  ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources", isDirectory: true)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("qundao-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

let ink = CGColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)
let red = CGColor(srgbRed: 0.902, green: 0, blue: 0.071, alpha: 1)
let paper = CGColor(srgbRed: 0.985, green: 0.98, blue: 0.965, alpha: 1)

func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: points[0].0, y: points[0].1))
  for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
  path.closeSubpath()
  return path
}

func drawIcon(pixels: Int) throws -> Data {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    throw NSError(domain: "群岛图标", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建图形画布"])
  }
  let scale = CGFloat(pixels) / 1024
  context.scaleBy(x: scale, y: scale)
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)
  context.setAllowsAntialiasing(true)

  func fill(_ path: CGPath, _ color: CGColor) {
    context.setFillColor(color); context.addPath(path); context.fillPath()
  }
  func outlined(_ path: CGPath, color: CGColor, width: CGFloat) {
    context.setFillColor(color); context.setStrokeColor(ink); context.setLineWidth(width)
    context.setLineJoin(.miter); context.setMiterLimit(3)
    context.addPath(path); context.drawPath(using: .fillStroke)
  }

  // macOS 图标保留透明外边距；轻量外阴影不会侵入符号。
  let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                    cornerWidth: 200, cornerHeight: 200, transform: nil)
  context.saveGState()
  // Core Graphics 阴影使用设备空间，必须显式随像素尺寸缩放。
  context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 15 * scale,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.2))
  fill(tile, ink)
  context.restoreGState()
  context.saveGState()
  context.addPath(tile); context.clip()

  // 大块斜切红纸与黑色留白构成图标的主轮廓。
  fill(polygon([(176, 136), (932, 244), (840, 940), (72, 776)]), red)

  // 只在较大尺寸保留浅网点，避免 Finder 列表图标产生噪点。
  if pixels >= 128 {
    let dot = CGColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 0.19)
    for y in stride(from: 642, through: 850, by: 26) {
      for x in stride(from: 664, through: 872, by: 26) {
        fill(CGPath(ellipseIn: CGRect(x: x, y: y, width: 7, height: 7), transform: nil), dot)
      }
    }
  }

  // 剪纸对话框：明显的对话尾角和黑色硬阴影，在小尺寸仍保持可识别。
  let bubble = polygon([(226, 328), (746, 250), (817, 625), (583, 663),
                        (421, 822), (415, 685), (260, 708)])
  context.saveGState()
  context.translateBy(x: 24, y: 28)
  fill(bubble, ink)
  context.restoreGState()
  outlined(bubble, color: paper, width: 16)

  // 消息线条与刘海的粗黑条呼应；16 像素时加厚以保留形状。
  let weight: CGFloat = pixels <= 32 ? 10 : 0
  fill(polygon([(320, 412), (652, 364), (665, 432 + weight), (333, 480 + weight)]), ink)
  fill(polygon([(344, 532), (559, 501), (570, 558 + weight), (355, 589 + weight)]), ink)

  // 四芒星沿用主窗口徽记，作为「需要关注」的视觉重心。
  let spark = polygon([(780, 122), (816, 215), (911, 246), (816, 279),
                       (783, 380), (749, 282), (650, 251), (745, 215)])
  context.saveGState()
  context.translateBy(x: 9, y: 12)
  fill(spark, ink)
  context.restoreGState()
  outlined(spark, color: paper, width: 23)
  context.restoreGState()

  guard let image = context.makeImage(),
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    throw NSError(domain: "群岛图标", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法输出 PNG"])
  }
  return png
}

for size in [16, 32, 128, 256, 512] {
  for density in [1, 2] {
    let suffix = density == 2 ? "@2x" : ""
    try drawIcon(pixels: size * density).write(
      to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
let encodedIcon = temporary.appendingPathComponent("AppIcon.icns")
let encoder = Process()
encoder.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
encoder.arguments = ["-c", "icns", "-o", encodedIcon.path, iconset.path]
try encoder.run(); encoder.waitUntilExit()
guard encoder.terminationStatus == 0 else {
  throw NSError(domain: "群岛图标", code: 3, userInfo: [NSLocalizedDescriptionKey: "ICNS 打包失败"])
}
try Data(contentsOf: encodedIcon).write(to: output.appendingPathComponent("AppIcon.icns"), options: .atomic)
try drawIcon(pixels: 1024).write(to: output.appendingPathComponent("AppIcon.png"), options: .atomic)
print("已生成群岛 P5 图标：\(output.path)")
