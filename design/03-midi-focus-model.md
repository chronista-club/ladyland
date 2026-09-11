# Design 03: MIDI Focus モデル — 繋ぎ先（bikeboy / VP）の即時切替

> **Status**: bikeboy 側 seam 実装済み（M キー切替）。VP 側（Bastet）は設計段階のため未接続。
> **Why の起点**: mako 2026-07-15「繋ぎ先を簡単に、VP(Bastet) なのか bikeboy なのか、すぐ切り替えられるといいね」
> **関連**: vantage-point [doc 23 (Bastet/Justice Stand 配線)](../../vantage-point/docs/design/23-bastet-justice-stand-wiring.md)

## 1. 原則

### CoreMIDI 入力はマルチクライアント — 切替は「接続」ではなく「focus」

同じ物理デバイス（Keystage / LPD8 / ROTO…）の入力ソースは、bikeboy と VP が**同時に listen できる**。
したがって切替に必要なのはポートの繋ぎ直し（遅い・ステートフル）ではなく、
**「どちらのアプリが反応するか」のフラグ反転（瞬時・ステートレス）**だけである。

```
   Keystage / LPD8 / ROTO ...（CoreMIDI: 両者が常時 listen）
        │                          │
   [bikeboy cortex]           [VP Bastet 🧲]
    midi_focus check           routing policy
        │                          │
   演奏・ビジュアル             lane 制御・LED projection
```

### fail-open — 楽器は単体で成立する

focus の既定値は **bikeboy（Local）**。VP が focus を取る形にし、VP daemon が
落ちている・存在しない環境でも bikeboy は常に単体で演奏可能であること。
bikeboy が VP に runtime 依存する構造は作らない。

### 統合はセマンティックレイヤで

raw MIDI bytes を転送する broker は作らない。VP → bikeboy の連携は
「Context 切替」「focus 変更」のような**意味のあるコマンド**で行う。

## 2. 責務の分担（ハイブリッド）

| 経路 | 担当 | 理由 |
|------|------|------|
| ノート/演奏 CC → 音源・ビジュアル | **bikeboy 直取り** | レイテンシ・楽器の自立性 |
| LPD8 → Context/Scene 切替 | 将来 **Bastet** → セマンティックコマンドで bikeboy へ | 環境制御 = VP のドメイン |
| ROTO / X-Touch の LED/LCD projection | **Bastet/Justice** | デバイス出力状態の単一所有（書き込みが競合するため） |

## 3. bikeboy 側の実装（本 doc 時点）

- `App.midi_focus_external: bool`（既定 `false` = bikeboy が処理）
- **M キー**で切替。External へ切替時は CC123（All Notes Off）を送出して
  スタックノートを防止する
- `route_midi_events()` の冒頭で focus を確認し、External ならハードウェア MIDI を
  すべて無視する（PC キーボード演奏モードはウィンドウ入力なので対象外）

## 4. 将来の拡張（Bastet 実装後）

| 項目 | 内容 |
|------|------|
| **リモート切替** | cortex に unison チャンネル（例: `bikeboy.midi.set_focus`）を追加し、VP から focus を操作。MARU プロトコル（デバイス専用）には載せない |
| **物理ボタン切替** | Bastet の routing policy 経由で、コントローラーの特定パッド/ボタンに focus toggle を割当（doc 23 の active-app 概念） |
| **per-device focus** | 現在はグローバル1フラグ。Bastet の device registry が実装されたら「Keystage は bikeboy、LPD8 は VP」のようにデバイス単位へ拡張 |
| **fail-open の自動復帰** | VP からの focus 取得に TTL/heartbeat を付け、VP 消失時に bikeboy へ自動復帰 |
| **LPD8 移管** | bikeboy-launcher の LPD8 ハンドリングを Bastet へ移し、launcher へはセマンティックコマンドを配送 |
