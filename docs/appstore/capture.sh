#!/bin/zsh
# 在模拟器里用演示数据截 App 的真实界面，供 screenshots.html 嵌进手机框。
#
# 流程：编译 Debug 包 → 准备一台 iPhone 17 Pro Max（6.9 英寸，1320 × 2868）模拟器 → 固定状态栏 →
# 按语言和场景逐个启动 App（--ui-testing-in-memory --appstore-scene <场景>，内存账本，不联网）→ 截图。
# 演示数据和脚本回复见 yadoA/Support/AppStoreScreenshotFixture.swift。
#
# 用法：docs/appstore/capture.sh [zh|en ...]，不带参数时中英文都截。
# 输出：raw/<语言>/<场景>.png
set -euo pipefail

DIR="${0:A:h}"
ROOT="${DIR:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/yadoA-appstore}"
SIM_NAME="yadoA AppStore 6.9"
RUNTIME="${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-2}"

langs=("$@")
(( ${#langs} )) || langs=(zh en)

# 场景:等待秒数:外观
scenes=(voice:9:light home:6:light charts:6:light accounts:7:light chat:10:light home:6:dark)

udid=$(xcrun simctl list devices available | grep "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)
if [[ -z "$udid" ]]; then
  udid=$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max "$RUNTIME")
fi

echo "› 编译 Debug 包"
xcodebuild -project "$ROOT/yadoA.xcodeproj" -scheme yadoA -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DERIVED" build -quiet

app=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" | head -1)
bundle=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app/Info.plist")

echo "› 准备模拟器 $udid"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
xcrun simctl install "$udid" "$app"

for lang in "${langs[@]}"; do
  if [[ $lang == zh ]]; then lang_args=(-AppleLanguages "(zh-Hans)" -AppleLocale zh_CN)
  else lang_args=(-AppleLanguages "(en)" -AppleLocale en_US); fi
  mkdir -p "$DIR/raw/$lang"
  for item in "${scenes[@]}"; do
    scene=${item%%:*}; rest=${item#*:}; wait=${rest%%:*}; look=${rest#*:}
    name=$scene; [[ $look == dark ]] && name="$scene-dark"
    xcrun simctl ui "$udid" appearance "$look"
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl launch "$udid" "$bundle" --ui-testing-in-memory --appstore-scene "$scene" \
      -home.summary.amountsVisible YES "${lang_args[@]}" >/dev/null
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "$DIR/raw/$lang/$name.png" >/dev/null 2>&1
    echo "raw/$lang/$name.png"
    # 对话页发出的小票照片；下次启动时没被引用的图片会被清理，趁现在拷出来
    if [[ $scene == chat ]]; then
      images="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Library/Application Support/yadoA/ChatImages"
      latest=$(ls -t "$images" | head -1)
      [[ -n "$latest" ]] && cp "$images/$latest" "$DIR/raw/$lang/receipt.jpg" && echo "raw/$lang/receipt.jpg"
    fi
  done
done
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl ui "$udid" appearance light
