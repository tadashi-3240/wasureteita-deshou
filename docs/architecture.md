# 忘れていたでしょう — プロジェクト構成案

iOS 18+ / SwiftUI / iPhone専用。既存 Expo・Web とは独立し、ルート直下の **`WasureteitaDeshou/`** に置く。

## 入力方針

- 起動直後はテキスト入力（大きな `TextEditor`）。独自巨大マイク／SFSpeech 自動開始は使わない。
- 音声は iOS キーボードのマイクから。画面内ステップ切替（cover / 不安定な NavigationPath に依存しない）。

## モジュール分割

| モジュール | 責務 | 段階 |
|---|---|---|
| **Features/Registration** | テキスト入力 → 内容確認 → 店舗検索／自宅 | 1〜2+自宅 |
| **Features/Schedule** | 予定一覧・編集（地図確認／ピン移動）・削除・手動完了（履歴へ） | 2〜5 |
| **Features/History** | 履歴表示・ワンタップ再登録 | 4 |
| **Features/Settings** | 通知距離・権限・自宅・保存した場所・**読み上げ**・距離／滞在非保証 | 3〜5 |
| **Services/PlaceSearch** | MapKit 検索＋SavedPlace を候補先頭へ | 2+places |
| **Services/HomePlaceStore** | 自宅の端末内永続化 | 自宅 |
| **Services/SavedPlaceStore** | 登録済み場所の呼び名（UserDefaults） | places |
| **Services/LocationMonitor** | 接近＋滞在の `CLCircularRegion`、限定的位置更新 | 3〜4 |
| **Services/ReminderNotifier** | ローカル通知＋`piroriron.caf` | 3 |
| **Services/ApproachSpeechSynthesizer** | `AVSpeechSynthesizer` 日本語読み上げ（自然な若い女性声・Premium/Enhanced/Siri 優先・前面＋進入直後 BG 試行） | 5 |
| **Services/AppNotifySettings** | デフォルト距離・読み上げ ON/OFF・声の種類 | 3〜5 |
| **Services/ReminderStore** | 予定・履歴の永続化＋監視同期 | 2〜4 |

## 権限

| 権限 | タイミング |
|---|---|
| 位置 When In Use | 店舗検索・地図・**自宅のいまの位置** |
| 位置 Always | 予定登録時の説明シート／設定。BG 接近・滞在に推奨 |
| 通知 | 同上 |
| マイク／Speech 認識 | **不要**（キーボード音声入力に委ねる。読み上げは TTS のみ） |

## 第5段階（音声読み上げ / stage5-speech-10）

1. `ApproachSpeechSynthesizer`（`AVSpeechSynthesizer`）で「忘れていたでしょう？○○予定ですよ！」
2. `speechVoices()` から `ja`／`ja-JP` を列挙。`resolveAllPresetVoices()` で3プリセットに **必ず異なる identifier** を排他割当（同じ bestNatural に収束させない）。若い女性＝Premium → Enhanced → Siri 女性 → O-ren…／標準＝Kyoko compact／低め＝Hattori／男性／Eloquence 男性寄り
3. 端末に ja が3未満のときだけ pitch/rate を極端に変え（1.40 / 1.0 / 0.50）、テスト文の冒頭にプリセット名を読んで差を明示。通常時 pitch は 1.14 / 1.0 / 0.82
4. 設定「接近時に読み上げる」（**既定 ON**）＋「声の種類」＋プリセット変更で即テスト＋「声を再選択」。設定画面に **いま使う声の identifier / name**（debug）を表示。UserDefaults キー `settings.approachSpeechVoiceStyle.v10`（v9／旧キーは移行／掃除）
5. 読み上げテストは毎回新規 `AVSpeechUtterance`・coalesce 状態クリアで **完全 bypass**
6. **フォアグラウンドの確実な経路**: `willPresent` **と** 進入時 `LocationMonitor` の両方から読む（同一文＋同一スタイルは約2秒 coalesce）。通知音（`piroriron.caf` 実長 0.69s）が鳴り止んでから約3.5秒空けて読む（遅延 4.19s）。毎回 `AVAudioSession`（`.playback` / `.spokenAudio` / `.duckOthers`）を再 active
7. **通知タップ後**（`didReceive`）でも前面復帰後に読む（BG で声が出なかった場合の確実な経路）
8. **バックグラウンド（ホーム退避・画面オフ）**: 進入検知で短く起きた枠内に通知投稿→遅延→`AVSpeech`。`UIBackgroundModes` に **`audio`（接近読み上げ用・常時再生ではない）** と `location`。`beginBackgroundTask` で遅延＋発話中だけ延長。**100% 保証はしない**（Focus／節電等で無音になり得る）
9. **ロック画面**: 進入直後に発話開始できれば聞こえることがあるが保証外。無理なら **通知音＋文字**、タップ後は前面で読む
10. 使える声は **iOS／端末依存**。クラウド TTS・独自音声ファイル大量同梱はしない
11. `japaneseVoices()` は声カタログ参照のみのため `nonisolated`（`SpeechVoiceStyle.availableStyles` から Swift 6 厳密 concurrency で呼べる）
12. ビルド識別: `build: stage5-speech-10`

