# 11. X-Touch Surface

> **Status**: Draft
> **Related**: `mem_1CfpRU9jTnXL4MeK2kfE42`, design 10
> **対象**: `ladyland/Sources/Ladyland/XTouch*`, `MIDI/MIDIInput.swift`, `Audio/InstrumentRack.swift`, `Audio/RackDatabase.swift`

## 構成

右の Surface に X-Touch を追加する。8 Track + 独立した 1ch Master の計9本。
Track は gain / Pan / Mute / Solo / Select、Master は全体音量。
FADER BANK 左右は表示開始を±8、CHANNEL 左右は±1ずらす。端で止まり、Masterは移動しない。
選択と表示範囲は独立。Selectを押したときだけ演奏先の選択が変わる。

## 接続

物理接続は Midistage に限定する。Ladyland は自分の lease に属する X-Touch INT bridge のみ読む。
EXT は外部 MIDI の通過口なので操作面として扱わない。
送信は SDK SendMIDI を直列に送り、失効時は送信処理を停止して完了を待つ。
UI変更も実機変更も同じ rack に反映する。LCD・色・値・LED・motorは差分だけ投影する。
タッチ中はmotor出力しない。Bank/Channel変更もタッチ中は保留し、旧Trackへの操作を混ぜない。

MCU byte変換は純粋層でテストする。既存Midistage Rust profileを参照し、Swift consumer側で変換する（現在のSDKはraw MIDI契約）。
参照: [Ardour MCU](https://github.com/Ardour/ardour/tree/master/libs/surfaces/mackie)。V-Potはbit6が方向、下6bitが移動量。

## 音声と保存

PanはAVAudioMixing.pan、MasterはmainMixer.outputVolumeへ反映する。
SoloはgainやMuteを書き換えず、一時的な出力抑制として計算する。ドラム席もSolo中の抑制対象。
Pan/Solo/MasterはSQLiteへ追加列で保存し、旧JSON/DBはPan=0、Solo=false、Master=1へ復元する。

## 検証の境界

純粋変換・Bank境界・タッチ抑制・lease失効・DB互換は自動テスト。
実機のMC/USB mode、LCDの色、motor追従、Panの聴感は実機確認が必要。
Transport / plugin割当は初版の対象外。

## Status log

- 2026-10-08: 8ch + 1ch MasterのGO。Bank±8/Channel±1を追加。
- 2026-10-08: 内部64Trackに揃える裁定。Masterはドラムを含む全体音量。起動/再接続の演出はLCDと色の短い表示とし、復元完了後に実値を投影する。
- 2026-10-08: 807 tests passed（終了時の明示的なSDK closeを含む）。専用の音声/MIDI/保存なしのネイティブ確認窓で9ストリップ、BANK/CHANNEL、Select/Mute/Soloを観測。実機motor/LCD/音声は別確認。
