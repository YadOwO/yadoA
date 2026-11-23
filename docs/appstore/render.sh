#!/bin/zsh
# 用本机 Chrome 无头模式把 screenshots.html 导出成 App Store 截图（6.9 英寸，1320 × 2868）。
# 用法：docs/appstore/render.sh [zh|en ...]，不带参数时中英文都导出。
# 输出：out/<语言>/01.png … 07.png，以及并排预览 out/preview-<语言>.png。
set -euo pipefail

DIR="${0:A:h}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT

langs=("$@")
(( ${#langs} )) || langs=(zh en)

shoot() { # $1 输出文件  $2 宽  $3 高  $4 URL
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" --force-device-scale-factor=1 --window-size="$2,$3" \
    --virtual-time-budget=5000 --screenshot="$1" "$4" >/dev/null 2>&1
}

for lang in "${langs[@]}"; do
  mkdir -p "$DIR/out/$lang"
  for f in 1 2 3 4 5 6 7; do
    shoot "$DIR/out/$lang/0$f.png" 1320 2868 "file://$DIR/screenshots.html#f=$f&lang=$lang"
    echo "out/$lang/0$f.png"
  done
  shoot "$DIR/out/preview-$lang.png" 3080 1000 "file://$DIR/preview.html#lang=$lang"
  echo "out/preview-$lang.png"
done
