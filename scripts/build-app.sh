#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(python3 scripts/project_config.py version)"
python3 scripts/project_config.py sync-cargo
SWIFT_ARGS=(--package-path macos -c release --disable-keychain)
if [ "${FSEARCH_UNIVERSAL:-0}" = "1" ]; then
    export MACOSX_DEPLOYMENT_TARGET=13.0
    export CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS="-C target-cpu=apple-m1"
    export CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS="-C target-cpu=x86-64"
    cargo build --release --locked --target aarch64-apple-darwin
    cargo build --release --locked --target x86_64-apple-darwin
    SWIFT_ARGS+=(--arch arm64 --arch x86_64)
else
    cargo build --release --locked
fi
swift build "${SWIFT_ARGS[@]}"
SWIFT_BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/FSearch.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# Do not carry frameworks or signatures from a previous build into the new bundle.
python3 - "$APP_DIR" <<'PY'
from pathlib import Path
import shutil
import sys
app = Path(sys.argv[1])
for relative in ('Contents/Frameworks/Sparkle.framework', 'Contents/_CodeSignature'):
    path = app / relative
    if path.is_symlink():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)
PY
cp "$SWIFT_BIN/FSearch" "$APP_DIR/Contents/MacOS/FSearch"
ditto "$SWIFT_BIN/FSearch_FSearch.bundle" "$APP_DIR/Contents/Resources/FSearch_FSearch.bundle"
for APP_LANGUAGE in en zh-Hans; do
    ditto "macos/Resources/$APP_LANGUAGE.lproj" "$APP_DIR/Contents/Resources/$APP_LANGUAGE.lproj"
done
if [ "${FSEARCH_UNIVERSAL:-0}" = "1" ]; then
    lipo -create target/aarch64-apple-darwin/release/fsearch target/x86_64-apple-darwin/release/fsearch \
        -output "$APP_DIR/Contents/Resources/fsearch"
else
    cp target/release/fsearch "$APP_DIR/Contents/Resources/fsearch"
fi
ICONSET_DIR="$PROJECT_DIR/build/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" macos/Resources/AppIcon.png --out "$ICONSET_DIR/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    RETINA_SIZE=$((ICON_SIZE * 2))
    sips -z "$RETINA_SIZE" "$RETINA_SIZE" macos/Resources/AppIcon.png --out "$ICONSET_DIR/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
python3 scripts/project_config.py write-info --output "$APP_DIR/Contents/Info.plist"
cp VERSION "$APP_DIR/Contents/Resources/VERSION"
codesign --force --sign - "$APP_DIR/Contents/Resources/fsearch"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf '已构建 FSearch %s：%s\n运行：open "%s"\n' "$VERSION" "$APP_DIR" "$APP_DIR"
