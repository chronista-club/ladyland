# 10. アプリと MIDI コントローラーをつなぐ共通契約

> **Status**: Draft — 共通サービス方式を採用
> **Related**: design 09、`mem_1CfnVkncPrmfdQet3bNSmx`
> **対象**: アプリ側 SDK、機材 adapter、接続・使用権 coordinator

機材別 ON/OFF と引き継ぎを、アプリ間の共通契約にする。さらに同じ契約上で、機材の能力・入力操作・画面や LED への出力を扱う。Ladyland と VP は対等な参加アプリであり、どちらかの UI やドメイン名をプロトコルの必須概念にしない。

## 責務

| 層 | 責務 |
|---|---|
| アプリ | 操作を Track / lane 等へ結び付ける。表示したい名前・値・色を渡す |
| 共通プロトコル | 機材の発見と能力、使用意思、使用権、引き継ぎ、入力イベント、出力状態の契約 |
| 機材 adapter | ポート識別、CC / SysEx / UMP の解釈、握手、機材ごとの表示更新・ペーシング |
| transport | 同一 Mac のプロセス間通信。Unison は既存の Swift / Rust 通信基盤として候補 |

## 共通の語彙（草案）

- `device_id`: 物理個体の安定した識別子。`profile_id`（ROTO / LPD8 等の機種）と分離し、複数ポートを束ねる。
- `client_id`: アプリの識別子。再起動で変わらない。接続ごとの `session_id` と分離する。
- `capabilities`: `controls` の ID・kind（absolute / relative / button / note / touch）と、表示・色・motor 等の対応能力。持たない能力を偽装しない。
- `presence`: detected / absent。使用設定や使用権とは独立。
- `intent`: どのアプリで使うかの保存設定。機材が不在でも保持する。
- `lease`: 実行中セッションの制御権。世代 token を持ち、旧セッションの出力を拒否する。
- `input`: 操作子 ID、値（絶対値と差分を区別）、timestamp、sequence、lease token。Track や lane の意味は含めない。
- `presentation`: 操作子の名前・値表示・色・motor 値等。初回 / 引き継ぎ後は全状態、その後は差分を渡す。

## 操作とイベント（草案）

| 操作 | 結果 |
|---|---|
| `list` / `watch` | 現在の機材・能力・担当・接続状態を取得 / 購読 |
| `enable` | 未使用なら取得。不在なら接続待ち。他アプリ担当なら競合を返す |
| `disable` | 入力を止め、アプリが発音を整理し、出力を停止して解放 |
| `handoff` | 画面で確認した旧担当・revision を指定して引き継ぐ。確認後の変更は競合 |
| `quiesced` | 旧担当が入力処理・発音を整理したと通知。adapter の送信完了も確認する |
| `present` | 有効な lease token を持つ担当だけが実機表示を更新できる |
| `input` event | 担当アプリへ操作を配送 |
| `state_changed` event | 接続・担当・引き継ぎの状態変更を全 observer へ通知 |

## 引き継ぎ

`active(A) → releasing(A, B) → acquiring(B) → active(B)`

旧担当の新規入力配送を止める。旧担当はその入力が鳴らした音を整理し、adapter は遅延更新を破棄して送信中の更新を完了させる。解放完了後に新しい lease token を発行し、B の表示状態を投影する。エラーは `handoff_failed` として見せ、タイムアウトだけを根拠に実機へ二重送信しない。

アプリ終了・クラッシュ・機材の抜去・仲裁サービスの再起動を個別の遷移として定義する。通常終了と応答なしは区別し、サービス再起動後に旧 token を再利用しない。操作イベントの欠落時は押下状態の再同期 / 入力由来の note cleanup が必要。

## 初期スコープ

機材全体を使用権の単位とし、まず ROTO / LPD8 / nanoKONTROL の操作面を対象にする。鍵盤・FGDP も検出と使用設定の契約に含めるが、演奏イベントの追加 hop は timestamp と遅延の実測を通して導入する。音声ストリームをこのプロトコルで運ばない。

VP の `midistage-profiles` には `DeviceInput::parse` と `DeviceProfile` の純粋変換がすでにある。既存 `midistage` は CoreMIDI / UMP と Keystage 設定ツールを持つ。これらを再利用候補として確認し、Ladyland の ROTO 実機知見・送信ペーシングを失わない。

## 配置の分岐

共通サービスが実機接続と adapter を持ち、アプリはプロトコル client になる方式を採用。正本は midistage repository の schemas / docs に置く。design 09 の各アプリ直接接続 + flock 案は採用しない。

## Status log

- 2026-10-07: 「これprotocolとして纏まってると良くない？」「アプリ<->MIDIコン間連携が楽になる」を受け、使用権に加えて能力・操作・表示を共通契約として整理。配置の選択に依存する実装は保留し、既存変換層を調査。
- 2026-10-07: 「それでいこう」、repo / crate 分割への「OK」で共通サービス方式を承認。midistage を正本、Ladyland / VP を利用側として実装開始。

### 利用側の実装（2026-10-07）

設定の「MIDI 機材」で機材ごとに使用 ON/OFF を保存し、別アプリの担当機材は確認後に切り替える。
MIDIUseSession が midistaged の lease を受け取り、MIDIInput / SysEx / LED は所有中の仮想ポートだけを使う。
サービス未接続時に物理ポートへフォールバックしない。Jack の結線、楽器、編集中の LPD8 プログラムは保持する。
解放時は機材ごとの保持音・sustain を整理し、LPD8 GET/SET の再試行、遅延 MIDI、ROTO serial 作業、Keystage 作業を止めて終了を待つ。
Keystage の途中の接続モードは共通サービスが物理送信完了を追跡して解除する。

関連307テストと、音声/MIDIを起動しない SwiftUI 描画で確認済み。物理機材の入力・音・LED・画面とアプリ間の往復は実機確認待ち。
Field と MIDI SDK が使う Unison は同じ GitHub package / 2.0.0 に統一し、local/remote の package identity 衝突を避ける。