## 予定編集の地図確認（stage5-editmap-1）

1. `ScheduleListView` の編集シートで登録座標を SwiftUI `Map`＋`Annotation` 表示
2. 場所名・住所を地図直下に短く表示
3. 地図タップでピン移動 → `PlaceSearchService.reverseGeocode` で住所更新（場所名はユーザー編集を維持）
4. 保存時に latitude／longitude／address も反映（`ReminderStore.update` → 位置監視再同期）
5. ビルド識別: `build: stage5-editmap-1`

## App Icon（stage5-icon-1）

1. `Assets.xcassets/AppIcon.appiconset` に 1024×1024 Single Size（`AppIcon-1024.png`）を配置
2. ソース原寸は `Resources/wasureteita-app-icon-source.png`（1254×1254）
3. 角丸はシステム任せ（フルブリード正方形）
4. ビルド識別: `build: stage5-icon-1`

## 内容確認の決定＝登録（stage5-decide-2）

1. 内容確認フェーズは場所／用事の編集と大きな **「決定」** のみ（用事必須）。**「予定に登録する」確認は出さない**
2. 決定時、場所欄を `SavedPlaceStore.resolveForDecide` で照合（完全一致 → 正規化一致 → 地名＋店名 → 明確な部分一致 → トークン）
3. **SavedPlace 一意**／**自宅確定**（suggestsHome または場所が自宅ラベルで自宅設定済み）／**検索で一意** → **即保存して完了**
4. **複数候補** → 一覧で選んだら即保存。**地図ピン＋呼び名確定**も即保存（`stage5-mapnick-1`）
5. マッチなしのときだけ **場所の決め方**: 店舗を検索／自宅を使う／**地図で場所を登録**
6. 通知距離は設定のデフォルト。修正は予定一覧から
7. `SimpleUtteranceConfirmView` と `PlaceResolveView` で同じ流れ
8. ビルド識別: `build: stage5-places-3`

## 地図で場所＋呼び名登録（stage5-mapnick-1）

1. 場所不明／検索ゼロ／検索失敗時、「場所の決め方」や候補一覧に大きな **「地図で場所を登録」**
2. `MapPlacePickerView` でピン確定後、**呼び名**入力（必須。プレースホルダ例「金古のセブン / 高崎のイオン」）。空なら登録不可
3. 確定で予定保存（決定＝登録のまま）＋ `SavedPlace` に呼び名・座標・住所を upsert
4. 次回は呼び名一意マッチで即登録（既存 `resolveForDecide`）
5. 自宅設定の地図ピッカーは呼び名必須にしない（`requiresNickname: false`）

## 地名＋店名の呼び名（stage5-places-2）

