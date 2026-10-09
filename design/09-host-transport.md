# design/09 — ホストのトランスポート（Play とは何か）

**起票**: mem_1CfrGtjgGHpVdfbyes2P2e
**ステータス**: Draft（2026-10-09 起工、wip/host-transport）

## 1. なぜ今まで無かったか

design/06 §2 の確定要件は「完全即興。曲・セクションの概念なし。ファイル再生なし」。
Ladyland は DAW ではなく楽器ホストなので、トランスポートは最初から要らないものとして
外されていた。拍の素材だけは流れている — Keystage が止められない MIDI Clock を
常時送り、`MidiClockTracker` が BPM を割り出し、`HostTempo` が AU に渡す。
ただし渡しているのはテンポだけで、`beatPosition` は常に 0、`transportStateBlock` は
未設定だった。**AU から見ると「ホストは止まっていて、テンポだけ知っている」**。
ホストの transport を見て動く AU（アルペジエーター、Gadget のシーケンサー系）は
走らない。

X-Touch と nanoKONTROL2 が机に載り、どちらにも同じ並びのトランスポート列
（<< / >> / STOP / PLAY / REC）が付いてきたので、「Ladyland にとって Play とは何か」を
決める必要が出た。

## 2. 裁定（mako 2026-10-09、原文）

> Playがなんたるかが、Ladyland的にないのでは？
> 内部的にはAUEngineが回ってるときだよね。
> Aで進めよう
> RECは録音待機にするのが良さそうだね。
> << と >>は、移動かな。小節単位かな？ → それでいこう

## 3. 定義

| ボタン | Ladyland での意味 | AU への申告 |
|---|---|---|
| （再生中） | **エンジンが回っている**（`engine.isRunning`）。起動から終了までほぼ常時 | `transportStateBlock` の `.moving` |
| PLAY | **小節の頭を宣言する**。押した瞬間を beat 0 とし、以後テンポで数える | `beatPosition` / `downbeatPosition`（4/4 固定） |
| STOP | **パニック**（全ノートオフ。Keystage EXIT の CC120 と同じ口）+ 拍を 0 へ | `beatPosition` = 0 |
| REC | **録音待機の ON/OFF**（トグル。実録音はしない） | `.recording` |
| << / >> | **頭を小節単位で置き直す**（<< 1 小節戻る / >> 1 小節進む）。1 小節で回るパターンには何も起きず、2〜4 小節のフレーズで「何小節目か」が変わる。頭より前には行かない（いまに揃える）。スロット移動は TRACK ◀▶ の仕事 | `beatPosition` が ±4 |

Play はエンジンの ON/OFF ではない。`engine.stop()` → `start()` は AU の
`allocateRenderResources` が呼び直されない（2026-08-06 の 4.35 倍速事故）ので、
ボタンで気軽に止めてよいものではない。

棄てた案: B「Play = サンプラーの全パッド」（楽器の中の都合をトランスポートに
昇格させる）、C「Play = 演奏記録の再生」（存在しない機能を丸ごと起こす）、
D「Play は無いと決める」。どれも A の拍の上に後から載せられる。

## 4. 実装

```
nanoKONTROL2  CC 43/44/42/41/45 ─┐
X-Touch (MCU) Note 5B..5F ───────┼→ TransportAction（rewind / fastForward / stop / play / record）
Keystage      （将来）───────────┘        ↓ AppState.transport(_:)
                                   HostTempo（declareDownbeat / resetBeat / recordArmed / running）
                                          ↓ 口は載せる前に 1 回だけ渡す（差し替えない）
                                   AU: musicalContextBlock + transportStateBlock
```

- **`Transport`**（`MIDI/Transport.swift`、純関数）: 機材の生の値を `TransportAction` に
  読み替える。押下だけ拾い、解放は捨てる。番号はここだけに書く
- **`HostTempo`** を拡張: `running` / `recordArmed` / 小節の頭の時刻の 3 語を足す。
  render スレッドから読むのでロックは取らず、整列した 64bit 1 語ずつ（既存の BPM と
  同じ作法）。拍 = `(now − 頭) × BPM / 60`。時計は `DispatchTime.now().uptimeNanoseconds`
  （mach_absolute_time 由来、render から呼んで安全）。テストは時計を差し替える
- **`transportStateBlock`** も `musicalContextBlock` と同じく**繋ぐ前に 1 回だけ渡す**。
  render 中に差し替えると別プロセスの AUv3 が落ちる（HostTempo.swift の経緯）
- **`running`** は `InstrumentRack` が `engine.start()` の後 / `engine.stop()` の前に書く
- nanoKONTROL2 の CC は surface 経路で `AppState.handleSurface` に届く。机の部品
  （`SurfaceMapping`）より先にトランスポートを見る — トランスポート列は部品ではない

### やってはいけない

- Play/Stop でエンジンを止めない（§3）
- 口を差し替えない（HostTempo.swift）
- テンポが nil（同期なし）のとき拍を数えない — `musicalContextBlock` は false を返し、
  プラグインは自前の既定で動く

## 5. 既知の限界

- テンポが変わると拍の数え方が変わる（頭からの経過時間 × 今の BPM）。Keystage の
  Clock は 0.1 秒おきに ±0.5 BPM 揺れうるが、`MidiClockTracker` が平均しているので
  実用上は小節の頭を宣言し直せば足りる。曲の途中で大きくテンポを変える使い方は想定外
- 拍子は 4/4 固定
- << >> は拍単位ではない。PLAY の押し遅れは PLAY を押し直して直す。拍のナッジが要るなら
  SHIFT 併用や長押しで後から足す

## Status log

- 2026-10-09 起工。Draft
- 2026-10-09 実装: `Transport`（読み替え）/ `HostTempo` の拍・transport 口 / `InstrumentRack` の `running` / `AppState.transport(_:)`。純テスト 15 本 GREEN。nanoKONTROL2 の PLAY / STOP / REC は**実機確認待ち**（X-Touch の受信口は wip/xtouch-surface 側）
- 2026-10-10 << >> = 小節単位で頭を置き直す（mako「それでいこう」）。`HostTempo.shiftDownbeat(bars:)`
