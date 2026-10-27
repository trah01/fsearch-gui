#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
cargo build --release
swift build --package-path macos -c release
SWIFT_BIN="$(swift build --package-path macos -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/FSearch.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$SWIFT_BIN/FSearch" "$APP_DIR/Contents/MacOS/FSearch"
cp target/release/fsearch "$APP_DIR/Contents/Resources/fsearch"
ICONSET_DIR="$PROJECT_DIR/build/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" macos/Resources/AppIcon.png --out "$ICONSET_DIR/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    RETINA_SIZE=$((ICON_SIZE * 2))
    sips -z "$RETINA_SIZE" "$RETINA_SIZE" macos/Resources/AppIcon.png --out "$ICONSET_DIR/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FSearch</string>
<key>CFBundleIdentifier</key><string>cn.trah.fsearch.desktop</string>
<key>CFBundleName</key><string>FSearch</string>
<key>CFBundleDisplayName</key><string>FSearch</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>FSearch 需要读取外置硬盘中的文件名，以建立文件搜索索引。</string>
<key>NSNetworkVolumesUsageDescription</key><string>FSearch 需要读取已连接网络磁盘中的文件名，以便搜索文件。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR/Contents/Resources/fsearch"
codesign --force --sign - "$APP_DIR"
printf '已构建：%s\n运行：open "%s"\n' "$APP_DIR" "$APP_DIR"
