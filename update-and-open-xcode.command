#!/bin/bash
cd "$(dirname "$0")" || exit 1

echo "最新を取り込んでいます (git pull --ff-only)…"
if ! git pull --ff-only; then
  echo ""
  echo "取り込みに失敗しました。"
  echo "ローカルに未コミットの変更があるか、履歴が分岐している可能性があります。"
  echo "変更を退避／破棄してから、もう一度このファイルをダブルクリックしてください。"
  echo ""
  read -r -p "Enter で閉じる…"
  exit 1
fi

if ! open WasureteitaDeshou.xcodeproj; then
  echo ""
  echo "Xcode プロジェクトを開けませんでした: WasureteitaDeshou.xcodeproj"
  echo ""
  read -r -p "Enter で閉じる…"
  exit 1
fi

echo ""
echo "完了。最新を取り込み、Xcode を開きました。"
read -r -p "Enter で閉じる…"