1. 「金古のセブン」「高崎のイオン」など **地名＋の＋店名** を SavedPlace の `displayName` にそのまま保存（MapKit の正式店名に上書きしない）
2. 予定の `placeName` も場所欄の呼び名を優先
3. `resolveForDecide`: 完全一致 → ブランド正規化一致（セブン↔セブンイレブン）→ 地名＋店名の両語一致 → 明確な部分一致 → トークン
4. パース／検索も同じ呼び名で一意マッチ。地図登録の例文も同形式
5. ビルド識別: `build: stage5-places-2`

## 保存した場所の一覧（stage5-places-3）

1. 設定「保存した場所」は **SavedPlace だけの一覧**（自宅は含めない）
2. 各行に **呼び名・住所**（なければ座標）。**地図プレビューは任意**（トグルで表示／非表示）
3. タップで編集: 地図プレビュー・住所・緯度経度の確認、呼び名の保存、削除確認
4. スワイプ削除も従来どおり
5. ビルド識別: `build: stage5-places-3`

## 接近通知の重複抑止（stage4-dedupe-1）

1. `handleApproachEnter` は通知投稿の **前に** `notifiedWhileInside` を同期的に立てる（失敗時のみ解除）
2. `requestState` は `sync` 末尾の一括のみ（領域 start ごと／active 時の二重呼び出しをやめる）
3. 通知 request identifier は安定 ID `approach-{reminderId}`（投稿前に同 ID を remove）
4. `notifiedWhileInside` を UserDefaults に短く永続化（退出／圏外でクリア）。Run し直しても圏内連打を抑える

## 呼び名で場所を覚える（stage4-places-1）

1. 予定確定時、場所を `SavedPlace` に upsert（約50m近傍なら名前更新）。表示名は場所欄の呼び名（`stage5-places-2`）
2. 自宅（`HomePlace`）は二重保存しない
3. 店舗検索時、SavedPlace を名前部分一致で探し候補の **先頭** に載せる（MapKit が空／失敗でも SavedPlace だけで候補へ。`stage5-nickname-1`）
4. 内容確認の **決定** でも同じ SavedPlace を優先（一意なら即保存。`stage5-decide-2`）
5. 設定「保存した場所」で一覧（呼び名・住所・地図プレビュー任意）・編集・削除（`stage5-places-3`）

## 場所／用事の分割（stage5-parse-1）

1. `UtteranceParser.parse(_:knownPlaceNames:)` が SavedPlace の `displayName` を既知の場所語として文頭・文中マッチ（長い名前優先）
2. 自宅キーワード（自宅・うち・帰ったら等）とコネクタ（で／に寄って／に着いたら／へ行って等）も維持
3. 内容確認画面は手編集可能のまま。初期値が分かれることを優先（例：金古のセブンで牛乳を買う）
4. ビルド識別: `build: stage5-parse-1`

## 自宅（stage4-home-1）

1. 設定「自宅を設定」: 名前（既定「自宅」）・緯度経度・住所（任意）。いまの位置（When In Use）または地図ピン
2. 内容確認で **決定** → 場所の決め方: **店舗を検索** / **自宅を使う** / **地図**（未設定ならその場で位置取得 or 設定へ）
3. パースで「自宅で〜」「家に着いたら〜」「帰ったら〜」→ `suggestsHome`＋用事抽出
4. 通知・滞在解除・履歴は既存 Reminder / LocationMonitor（`placeName` が「自宅」等）

## 第4段階（滞在）の振る舞い

1. 予定ごとに **接近領域**（`notifyDistanceMeters`）と **滞在領域**（約 75m）を監視
2. 接近進入でローカル通知（圏内にいるあいだ1回まで）。退出／圏外で再通知フラグ解除
3. 滞在領域進入で計測。約1分で自動解除 → 履歴。**再通知しない**
4. **正確な距離は保証しない**／**BG で正確な1分は保証できない**

### やらない（未実装）

- ログイン／クラウド同期／クラウド TTS
- ロック画面での読み上げ 100% 保証（進入直後の試行までは実装。失敗時は通知音＋文字）

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
