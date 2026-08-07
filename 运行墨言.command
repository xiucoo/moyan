#!/bin/bash
# 双击运行已编译的墨言 App（需先在 Xcode 里 ⌘B 编译过）
APP=$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Moyan-*/Build/Products/Debug/Moyan.app 2>/dev/null | head -1)
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  osascript -e 'display alert "未找到已编译的墨言" message "请先双击「打开墨言工程.command」，在 Xcode 里按 ⌘B 编译后再试。" as critical'
  exit 1
fi
open -n "$APP"
