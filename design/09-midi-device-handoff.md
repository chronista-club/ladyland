# 09. 機材別の使用設定とアプリ間引き継ぎ

> **Status**: Deprecated — design 10 と midistage の共通サービスへ移行
> **Related**: spec 09、design 08、`mem_1CfnVkncPrmfdQet3bNSmx`
> **対象**: `MIDI/MIDIDeviceAccess.swift`, `MIDI/MIDIInput.swift`, `MIDI/RotoService.swift`, `JackBoardView.swift`、VP `devices.rs`

Mac 上での機材検出、アプリの使用設定、実際の使用権を別々に扱う。Ladyland の Jack と VP の Devices から、機材単位で ON/OFF を変更できる。別アプリに割り当て済みなら「引き継ぐ」を明示して切り替える。Jack の配置と Track 割り当ては変更しない。

## 共有契約 v1

以下は各アプリが実接続を持つ案の検討記録。2026-10-07 の裁定で、実接続を共通サービスに集約する方式を採用したため実装しない。設定・使用権の正本は midistaged が持つ。

同一ユーザーの `~/Library/Application Support/Chronista/MIDI Access/` に保存する。設定 `devices.json` は `version: 1` と `devices` 辞書。機材 ID は `roto`, `lpd8`, `nanokontrol`, `keystage`, `minilab`, `ncxse`, `fgdp`, `xtouch`。1 台の複数 MIDI ポートは同じ ID にまとめる。現段階は同機種複数台の識別を対象外とする。

各値は `owner` (`ladyland` / `vp` / null)、`revision` (整数)、`expected` (常設機材なら true)。owner は保存された担当であり、プロセスの生存や機材の接続を意味しない。変更は `settings.lock` の flock 下で read-modify-atomic-write し、未知 version や破損を空設定に置き換えない。

実際の制御には機材別 `ID.lock` の排他 flock を保持する。設定を書き換えても旧アプリの lock は奪わない。旧アプリは設定変更を検知し、入力を止め、その機材由来の発音を整理し、再試行・遅延送信を無効化して送信完了を待ち、最後に lock を解放する。新アプリは lock を取れてから接続・実機表示の復元を行う。revision で古い確認画面や遅延処理を拒否する。プロセス終了時は OS が lock を解放する。

## 表示と永続

- 検出あり / 自アプリ担当 / 使用権取得済み: 使用中。
- 検出あり / owner null: 接続済み・使用 OFF。
- 他アプリ担当: アプリ名と「引き継ぐ」。検出と区別して表示する。
- 自アプリ担当 / 使用権取得待ち: 引き継ぎ待ち。
- 自アプリ担当 / 未検出: 接続待ち。常設なら「見当たらない」を強調する。
- 常設の初期値は ROTO、LPD8、nanoKONTROL。FGDP の自動終了は通常待機。

OFF・他アプリへの譲渡でも Jack の部品と束縛は保持。再起動・ホットプラグで owner を上書きしない。移行時は未登録の機材だけ現行アプリの既定から初期化する。VP の既存全体 OFF は保持し、機材別 ON の明示操作でその機材の使用を開始する。全体 ON は他アプリから無断取得しない。

## やってはいけない

- CoreMIDI の列挙だけで「使用中」と言わない。接続 API の失敗を無視しない。
- 入力だけ止めて LED / SysEx / モーターの送信を残さない。
- 相手の PID を kill したり、時刻だけを根拠に使用権を奪ったりしない。
- 引き継ぎで音声エンジン全体や他の入力を panic しない。
- 実機確認と単体テストを同じ証拠として扱わない。

## Status log

- 2026-10-07: 機材別 ON/OFF と明示的な引き継ぎの構想を承認。Swift / Rust 共通契約と遅延送信停止の検証から着手。

## ROTO の setup と引き継ぎ（2026-10-18）

この節は design 10 の共通サービス方式に従う。旧来の各アプリ直接接続案を復活させない。
関連: `mem_1Cg9RCew1FXTqxVCJjgcrs`、midistage `docs/design/06-roto-setups.md` と `schemas/midistage.kdl`。

- Serial/admin port の開閉は midistaged に集約する。Ladyland 本体からの直接 open は廃止する。
- 接続時に `SetDeviceSetups(device_id: "roto", setups: [0, 1, 2, 3])` で自分の冊だけを登録する。
  旧配置の掃除対象だった席 4・5 も、VP の席 8（ROTO 画面の SETUP 09）も登録・書き込み対象にしない。
  内部の setup 番号は 0 始まり、ROTO 画面の SETUP 番号は 1 始まりで、表示は内部番号 + 1 となる。
- MIXER ボタンの長押しは、現在の lease token を付けた `SelectSetup(setup: 2)` で INST 冊へ移動する。
  受付は書き込み完了ではない。完了・失敗は snapshot で確認する。
- `configuring` 中と `config_error` がある間は ROTO の入力・出力を止める。
  使用権があり、設定が成功して `configuring` が外れたら再取得し、既存の `RotoMidiSync` をリセットして値を送り直す。
  ポーリング間に完了した切り替えも `current_setup` の変化で同期をリセットする。
- 切替要求・受信 loop・終了処理は機材ごとの送信終了待ちを共有する。
  長押しの停止処理中に takeover が来ても、drain 完了前に `quiesced` や再取得へ進まない。
- 設定失敗は MIDI 設定画面へ表示する。サービスが利用できないとき、直接 Serial へフォールバックしない。
- **Ladyland 側の失敗（応答待ちのタイムアウト、受付を確認できない等）では ROTO を止めない**
  （VP lead review M1、2026-10-19 ladyland lead 判断「一過性の失敗で演奏を止めない」）。
  エラーは画面に残し、次の変更か全冊ボタンで書き直す。ROTO の入出力を止めるのは、サービスが
  `configuring` / `config_error` を示している間と、Ladyland の席が表に出ていないときだけ

