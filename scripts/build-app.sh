#!/usr/bin/env bash
# 编译并打包「快捷语音输入.app」到 build/ 目录，然后签名。
#
# 环境变量：
#   SIGN_IDENTITY  指定签名证书名称；不指定时自动选用钥匙串里的 Apple Development /
#                  Developer ID 证书，找不到则用 ad-hoc 签名（每次重新打包都要重新授权）。
#   BUNDLE_ID      指定 Bundle ID；不指定时沿用 ~/Applications 里已安装版本的，
#                  没装过则用 com.quickvoiceinput.app。
#   UNIVERSAL=1    同时编译 arm64 和 x86_64。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="快捷语音输入"
DEFAULT_BUNDLE_ID="com.quickvoiceinput.app"
INSTALLED_INFO="$HOME/Applications/$APP_NAME.app/Contents/Info.plist"
# 「辅助功能」授权和设置都跟着 Bundle ID 走，换了就要重新授权，所以优先沿用已安装的。
if [[ -z "${BUNDLE_ID:-}" && -f "$INSTALLED_INFO" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_INFO" 2>/dev/null || true)"
fi
BUNDLE_ID="${BUNDLE_ID:-$DEFAULT_BUNDLE_ID}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "无效的 Bundle ID：$BUNDLE_ID" >&2
  exit 1
fi
VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

arch_flags=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi

echo "==> 编译 release 版本"
swift build -c release --product QuickVoice ${arch_flags[@]+"${arch_flags[@]}"}
BIN_DIR="$(swift build -c release --product QuickVoice ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"

echo "==> 组装 $APP_NAME.app（$BUNDLE_ID）"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$BIN_DIR/QuickVoice" "$APP/Contents/MacOS/QuickVoice"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'CFBundleDisplayName = "%s";\nCFBundleName = "%s";\n' "$APP_NAME" "$APP_NAME" \
  > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ICON_CACHE="$ROOT/.build/icon"
if [[ ! -f "$ICON_CACHE/AppIcon.icns" || "$ROOT/scripts/make-icon.swift" -nt "$ICON_CACHE/AppIcon.icns" ]]; then
  echo "==> 生成图标"
  rm -rf "$ICON_CACHE"
  mkdir -p "$ICON_CACHE"
  swift "$ROOT/scripts/make-icon.swift" "$ICON_CACHE/AppIcon.iconset" >/dev/null
  iconutil -c icns "$ICON_CACHE/AppIcon.iconset" -o "$ICON_CACHE/AppIcon.icns"
fi
cp "$ICON_CACHE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"(Apple Development|Developer ID Application):/ { print $2; exit }')"
fi
identity="${identity:--}"

# 钥匙串如果弹框等待确认，60 秒后放弃并改用 ad-hoc，避免脚本卡住。
sign() {
  perl -e 'alarm shift @ARGV; exec @ARGV' 60 \
    /usr/bin/codesign --force --sign "$1" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
}

echo "==> 签名（$identity）"
if ! sign "$identity"; then
  if [[ "$identity" != "-" ]]; then
    echo "!! 用「$identity」签名失败，改用 ad-hoc 签名" >&2
    identity="-"
    sign "-"
  else
    exit 1
  fi
fi
codesign --verify --strict "$APP"

echo "==> 完成：$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)=" | head -2 || true
if [[ "$identity" == "-" ]]; then
  echo "提示：当前是 ad-hoc 签名，以后每次重新打包都需要在「辅助功能」里重新授权。"
fi
