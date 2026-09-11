# spec/04 — LPD8 mk2 統合仕様（KDL）の読み方

> **Status**: ワイヤレイアウトは実機確定（2026-07-31、RigBench ゴールデン 4 プログラム全一致）
> **本体**: [04-lpd8-mk2-unison.kdl](04-lpd8-mk2-unison.kdl)（unison-protocol の schema 語彙で記述）
> **出典**: VP doc 22（逆解析 3 repo の独立一致）+ 2026-07-31 実機測定（Creo `mem_1CdZe314eTYVofGrhZN6xy`）

## この KDL が固定するもの — 3 層

| layer | 固定する Why | 実行可能な正（Living Documentation） |
|---|---|---|
| `wire-protocol` | SysEx バイトレイアウト（LED 0x06 / プログラム 0x03・0x01）・pack7・UMP 受信経路・実測性能（≈107ms/frame → 9-10fps 上限）と completion-gated の帰結 | `ladyland/Sources/Lpd8Kit/`（Lpd8SysEx / Lpd8Program / SysEx7Assembler）+ `ladyland/Tests/LadylandTests/Lpd8KitTests.swift`（実機ゴールデン、round-trip byte-exact） |
| `interaction` | LPD8 = **第 2 の声部**という役割・色の意味論（プログラム色 = 実機の正、0x06 = 揮発オーバーレイ）・LedBus の優先度合成計画 | 役割は design/06 §3。LedBus は実装時に本 spec の `led-surface` を仕様として参照 |
| `harness` | RigBench の測定契約 — なぜ criterion 型でなく 1 ショット・目視併用か | `ladyland/Sources/RigBench/`（`swift run RigBench` で一覧・実行） |

## 同期の仕組み（spec = Why、コード + テスト = 実行可能な正）

- **ワイヤバイトの正はコードと実機ゴールデンテスト**。この KDL は「なぜそのバイト列か」
  「なぜその設計帰結か」を持つ。両者が食い違ったら**実機バイト（テスト側）が勝ち**、KDL を追従させる
- レイアウト変更（新 command 対応・フィールド解釈の訂正など）は、Lpd8Kit と本 KDL を**同一 PR** で更新する
- 実測値（107ms/frame 等）は `swift run RigBench lpd8-led-rate` の再実行で再測定できる。
  数値を書き換えたら `fact` の `measured=` 日付も更新する
- 未確定は KDL 内コメントに明記（例: color-a/b の off/on 対応 — 逆と判ってもフィールド名の入替のみ）

## 初代 LPD8 に関する警告

ヘッダ `F0 47 7F 4C` は **mk2（model 0x4C）専用**。初代 LPD8 は model 0x75 + 別 command 体系で、
mk2 は初代向けフレームを黙って無視する（エラーも返さない）。「送っているのに何も起きない」ときは
まずここを疑う。
