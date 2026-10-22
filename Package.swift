// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "Qundao", platforms: [.macOS(.v14)],
  products: [.executable(name: "Qundao", targets: ["Qundao"])],
  targets: [
    .target(name: "QundaoCore"), .executableTarget(name: "Qundao", dependencies: ["QundaoCore"]),
    .testTarget(name: "QundaoCoreTests", dependencies: ["QundaoCore"]),
    .testTarget(name: "QundaoTests", dependencies: ["Qundao"]),
  ])
