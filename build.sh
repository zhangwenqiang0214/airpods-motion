#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="AirPodsMotion.app"
echo "→ 清理旧构建"
rm -rf "$APP"

echo "→ 建立 bundle 结构"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ 编译"
xcrun swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/AirPodsMotion"

echo "→ 签名 (ad-hoc)"
codesign -s - -f "$APP" >/dev/null 2>&1

# ad-hoc 签名每次重建 cdhash 都变,TCC 里的旧授权会对不上号。
# 主动清掉,让下次启动重新弹框,避免出现「数据库说已授权、app 拿到 notDetermined」。
echo "→ 重置 TCC 运动权限(下次启动会重新弹框)"
tccutil reset Motion local.tools.airpodsmotion >/dev/null 2>&1 || true

echo "→ 自检"
plutil -lint "$APP/Contents/Info.plist" >/dev/null && echo "   Info.plist 合法"
/usr/libexec/PlistBuddy -c 'Print :NSMotionUsageDescription' "$APP/Contents/Info.plist" >/dev/null \
    && echo "   NSMotionUsageDescription 就位"
codesign -v "$APP" && echo "   签名有效"

echo
echo "✅ 构建完成: $(pwd)/$APP"
echo
echo "⚠️  必须从访达双击启动,不能在终端里跑 —— 终端启动会让 TCC"
echo "   把「责任进程」算到终端头上,直接 SIGABRT 杀掉。"
