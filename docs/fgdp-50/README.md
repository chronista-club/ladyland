# YAMAHA FGDP-50 — ladyland 機材リファレンス

> ⚠️ **メーカー配布の原文（PDF・MIDI 実装チャート等）は私有リポジトリ
> [`chronista-club/ladyland-gear-docs`](https://github.com/chronista-club/ladyland-gear-docs)
> へ退避した（2026-08-10、OSS 公開準備 — 第三者著作物は再配布できない）。
> この README の「L123」形式の行番号引用は、そこの原文をそのまま指す。


> **一次資料**（このディレクトリ内）:
> - `fgdp50_ja_ug_a0.pdf`（gear-docs） — ユーザーガイド（121p）。以下 `ug p.76` は本書のページ
> - `fgdp50_ja_om_a0.pdf`（gear-docs） — スタートアップガイド（31p、仕様表 p.21-23）
> - ⚠ **MIDI インプリメンテーションチャート / チャンネルメッセージ / SysEx は別配布**（ug p.115）:
>   [download.yamaha.com](https://download.yamaha.com/jp/) で「FGDP」検索。MIDI 詳細が要る時に取得する
>
> **役割**: 飛び道具（メインは Keystage）。**自身の音源を使う**（cortex はドラム音源を持たない）。
> 検証日: 2026-07-26。

## 結論ダイジェスト

- フィンガードラムパッド **26パッド（うち RGB スクエア 8）**、音源内蔵（AWM2、64音ポリ、1500音色）
- **ポリフォニック AT + チャンネル AT 対応**（仕様表に明記）— パッドで鍵盤並みの表現が出る
- 出力はステレオミニ（PHONES/OUTPUT）→ **L6max のライン入力へアナログ接続が本線**
- USB TO HOST（Micro-B）で MIDI + 2ch オーディオも出せる（44.1kHz/16bit 系）
- MIDI 挙動は「**トリガー**」プリセットで一括切替（P01-06 = 送信用 / P07-12 = 受信用）

## 1. 音の経路（リグでの位置づけ）

```
FGDP-50 ─ステレオミニ(アナログ)→ L6max ライン入力 ─→ 会場   ← 本線
        └─USB(Micro-B): MIDI + 2ch audio → Mac              ← 将来のオプション
```

- **本線はアナログ**: 自身の音源 → L6max。cortex 非依存で fail-open（メイン経路を侵さない）
- USB オーディオは 44.1kHz 系。L6max（48kHz 固定）との Mac 上での集約は SRC が絡むため**推奨しない**。使うなら「FGDP 単体を cortex に取り込む」将来案として
- ⚠ **オーディオループバック注意**（ug p.51-52）: `RecSetting→RecSource→Session&Audio = On`（**初期値 On**）のまま USB 接続すると、USB から入れた音が USB へ戻るループバック構成になる。AUX IN と USB の**ループ接続はノイズ源**（公式が対策例を明記）

## 2. トリガー = MIDI プロファイル（ug p.76-78）

パッドの演奏感と MIDI 設定をまとめた単位。プリセット12 + ユーザー50。

| 番号 | 名前 | 用途 |
|---|---|---|
| P01-P05 | Normal/Loud1/Loud2/Hard1/Hard2 **Tx** | **MIDI 送信用**。全パッドの MIDINote が **GM Drum Map** 基準 |
| P06 | Fixed Tx | 送信用、ベロシティ/AT 固定127 |
| P07-P12 | 同 **Rx** | **MIDI 受信用**。MIDINote が連番 |

- cortex に MIDI を送る日が来たら **P01 Normal Tx（GM Drum Map）** が起点
- パッド個別に設定可: `NoteOut` On/Off、`VelCurve`（Loud/Normal/Hard/Fixed/Spline/Offset 系 21種）、`VelMin/Max`、`ADGain`、AT 系（ug p.81-）

## 3. パッドへの機能割当（ug p.109-113）

パッドは発音以外も割当可能（`Function`）:
- `ControlChange` — **叩く→ベロシティが CC 値 / 押し込む→AT が CC 値**として送出（ノートは出なくなる）
- `DrumMute` / `DrumSolo` / `PartOnOff` / `KitChoke` / `AllSoundOff` / `Tempo`（押下中にテンポ上下）
- `LocalControl` Off（ug p.102）で**パッドと内蔵音源を切り離し**、純粋な MIDI コントローラ化も可能

## 4. 仕様の要点（om p.21-23）

| 項目 | 値 |
|---|---|
| パッド | 26（RGB スクエア 8）。**アフタータッチ: Polyphonic, Channel** |
| 音源 | AWM2、64音ポリ、1500音色、キット P48 + U50 |
| ユーザーサンプル | 100個、WAV/AIFF 44.1kHz/16bit、計約600秒(mono) |
| 端子 | PHONES/OUTPUT(ステレオミニ)、AUX IN(ステレオミニ)、USB TO HOST(Micro-B)、USB TO DEVICE(Type-A) |
| レコーダー | USB フラッシュへ WAV 44.1/16 ステレオ、1ファイル約80分 |
| 電源 | USB 5V/1.5A（BC 対応）、内蔵電池 1400mAh **約3時間**、消費 7W |
| スピーカー | 内蔵 4cm / 2.5W（練習用。ライブでは L6max へ） |

## 5. ライブ運用ノート

- **電源**: 内蔵電池は約3時間。本番は USB 給電（5V/1.5A 以上、BC 対応アダプタ）を確保
- **AutoPowerOff 初期値 30分**（ug p.102）→ **本番前に Disabled へ**（放置で落ちる事故防止）
- パネルロック機能あり（EXIT 長押し、ug p.37）— 演奏中の誤操作防止に使える
- 接続は「ステレオミニ → L6max ライン入力」のケーブル1本。予備ケーブル推奨

## 6. 未確認 / 将来調べる事項

1. MIDI インプリメンテーションチャート（別配布）の取得 — cortex に MIDI を繋ぐ判断をした時
2. USB オーディオ I/F としての正確なチャンネル構成・サンプルレート（実測で確認可）
3. パッドのポリ AT が MIDI 1.0 `0xA0` で送出されるか（Keystage と同様のはず。実測で確認）
