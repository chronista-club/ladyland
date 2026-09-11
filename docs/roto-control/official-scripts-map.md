# 公式スクリプト完全地図 — ROTO_CONTROL.py (Ableton) + config.lua (Logic)

> 2026-08-11 夜、ROTO-SETUP 3.2.1 同梱の公式実装を総ざらいした調査記録。
> PY = ableton/ROTO_CONTROL.py (v3.2.0) / LUA = logic/config.lua (v3.2.10) の行番号。
> ladyland の DAW ぶり（Transform 方針）の「正解の写経元」。protocol.md と対で読む。

## ⭐ 最重要の発見（ladyland の実装とのズレ）

1. **14bit は両方向とも MSB 先**（PY:1827-1832 / PY:1398）— `index14` は正しかった。
   「下位先でしか効かない」という同日夕方の A/B 結論は**交絡していた疑い**
   （正値 16 の宣言をセッション中盤に注入する対照実験を欠いていた）
2. **実機は「要求したら応答が来る」前提の状態機械** — 応答しないと UI が
   固まって見える。ladyland が未実装の応答義務:
   - `0A 0A REQUEST_TRANSPORT_STATUS` → **`0A 0B` 8 bytes**
     `[play, 0, record, session_record, loop, punch_in, punch_out, re_enable_automation]`（PY:1443）
   - RK 解放（`BF <20+ix> 00`）→ **LED 再表明** `BF <20+ix> <0|127>`（PY:670,719,766）
   - `0A 09 SELECT_TRACK` → Logic は `0C 0A DAW_SELECT_FOCUS_TRACK`（21 bytes、LUA:1526-1536）で選択をエコー
   - `0C 01` → モデル再構築ひと揃い（Ableton: NUM_SENDS + NUM_TRACKS + FIRST_TRACK +
     詳細 + **`0A 08 TRACK_DETAILS_END`（コミット）** + LED 掃き + `0C 0C`）
3. **`0C 01 SET_MIXER_ALL_MODE` は 4 byte payload に意味がある**:
   `[チャンネル種(1=master/return), ノブ機能(0=VOL/1=PAN/2=SEND), ボタン機能(0=MUTE/1=SOLO/2=ARM/3=INPUT_MON), センド番号]`
   — **KNOBS-VOL/PAN/SEND の検出はここでできる**（gain 直結の誤訳ガード）
4. **Logic 方言の正しい init 値**: NUM_SENDS=**12**（0C 03 0C）/ NUM_DEVICES=**8** /
   VU points=**[106,120]**。順序: dawStart → **500ms** → 宣言 6 通（各 5ms）。
   NUM_TRACKS は **8 を 1 回だけ**、以後再宣言しない（終了時に 0 を宣言 = モデル破棄の合図）
5. **面切替は全部実機発**。DAW→実機の「面を選べ」opcode は**存在しない** —
   B6（ch7）の CC 群は **Logic 内部の合成イベント**（LUA:905-909 が SysEx を
   B6 CC に書き換えて Logic のアサインエンジンに食わせている）。
   ⚠️ ladyland が B6 64 を実機に送って面が動いて見えたのは**別の何か**
   （要再検証 — 実機が B6 を解釈している可能性はあるが公式は送っていない）
6. **キャッシュは面切替のたびに全部捨てる**（LUA:942-1019）— 捨てないと
   再入場で 1 通も送らず「表示が古いまま・操作が効かない」に見える
7. スロットルの掟: 値表示 12fps / メーター 12fps / 選択エコーの抑制フラグ
   （PY:1017 `_track_selected_via_roto_control` — エコーループ防止）

## 詳細（調査エージェントの全報告）


## opcode 全表（方向つき）

