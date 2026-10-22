#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="Qundao"
APP_BUNDLE="$ROOT_DIR/dist/群岛.app"
INSTALLED_BUNDLE="/Applications/群岛.app"
# 复用本机已有的固定本地开发身份；不自动替换证书，也不修改系统信任。
SIGN_IDENTITY="${QUNDAO_SIGNING_IDENTITY:-D01BDF064D9EDF0FBA392837F0A22632515F7F4E}"
if [[ "$MODE" != "--build-only" ]]; then
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
# 安装包默认用 Release（开启编译优化，SwiftUI 渲染明显更快）；--debug 才用 Debug 以便 lldb 调试。
CONFIG="release"
if [[ "$MODE" == "--debug" ]]; then CONFIG="debug"; fi
swift build -c "$CONFIG" --scratch-path .build
BUILD_DIR="$(swift build -c "$CONFIG" --scratch-path .build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" || "$ROOT_DIR/script/make_icon.swift" -nt "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  swift "$ROOT_DIR/script/make_icon.swift" "$ROOT_DIR/Resources"
fi
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"; fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Qundao</string>
<key>CFBundleIdentifier</key><string>cn.kiliter.qundao</string>
<key>CFBundleName</key><string>群岛</string>
<key>CFBundleDisplayName</key><string>群岛</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>连接本机 Alpha 微信消息服务，读取你选择的账号消息。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --identifier cn.kiliter.qundao --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
if [[ "$MODE" == "--build-only" ]]; then
  echo "已构建并签名：$APP_BUNDLE"
  exit 0
fi
/usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$INSTALLED_BUNDLE"
# 更新本应用的资源修改时间与注册信息，让 Finder / Dock 重新读取图标。
/usr/bin/touch "$INSTALLED_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED_BUNDLE"
case "$MODE" in
  run|--verify) /usr/bin/open -n "$INSTALLED_BUNDLE" ;;
  --debug) /usr/bin/lldb -- "$INSTALLED_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|--telemetry) /usr/bin/open -n "$INSTALLED_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Qundao"' ;;
  *) echo "支持参数：--build-only、--verify、--debug、--logs、--telemetry" >&2;exit 2 ;;
esac
if [[ "$MODE" == "--verify" ]]; then sleep 2;/usr/bin/pgrep -x "$APP_NAME" >/dev/null;echo '群岛已从 /Applications 启动';fi
