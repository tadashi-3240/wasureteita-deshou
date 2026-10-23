# 忘れていたでしょう — プロジェクト構成案

iOS 18+ / SwiftUI / iPhone専用。既存 Expo・Web とは独立し、ルート直下の **`WasureteitaDeshou/`** に置く。

## 入力方針

- 起動直後はテキスト入力（大きな `TextEditor`）。独自巨大マイク／SFSpeech 自動開始は使わない。
- 音声は iOS キーボードのマイクから。画面内ステップ切替（cover / 不安定な NavigationPath に依存しない）。

## モジュール分割

| モジュール | 責務 | 段階 |
|---|---|---|
| **Features/Registration** | テキスト入力 → 内容確認 → 店舗検索／自宅 | 1〜2+自宅 |
| **Features/Schedule** | 予定一覧・編集・削除・手動完了（履歴へ） | 2〜4 |
| **Features/History** | 履歴表示・ワンタップ再登録 | 4 |
| **Features/Settings** | 通知距離・権限・自宅・保存した場所・**読み上げ**・距離／滞在非保証 | 3〜5 |
| **Services/PlaceSearch** | MapKit 検索＋SavedPlace を候補先頭へ | 2+places |
| **Services/HomePlaceStore** | 自宅の端末内永続化 | 自宅 |
| **Services/SavedPlaceStore** | 登録済み場所の呼び名（UserDefaults） | places |
| **Services/LocationMonitor** | 接近＋滞在の `CLCircularRegion`、限定的位置更新 | 3〜4 |
| **Services/ReminderNotifier** | ローカル通知＋`piroriron.caf` | 3 |
| **Services/ApproachSpeechSynthesizer** | `AVSpeechSynthesizer` 日本語読み上げ（若い声優先・前面向け） | 5 |
| **Services/AppNotifySettings** | デフォルト距離・読み上げ ON/OFF・声の種類 | 3〜5 |
| **Services/ReminderStore** | 予定・履歴の永続化＋監視同期 | 2〜4 |

## 権限

| 権限 | タイミング |
|---|---|
| 位置 When In Use | 店舗検索・地図・**自宅のいまの位置** |
| 位置 Always | 予定登録時の説明シート／設定。BG 接近・滞在に推奨 |
| 通知 | 同上 |
| マイク／Speech 認識 | **不要**（キーボード音声入力に委ねる。読み上げは TTS のみ） |

## 第5段階（音声読み上げ / stage5-speech-3）

1. `ApproachSpeechSynthesizer`（`AVSpeechSynthesizer`）で「忘れていたでしょう？○○予定ですよ！」
2. `speechVoices()` から `ja`／`ja-JP` を列挙。既定は **明るい若い声**（Siri 女性 → O-ren → Hattori → Kyoko enhanced → Kyoko → `ja-JP` フォールバック）。端末に無い声はスキップ
3. 若い声は `pitchMultiplier` 約 1.15、`rate` を default より少し上（元気め・やりすぎない）
4. 設定「接近時に読み上げる」（**既定 ON**）＋「声の種類」（明るい若い声／標準／低め、UserDefaults）＋「読み上げテスト」
5. **フォアグラウンドの確実な経路**: `AppDelegate.userNotificationCenter(_:willPresent:)` で通知表示時に読み上げ
6. 非アクティブ時の接近進入では `LocationMonitor` からも試すが **成功は保証しない**
7. **バックグラウンド／ロック画面**: iOS 制約で自由文 TTS は保証できない。`UIBackgroundModes=audio` 迂回はしない。**通知音＋文字が基本**
8. 使える声は **iOS／端末依存**。クラウド TTS・独自音声ファイル大量同梱はしない
9. `japaneseVoices()` は声カタログ参照のみのため `nonisolated`（`SpeechVoiceStyle.availableStyles` から Swift 6 厳密 concurrency で呼べる）
10. ビルド識別: `build: stage5-speech-3`

## 接近通知の重複抑止（stage4-dedupe-1）

1. `handleApproachEnter` は通知投稿の **前に** `notifiedWhileInside` を同期的に立てる（失敗時のみ解除）
2. `requestState` は `sync` 末尾の一括のみ（領域 start ごと／active 時の二重呼び出しをやめる）
3. 通知 request identifier は安定 ID `approach-{reminderId}`（投稿前に同 ID を remove）
4. `notifiedWhileInside` を UserDefaults に短く永続化（退出／圏外でクリア）。Run し直しても圏内連打を抑える

## 呼び名で場所を覚える（stage4-places-1）

1. 予定確定時、場所を `SavedPlace` に upsert（約50m近傍なら名前更新）。表示名は確定時の `placeName`
2. 自宅（`HomePlace`）は二重保存しない
3. 店舗検索時、SavedPlace を名前部分一致で探し候補の **先頭** に載せる（MapKit が空でも SavedPlace だけで候補へ）
4. 設定「保存した場所」で呼び名の編集・削除

## 自宅（stage4-home-1）

1. 設定「自宅を設定」: 名前（既定「自宅」）・緯度経度・住所（任意）。いまの位置（When In Use）または地図ピン
2. 内容確認のあと場所の決め方: **店舗を検索** / **自宅を使う**（未設定ならその場で位置取得 or 設定へ）
3. パースで「自宅で〜」「家に着いたら〜」「帰ったら〜」→ `suggestsHome`＋用事抽出
4. 通知・滞在解除・履歴は既存 Reminder / LocationMonitor（`placeName` が「自宅」等）

## 第4段階（滞在）の振る舞い

1. 予定ごとに **接近領域**（`notifyDistanceMeters`）と **滞在領域**（約 75m）を監視
2. 接近進入でローカル通知（圏内にいるあいだ1回まで）。退出／圏外で再通知フラグ解除
3. 滞在領域進入で計測。約1分で自動解除 → 履歴。**再通知しない**
4. **正確な距離は保証しない**／**BG で正確な1分は保証できない**

### やらない（未実装）

- ログイン／クラウド同期／クラウド TTS
- BG／ロックでの読み上げ保証（実装済みとしない）

## 主要パス

```
WasureteitaDeshou/WasureteitaDeshou/
├── Models/HomePlace.swift
├── Models/SavedPlace.swift
├── Services/HomePlaceStore.swift
├── Services/SavedPlaceStore.swift
├── Services/ApproachSpeechSynthesizer.swift
├── Features/Settings/HomePlaceSettingsView.swift
├── Features/Settings/SavedPlacesSettingsView.swift
├── Features/Settings/SettingsView.swift
├── App/AppDelegate.swift
├── Features/Registration/SimpleUtteranceConfirmView.swift
└── Resources/Sounds/piroriron.caf
```