| grp/cmd | 名前 | 方向 | 備考 |
|---|---|---|---|
| 0A/01 | DAW_STARTED | DAW→機 | この後 **500ms 空ける**（LUA:1435） |
| 0A/02 | PING_DAW | 機→DAW | 応答: 0A/03 + dawType（Logic=3） |
| 0A/04 | NUM_TRACKS | DAW→機 | **[MSB, LSB]**。Logic は 8 を 1 回だけ。終了時 0 = モデル破棄 |
| 0A/05 | FIRST_TRACK | DAW→機 | [MSB, LSB]。Logic は常に 0 |
| 0A/06 | SET_FIRST_TRACK | 機→DAW | Ableton のバンク要求。応答 = モデル全再構築 |
| 0A/07 / 0A/08 | TRACK_DETAILS / **END** | DAW→機 | Ableton 方言。**END がコミット** |
| 0A/09 | SELECT_TRACK | 機→DAW | [MSB, LSB]。応答: 0C/04（Abl）/ 0C/0A（Logic） |
| 0A/0A / 0A/0B | REQUEST_TRANSPORT_STATUS / 応答 | 機→DAW / DAW→機 | 0A/0B = 8 bytes [play,0,rec,sess_rec,loop,punch_in,punch_out,re_auto] |
| 0A/0C | ROTO_DAW_CONNECTED | 機→DAW | **これが門** — これ以前にモデルを送らない |
| 0A/11 / 0A/12 / 0A/13 | SET/RESET_TRACK_DETAILS / SET_TRACK_COLOR | DAW→機 | Logic 方言のみ。0A/11 の枠 index は **スロット 0-7**（絶対番号ではない）。0A/13 = RGB 各 8bit を [1bit,7bit] 分割 |
| 0A/16 / 0A/17 | 選択トラック名 / 色 | DAW→機 | Logic |
| 0A/18 | PARAM_VALUES | DAW→機 | 値の文字列表示。**12fps 上限** |
| 0B/01 | SET_PLUGIN_MODE | 機→DAW | Logic: data[1] 0=PLUGIN / 1=SMART |
| 0B/02 / 0B/03 | NUM_DEVICES / FIRST_DEVICE | DAW→機 | Logic 公式は **8** / 0 |
| 0C/01 | SET_MIXER_ALL_MODE | 機→DAW | **4 bytes: [ch種, ノブ機能(0=VOL/1=PAN/2=SEND), ボタン機能(0=MUTE/1=SOLO/2=ARM/3=MON), send#]** |
| 0C/02 / 0C/05 / 0C/06 | ページ / ch種 / グループ折り | 機→DAW | |
| 0C/03 | NUM_SENDS | DAW→機 | Logic 公式 = **12** |
| 0C/0A | DAW_SELECT_FOCUS_TRACK | DAW→機 | 21 bytes（選択エコー、Logic） |
| 0C/0B / 0C/0C | VU 閾値 / VU 状態 8 bytes | DAW→機 | Logic 閾値 = [106, 120] |

## RK / ノブ / メーター（ch16 = BF）

- RK: CC20-27。押 7F / 離 00。**離に対して LED を再表明するのが公式の作法**
- バンク切替時は 8 キーぶん LED 掃き（MUTE 面: トラック無し枠は **127**）
- ノブ: CC12-19(MSB)+CC44-51(LSB)、モーターエコーも同じ CC（MSB→LSB 順）。
  `maxValue==1` のときは送らない（クリア時のゼロ叩き防止、LUA:1735）
- touch: CC52-59。タッチ時に 0A/18 で値を出し直す
- CC64: 値 = ノブ番号。**デフォルト値へのリセット要求**
- メーター: CC65+（L/R 交互 16 本）、12fps、バンク切替中は必ず止める

## 固まりの説明候補（公式が必ずやっていて、うちが省いたもの）

1. 全 SysEx に 5ms、dawStart 後に 500ms の間合い
2. コミット（Ableton 0A/08）/ 空きスロットの明示クリア（Logic 0A/12）
3. init 一式（NUM_SENDS 12 / NUM_DEVICES 8 / VU 点）を欠かさない
4. **実機の要求への応答**（0A/0A → 0A/0B、0C/01 → 再構築、0B/01 → プラグインモデル）
5. RK 解放への LED 再表明
6. 選択エコーの抑制フラグ（ループ防止）と 12fps スロットル
7. 面切替のたびにキャッシュ全捨て（捨てないと再入場で何も送らない）
