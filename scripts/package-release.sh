#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/project_config.py version)"
APP_DIR="$PROJECT_DIR/build/FSearch.app"
python3 - "$APP_DIR/Contents/Info.plist" "$VERSION" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
if any(info.get(key) != sys.argv[2] for key in ('CFBundleVersion', 'CFBundleShortVersionString')):
    raise SystemExit('应用版本与 VERSION 不一致，请重新构建后打包。')
PY
ARCHS="$(lipo -archs "$APP_DIR/Contents/MacOS/FSearch")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ARCH=universal ;;
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=x86_64 ;;
    *) printf '不支持的架构：%s\n' "$ARCHS" >&2; exit 1 ;;
esac
DIST_DIR="$PROJECT_DIR/build/release"
ASSET="FSearch-gui-$VERSION-$ARCH"
mkdir -p "$DIST_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/$ASSET.zip"
DMG_STAGE="$(mktemp -d "$PROJECT_DIR/build/dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$APP_DIR" "$DMG_STAGE/FSearch.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "FSearch-gui $VERSION" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DIST_DIR/$ASSET.dmg"
(
    cd "$DIST_DIR"
    shasum -a 256 "$ASSET.zip" "$ASSET.dmg" > "$ASSET.sha256"
)
printf '已打包：%s/%s.zip\n%s/%s.dmg\n' "$DIST_DIR" "$ASSET" "$DIST_DIR" "$ASSET"
