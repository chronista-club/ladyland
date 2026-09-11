# ZOOM LiveTrak L6max — ladyland 機材リファレンス

> ⚠️ **メーカー配布の原文（PDF・MIDI 実装チャート等）は私有リポジトリ
> [`chronista-club/ladyland-gear-docs`](https://github.com/chronista-club/ladyland-gear-docs)
> へ退避した（2026-08-10、OSS 公開準備 — 第三者著作物は再配布できない）。
> この README の「L123」形式の行番号引用は、そこの原文をそのまま指す。


> **一次資料**（このディレクトリ内、これが正典）:
> - `J_L6max.pdf`（gear-docs） — オペレーションマニュアル日本語版（149p、Z2I-5716-02）。以下 `p.123` は本書のページ
> - `J_L6max_v1.1_Supplementary.pdf`（gear-docs） — v1.1 追補（USB 送出レベル等）
> - `J_L6max_QuickTour.pdf`（gear-docs）
> - `L6_Editor_Mac_v2.0.0_J/` — 公式エディタ（dmg + ガイド）、`L6max_v1.10_J/` — ファームウェア v1.10
>
> **役割**: ladyland の音の出口（USB オーディオ I/O）+ MIDI で読み書きできる卓。
> macOS デバイス名は **"ZOOM L6max"**（"LiveTrak" ではない。rigcheck 実測）。
> 検証日: 2026-07-26。⚠印は実機未確認。

## 結論ダイジェスト

- USB オーディオ **出力4ch / 入力14ch、48kHz 固定、32-bit float**（p.146-147）
- Mac からの 4ch は**卓の CH7(1-2) / CH8(3-4) に入る**。`USB 1/2` `USB 3/4` キー点灯が必須（p.108）
- MIDI は**素朴な CC/Note/PC**（SysEx 公式なし・MCU/HUI 非対応）。**双方向**（卓操作も送出される）
- **フェーダーは無い**。LED リング付きエンコーダ8個（絶対位置問題なし）
- 隠し SysEx がコミュニティのリバースで判明（Identity / Editor プロトコル）

## 1. USB オーディオ（p.108-110, 146-147）

### 出力（Mac → 卓）4ch

| Mac 出力 ch | 卓の入り先 | 条件 |
|---|---|---|
| 1, 2 | **CH7** L/R | `USB 1/2` キー点灯（点灯中は INPUT 7 ジャック無効） |
| 3, 4 | **CH8** L/R | `USB 3/4` キー点灯（点灯中は INPUT 8 ジャック無効） |

- 通常のチャンネルストリップを通る（EQ → MUTE → LEVEL → PAN → MASTER）→ **卓のエンコーダで cortex の音を触れる**
- `USB 1/2`/`USB 3/4` の状態は**シーン(A-D)に保存される** → シーン切替で経路が変わり得る
- ⚠ 本体レコーダーを**再生すると CH7/8 が PLAY DATA に奪われ Mac の音が止まる**（英語版ブロック図から。日本語版 p.144 ブロックダイアグラム参照）

### 入力（卓 → Mac）14ch

| USB in ch | 内容 | タップ位置 |
|---|---|---|
| 1-4 | CH1-4（モノ） | プリEQ・プリレベル（卓の操作は乗らない） |
| 5-12 | CH5-8 の L/R | 同上 |
| 13-14 | **MASTER L/R** | **ポストフェーダー**（v1.1 追補に明記） |

- v1.1 で USB 送出のトラック毎レベル（Mute / −40〜+40dB）追加（Multi Track 時）
- **USB Mix Minus**（p.109）: On = USB 入力音声を USB 出力しない（ループバック抑止）。**ただしコンプ含む本機エフェクトが OFF になる**
- モード: Stereo Mix / **Multi Track**（14ch が見えるのは Multi Track。本体 Menu > USB Audio Interface）

## 2. MIDI ポート 3つ（p.115）

| macOS でのポート名 | 役割 | ladyland の扱い |
|---|---|---|
| `L6max MIDI I/O Port` | 物理 MIDI IN/OUT 端子（3.5mm TRS Type-A）への素通しパイプ | 外部機器を繋ぐ時のみ |
| `L6max Mixer Control Port` | **卓の制御**。CC で操作・卓操作の送出も | **これを開く** |
| `L6max for L6 Editor Port` | L6 Editor 専用。**「使用しないでください」**（公式明記） | 開かない |

- 公式注意: L6 Editor より先に他アプリがポートを掴むと Editor が接続不能 → cortex は Editor ポートを列挙から除外すること

## 3. MIDI 設定（p.116-119）

| 設定 | 値 | 注意 |
|---|---|---|
| Mixer Control via MIDI | On/Off | **「MIDI IN/OUT 端子に接続した機器」の許可**（p.116 の文言は物理端子限定）。⚠ USB Mixer Control Port に効くかは未記載 → 実機確認。コミュニティ実測では USB は常時有効の模様 |
| MIDI Out Mode | Out / Thru | Out = 本機生成 or PC からの信号を物理 OUT へ / Thru = IN の素通し |
| MIDI Channel | CH1-16 | **送受信共通の単一チャンネル**（L6 Editor で設定） |

MIDI CLOCK 受信中はタップテンポがクオンタイズされテンポ追従（p.114）。クロックの**送信は無い**（チャート p.145）。

## 4. MIDI CC マッピング（p.120-122）

- 割当は **L6 Editor の「MIDI CC# Mapping」で自由に変更可**（"Not Mapped" も可、"Default MIDI Settings" で初期化）
- **CC 割当は卓側に保存される** → cortex は CC をハードコードせず設定化すべき
- 対象パラメータ 16 種（p.122）: EQ HI/MID FREQ/MID/LO LEVEL・SUB MIX/AUX1/AUX2/EFX SEND・PAN・**LEVEL**・**MUTE**（各 CH1-8）、MONO x2（CH5,6）、USB 1/2・USB 3/4、EFX TYPE、COMPRESSOR
- **制御できないもの**: 入力ゲイン（存在しない）、MASTER/MONITOR/SUB-OUT/EFX RTN/SOUND PAD の各ノブ（アナログ）、レコーダーのトランスポート、メーター値

### デフォルト CC 値（公式画面写真 p.121 + コミュニティ実装の一致）

| パラメータ | CC (CH1→CH8) |
|---|---|
| EQ HI | 1-8 |
| EQ MID FREQ | 11-18 |
| EQ MID | 21-28 |
| EQ LOW | 33-40 |
| SUB MIX | 41-48 |
| AUX1 / AUX2 | 49-56 / 57-64 |
| EFX SEND | 65-72 |
| PAN | 73-80 |
| **LEVEL** | **81-88** ← フェーダー相当 |
| MUTE | 93-95, 102-106 |
| MONO x2 | 109 (CH5), 110 (CH6) |
| USB 1/2 / USB 3/4 | **113 / 114** ← 音の出口を遠隔点灯できる |
| EFX TYPE | 117（値域: 0-20 AI NR / 21-42 Hall / 43-63 Room / 64-84 Spring / 85-106 Delay / 107-127 Echo） |
| COMPRESSOR | 119 |

Sound Pads = **Note 60/62/64/65**。出典: [zoom-l6-companion](https://github.com/philmillman/zoom-l6-companion)（実機テスト済み）・[midi.guide](https://midi.guide/d/zoom/livetrak-l6max/)・p.121 画面写真が一致。
旧 L6 は番号が異なる（AUX1=43-48 等）ので流用しないこと。

## 5. MIDI インプリメンテーション・チャート要約（p.145）

- CC: **1-31 ○ / 33-95 ○ / 102-119 ○**（0, 32, 96-101, 120-127 は ×）送受信とも
- Note 0-127 送受信 ○（SOUND PAD 1-4）。ベロシティ・AT・PB は ×
- PC 送受信 ○ — チャートは「0-2 / SCENE A-D」と矛盾記載。**実機テストでは PC 0-3 = A/B/C/D**（コミュニティ、コード実証）
- SysEx 公式 ×。クロック/コマンド/ソングポジションは**受信のみ**

## 6. 隠し SysEx（コミュニティのリバース、非公式）

[L6-MassStorage](https://github.com/Magicking/L6-MassStorage) が USB キャプチャから解明（ZOOM Manufacturer ID = `0x52`）:

- Identity Request `F0 7E 00 06 01 F7` → Reply 末尾 ASCII でファームバージョン取得
- Editor Open `F0 52 00 00 2B F7`、Heartbeat `F0 52 00 00 31 0B F7`（純正 Editor は約100ms間隔）
- ファイル転送モード切替 `F0 52 00 00 31 09 01/00 F7`（USB 再列挙が起きる）
- SysEx は **Editor ポート**に流れる（CC は Mixer Control ポート）— ポートで役割分離

## 7. ライブ運用ノート

- **電源**: 上面 USB = データ、**右側面 USB-C = 電源**（p.143）。電池運用は 14tr 録音でアルカリ約1.5h / NiMH 約2.5h / リチウム約5h（p.147）。**電池が減ると USB デバイスごと消えた実測報告あり → 側面給電を併用**
- **レイテンシ**: USB 往復 16-17ms の実測報告（内部固定遅延が大きい）⚠ 鍵盤→cortex→L6max の出音遅延は要実測
- **録音**: 48kHz/32-bit float WAV、14tr 同時（p.147）。32GB カードで 2ch≈22時間 / 14tr≈3.2時間。録音中の電源断も一定間隔で自動保存され復帰可能（p.142）
- **SD 事前チェック**: 本体 Menu > SD Card > **Quick Test / Full Test**（p.125）。ライブ前点検に組み込む
- **USB 再列挙**（ファイル転送モード切替・電源イベント）で CoreMIDI ポートが stale になる → **保存名での再接続処理が必須**（コミュニティ実装も同対策）

## 8. 実機で確認すること（⚠一覧）

1. Mixer Control via MIDI = Off のとき **USB** Mixer Control Port が生きているか
2. CC 送信時のエコーバック有無（送った CC がそのまま返るか）と LED リングの追従
3. SCENE PC 0-3 の実挙動（コミュニティ実証の追試）
4. Multi Track モードでの実効レイテンシ（鍵盤→cortex→出音）
5. 本体レコーダー再生中の CH7/8 の実挙動（Mac 音が止まるか）
6. デフォルト CC 値の実送出（エンコーダを回して Mixer Control Port を監視）
