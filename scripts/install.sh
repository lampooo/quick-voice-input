#!/usr/bin/env bash
# 打包并安装「快捷语音输入.app」到 ~/Applications。默认不启动；加 --open 安装后立即打开。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="快捷语音输入"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME.app"
OPEN_AFTER=0
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --open) OPEN_AFTER=1 ;;
    --no-build) SKIP_BUILD=1 ;;
    -h|--help)
      echo "用法：scripts/install.sh [--open] [--no-build]"
      exit 0
      ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

if [[ "$SKIP_BUILD" == "0" ]]; then
  "$ROOT/scripts/build-app.sh"
fi

SRC="$ROOT/build/$APP_NAME.app"
[[ -d "$SRC" ]] || { echo "找不到 $SRC，请先运行 scripts/build-app.sh" >&2; exit 1; }

was_running=0
if pgrep -xq QuickVoice; then
  was_running=1
  echo "==> 退出正在运行的快捷语音输入"
  pkill -TERM -x QuickVoice || true
  for _ in {1..20}; do pgrep -xq QuickVoice || break; sleep 0.2; done
fi

echo "==> 安装到 $DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --strict "$DEST"

cat <<EOF

已安装：$DEST

接下来：
  1. 打开「$APP_NAME」（在 ~/Applications 里双击，或运行 open "$DEST"）。
  2. 按设置向导授予「辅助功能」权限。
  3. 在向导里选语音输入法，把它的「按住说话」快捷键设好（微信输入法推荐右 Option，豆包输入法推荐右 Command；
     网易叭哥说是点按开始、点按结束，推荐 ⌃⌥⇧V，即左 Control + 左 Option + 左 Shift + V），然后点「开始测试…的语音快捷键」。
EOF

if [[ "$OPEN_AFTER" == "1" || "$was_running" == "1" ]]; then
  open "$DEST"
fi