### midistage 経由の冊書き込み

SDK は midistage nightly `fc9360edc2e31aa19eafa08dc35e716892517ef8` に固定する。
配置は **ApplyDeviceSetup 実装を含む常駐 midistaged を更新・再起動 → Ladyland を更新・再起動** の順。
契約だけの `0379302` は Apply に `not_implemented` を返すため、この機能には使えない。
古い daemon で登録 API が無い場合も、設定画面にエラーを出し、直接 Serial へ戻らない。

`RotoMidiSetupExport.books` を純関数 `servicePayload` で `SetupContent` に変換する。
Ladyland の担当 0–3 のみを許し、ノブ・ボタン位置 0–31、チャンネル 1–16、CC 0–127、色・LED 色 0–82 を検査する。
名前は印字可能な ASCII 12 文字へ揃える（非対応文字は `?`、超過分は切る）。
現在の builder は CC7、値 0–127、ノブは `smooth(indents: [])`、ボタンは PUSH / TOGGLE を渡す。
未掲載の席はサービスが CLEAR する。JSON export は従来どおり控えとして残す。

「全冊を焼く」と従来の Darwin 通知は、同じ Apply 経路で 4 冊を順に送る。
名前・色・選択・割当の変更は、送信可能になった最初の変更から 1 秒で束ね、希望値が変わった冊を送る。
継続する変更で期限を延ばさず、その時点の最新値を送る。
初回と lease / 接続の交代後は 4 冊を渡す。書き込み中の変更は進行中の要求を中断せず、完了後に最新の希望値を送る。
同じ接続・lease 内で確認済みの要求だけをメモリ上で重複抑止し、実機の状態として永続化しない。
席単位の差分・バックアップ・読み戻しは midistaged が担当する。
旧 `roto-shadow.json` は読み書き・削除せず、旧影の実装と Codable 保存形式は廃止する。

Select / Apply は排他にし、入力・モーター送信を閉じて送信終了を待ってから要求する。
受付応答の `configuring=true` は完了ではない。その後の新しい snapshot が同じ接続・lease で
`configuring=false`、`config_error` なしになるまで待つ。**Apply は表示中の setup を切り替えない**ため、
Apply の完了に `current_setup == 書いた冊` を要求しない。途中の切断・譲渡・停止は失敗として扱う。
エラーは ROTO / MIDI 設定へ表示する。ポーリングのたびには再送せず、サービスの設定エラー後は全冊ボタンで再試行する。

### トラック選択の書き直しコスト（M2、2026-10-19 実測・裁定）

トラックを 1 回選ぶと 3 冊を書き直す（MIXER 冊の選択印、INST 冊 2 冊のノブ名と色）。
midistaged のログ（2026-10-19 01:35 JST、3 回の選択）:

| 冊 | 理由 | port open |
|---|---|---|
| 席 0（SETUP 01、MIXER） | 選択中トラックの印 | 約 1.1 秒 |
| 席 2（SETUP 03、INST） | 新しい楽器のノブ名と色（26〜33 op） | 2.0〜3.2 秒 |
| 席 3（SETUP 04、INST+） | 同上（1〜6 op） | 0.8〜1.3 秒 |

合計 **1 選択あたり 4〜5.6 秒、ROTO の MIDI が止まる**。port open 中は ROTO 本体が CC を送らない
（旧直接焼きと同じ性質）。加えて Ladyland も Apply 中は ROTO の入力を閉じるので、続けて選ぶと
2 回目以降の押下は届かない。

内訳: INST 冊の書き直し量は楽器が変われば避けられない。**固定費**は midistage が毎回取る控えと
読み戻し（1 冊あたり約 130 往復、0.7〜0.9 秒。0 op の席 1 でも 0.3〜0.4 秒）。

**裁定（mako 2026-10-19）**: 「いったん許す方向で。遅いなと思ったら着手する。今の所このまま」。
選択印は content に残す。

次に手を入れるときの候補（効く順）:
1. midistage で同じ接続中の控え・読み戻しを省く（1 選択で約 2 秒減）
2. 入力を閉じずに書く（Apply は表示中の setup を変えないので、Ladyland 側で押下を捨てる必要は薄い。
   書き込み後のモーター再同期だけ残す）
3. 表示中の冊を先に書く（止まる合計は同じだが、目の前の画面が早く変わる）
4. MIXER 冊の選択印を content から外す（約 1.1 秒減、見た目の機能が減るので最後）

### 実機確認の引き継ぎ

実機の切り替え・書き込みは mako の合図後に行う。lane のテストは模擬 snapshot / loopback に限定し、
`/Applications/Ladyland.app` の差し替えと midistaged の再起動は lead が担当する。
Ladyland は起動後に lease を得ると自動反映を始めるため、実機へ接続する起動も実機 GO の後に行う。

1. Apply 実装を含む daemon → Ladyland の順で配置し、Ladyland の登録が 0–3、VP が 8 であることを確認する。
2. 全冊ボタンで 0–3 の名前・ノブ・ボタン・未割当席の消去を読み戻し、4・5・8 に書き込まないことを確認する。
3. トラック名・色・選択・割当を変更し、操作が落ち着いた後にラベル・色が追従すること、同じ内容では書き直さないことを確認する。
4. 書き込み中の入力・モーター停止、成功後の値再送、Apply 前後で表示中の setup が変わらないことを確認する。
5. 長押し INST、VP との譲渡と復帰、サービスの設定エラー表示と全冊ボタンによる再試行を確認する。
