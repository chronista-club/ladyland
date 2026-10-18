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
  旧配置の掃除対象だった席 4・5 も、VP の席 6 も登録・書き込み対象にしない。
- MIXER ボタンの長押しは、現在の lease token を付けた `SelectSetup(setup: 2)` で INST 冊へ移動する。
  受付は書き込み完了ではない。完了・失敗は snapshot で確認する。
- `configuring` 中と `config_error` がある間は ROTO の入力・出力を止める。
  使用権があり、設定が成功して `configuring` が外れたら再取得し、既存の `RotoMidiSync` をリセットして値を送り直す。
  ポーリング間に完了した切り替えも `current_setup` の変化で同期をリセットする。
- 切替要求・受信 loop・終了処理は機材ごとの送信終了待ちを共有する。
  長押しの停止処理中に takeover が来ても、drain 完了前に `quiesced` や再取得へ進まない。
- 設定失敗は MIDI 設定画面へ表示する。サービスが利用できないとき、直接 Serial へフォールバックしない。

### 書き込みの移行境界

SDK の固定版は midistage nightly `03793029fbc726c1b2431ea66862c46cdb398424`（PR #31）。
配置は **常駐 midistaged をまず `0379302` 以降へ更新・再起動し、その後 Ladyland を更新・再起動する**順序にする。
古い daemon は `setup_owners` / 登録 API が無いため ROTO を使用できない。設定画面の更新案内に従い、
daemon 更新後は Ladyland も再接続する（登録エラーは接続単位で保持し、直接 Serial へは戻らない）。
`ApplyDeviceSetup` の型とメソッドは存在するが、この版のサービス本体は `not_implemented` を返す。
このため全焼き・自動差分焼きは停止し、ROTO 設定画面には「書き込み準備中」と JSON export を残す。
この段では楽器変更によるノブ画面の名前・色の自動追従も止まる。Apply 本体の接続後に再開する。
旧 Darwin 通知も書き込み不可を明示し、ローカルの `roto-shadow.json` は読み込まず、更新・削除もしない。
Serial I/O の実装自体を RotoKit から調査用 RigBench へ移し、Ladyland 製品の依存から外す。
未使用になった `RotoDiffShadow` と `SeatKey: Codable` は旧形式の回帰テストとともに残し、
次段の冊全体 payload への移行時に削除する。現在の製品はこの保存形式を読み書きしない。

次段では `RotoMidiSetupExport.books` を `SetupContent` に変換して冊単位で `ApplyDeviceSetup` へ渡す。
席単位の差分・バックアップ・読み戻しはサービスが担当する。受付応答は `configuring=true` であることを確認し、
その後の同一 lease の snapshot が `false` かつ `config_error` なしになるまで成功扱いしない。

実機の切り替え・書き込みは mako の合図後に行う。lane のテストは模擬 snapshot / loopback に限定し、
`/Applications/Ladyland.app` の差し替えと midistaged の再起動は lead が担当する。
