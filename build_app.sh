#!/bin/bash
# .appバンドルとしてビルドし直すスクリプト。
# swift runの生バイナリだとIME(IMK)がプロセスを正しく認識できず
# テキスト入力時にウィンドウが不安定になるため、正式なバンドルにする。
set -e

cd "$(dirname "$0")"

CONFIG=${1:-debug}
APP_NAME="FloatPlayer.app"
EXECUTABLE_NAME="FloatPlayer"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

BIN_PATH=".build/$CONFIG/$EXECUTABLE_NAME"

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
cp "$BIN_PATH" "$APP_NAME/Contents/MacOS/$EXECUTABLE_NAME"
cp Info.plist "$APP_NAME/Contents/Info.plist"

# アドホック署名しておく(IME/TCCまわりの認識を安定させるため)
codesign --force --deep --sign - "$APP_NAME"

echo "Built: $(pwd)/$APP_NAME"
echo "起動: open $APP_NAME"
