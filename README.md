# 忘れていたでしょう（iOS）

指定場所に近づいたら知らせる忘れ物防止アプリ（Swift / SwiftUI / iOS 18+）。入力はテキスト中心。音声は iOS キーボードのマイクから。

## 実装済み

- **第1**: テキスト入力・「次へ」
- **第2**: 場所／用事抽出、MapKit 検索・候補／地図、予定一覧
- **第3**: 接近時ローカル通知（300/500/1000m）、専用音 `piroriron.caf`、Always 位置の導線
- **第4**: 店舗付近の滞在で自動解除、履歴、ワンタップ再登録
- **自宅**: 設定で自宅を保存し、「帰ったら洗濯」などを自宅へ登録（`stage4-home-1`）
- **呼び名**: 登録した場所を端末内に覚え、次回検索で候補先頭に出す（`stage4-places-1`）
- **接近通知の重複抑止**: 圏内にいるあいだ1回まで（`stage4-dedupe-1`）
- **第5（前面読み上げ）**: `AVSpeechSynthesizer` で用事文を読み上げ（設定 ON/OFF・声の種類・読み上げテスト）。既定は元気で若い印象の声。**バックグラウンド／ロック画面の読み上げは保証しない**（通知音＋文字が基本）

ビルド識別: **`build: stage5-speech-3`**

## 未実装／保証外

- バックグラウンド・ロック画面での自由文読み上げ（iOS 制約。審査リスクの高い audio バックグラウンド迂回はしない）
- クラウド TTS／独自音声ファイル大量同梱／クラウド同期／ログイン

## Mac で開く

Mac では `更新してXcodeを開く.command` をダブルクリック（初回は右クリック→開く）。

pbxproj にローカル署名があると `git pull` がコケやすいので、作業前は remote に合わせるのを推奨（上記 .command が同じことをします）:

```bash
cd /path/to/ima-ikura-tanonda
git fetch
git checkout cursor/wasureteita-stage1-aaa9
git reset --hard origin/cursor/wasureteita-stage1-aaa9
git log -1 --oneline
cd WasureteitaDeshou
open WasureteitaDeshou.xcodeproj
```

Signing で Team を選び、実機（iOS 18+）で Run。

### 通知音の再生成

```bash
cd WasureteitaDeshou
python3 scripts/generate_piroriron_sound.py   # ffmpeg が必要
```

## 実機テスト（読み上げ / speech-2）

1. 設定で `build: stage5-speech-3` を確認
2. 「接近時に読み上げる」がオン（既定）であること
3. 「声の種類」が「明るい若い声」（既定）であること。標準／低めに切り替えて「読み上げテスト」で差が分かること
4. 「いま使う声」に端末の声名が出ること（無い声はフォールバック）
5. アプリ前面のまま「テスト通知を送る」→ バナーと読み上げ（設定オン時）
6. ロック／ホームへ退避した状態では、読み上げは期待しない（通知音＋文字のみ）

## 実機テスト（接近通知 dedupe）

1. 予定の通知圏内にいる状態で Run／アプリをフォアグラウンドへ戻す
2. 接近通知が **同じ予定について1回だけ** 届くこと
3. 圏外に出てから再度入ると、また1回通知されること

## 実機テスト（呼び名 / places-1）

1. 地図などで「水江の製油所」などを予定登録 → 設定「保存した場所」に出ること
2. 新規登録で「製油所」や「水江」と入力 → 候補の先頭（または一意なら確認）に出ること
3. 設定で呼び名の編集・削除ができること
4. 「自宅を使う」で登録しても SavedPlace に自宅が二重保存されないこと

## 構成

[`docs/architecture.md`](docs/architecture.md)
