#!/bin/bash
set -e
cd "$(dirname "$0")/.."
git fetch origin
git checkout cursor/wasureteita-stage1-aaa9
git reset --hard origin/cursor/wasureteita-stage1-aaa9
git log -1 --oneline
open WasureteitaDeshou/WasureteitaDeshou.xcodeproj
echo "完了。Xcode で Team を確認して実機 Run してください。"
read -r -p "Enter で閉じる…"
