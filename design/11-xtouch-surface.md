# 11. X-Touch Surface

> **Status**: Draft
> **Related**: `mem_1CfpRU9jTnXL4MeK2kfE42`, `mem_1ChUmyfDVi6vo4rWitdeiD`, design 10
> **対象**: `ladyland/Sources/Ladyland/XTouch*`, `MIDI/MIDIInput.swift`, `Audio/InstrumentRack.swift`, `Audio/RackDatabase.swift`

## 構成

中央の Mixer に X-Touch の 8 Track と独立した 1ch Master を置く。
Track は gain / Pan / Mute / Solo / Select と鍵盤入力元を扱い、Master は全体音量を扱う。
FADER BANK 左右は表示開始を±8、CHANNEL 左右は±1ずらす。端で止まり、Masterは移動しない。
選択と表示範囲は独立。Selectを押したときだけ演奏先の選択が変わる。

## 接続

物理接続は `lnx-server`（旧 Midistage）に限定する。Ladyland は自分の lease に属する X-Touch INT bridge のみ読む。
EXT は外部 MIDI の通過口なので操作面として扱わない。
送信は SDK SendMIDI を直列に送り、失効時は送信処理を停止して完了を待つ。
UI変更も実機変更も同じ rack に反映する。LCD・色・値・LED・motorは差分だけ投影する。
タッチ中はmotor出力しない。Bank/Channel変更もタッチ中は保留し、旧Trackへの操作を混ぜない。

MCU byte変換は純粋層でテストする。`lnx-gear`（旧 Midistage）の Rust profileを参照し、Swift consumer側で変換する（現在のSDKはraw MIDI契約）。
参照: [Ardour MCU](https://github.com/Ardour/ardour/tree/master/libs/surfaces/mackie)。V-Potはbit6が方向、下6bitが移動量。

## 音声と保存

PanはAVAudioMixing.pan、MasterはmainMixer.outputVolumeへ反映する。
SoloはgainやMuteを書き換えず、一時的な出力抑制として計算する。ドラム席もSolo中の抑制対象。
Pan/Solo/MasterはSQLiteへ追加列で保存し、旧JSON/DBはPan=0、Solo=false、Master=1へ復元する。

## 検証の境界

純粋変換・Bank境界・タッチ抑制・lease失効・DB互換は自動テスト。
実機のMC/USB mode、LCDの色、motor追従、Panの聴感は実機確認が必要。
Transport / plugin割当は初版の対象外。

## Jack / VirtualDesk からの入口と割当一覧

Jack の共通ヘッダにある「X-Touch → Mixer Surface」は主ウィンドウの Mixer を選ぶ。
中央 Mixer と保存済みの Mixer／X-Touch 別ウィンドウは、同じラックと `XTouchSurfaceView` を使う。
Mixer Surfaceは既存の8ch + Master操作と「割当一覧」を持ち、実装済みの操作と未割当を分ける。
一覧は `XTouchAssignments` に集約し、実際にdecodeするボタンの網羅をテストする。
未接続でも一覧を参照できる。Recは役割をこのSurfaceで詰めるまで未割当とし、録音できる表示にしない。
3D機材のドラッグや既存のnanoKONTROL2用Mixer部品の結線は変更しない。

## ワークスペースと Inspector

上部のノブと下部の 64 Track レーンの間で Play／Mixer／Studio を切り替える。
Mixer と Studio は切り離せる。中央の Studio は 720pt の机表示を確保し、幅が足りないときは横にスクロールする。
右の Inspector は Track と Gear で、Gear は ROTO／Keystage／LPD8 に切り替えられる。

`window.json` の `workspaceTab` は省略可能で、未保存時は Play を開く。旧 `assignTab` の Mixer／X-Touch／Jack は Inspector 上では Track を表示する。
`drumPaneExpanded` と既存の `SurfaceTab`／`PaneID` は互換のため保持する。メイン画面の固定 Drum 列とタイルは外し、既存のドラム音声経路とラックデータを引き継ぐ。

鍵盤の固定先は既存の `AppState` のルーティングに書く。未固定の鍵盤は選択 Track に追従し、該当チャンネルで `↗` を表示する。
nanoKONTROL2 の S → ノブ → S と同じ候補・確定操作を Mixer 上部から確認・操作できる。

## Status log

- 2026-10-08: 8ch + 1ch MasterのGO。Bank±8/Channel±1を追加。
- 2026-10-08: 内部64Trackに揃える裁定。Masterはドラムを含む全体音量。起動/再接続の演出はLCDと色の短い表示とし、復元完了後に実値を投影する。
- 2026-10-08: 807 tests passed（終了時の明示的なSDK closeを含む）。専用の音声/MIDI/保存なしのネイティブ確認窓で9ストリップ、BANK/CHANNEL、Select/Mute/Soloを観測。実機motor/LCD/音声は別確認。
- 2026-10-08: ユーザーが再接続時LCD演出とFADER BANK / CHANNELの実機動作を確認。
- 2026-10-09: Jack / VirtualDesk の「X-Touch → Mixer Surface」を機能整理の中心とするGO。割当一覧を操作面へ集約する。Recの役割は未決定。
- 2026-11-28: Play／Mixer／Studio の中央タブと Track／Gear Inspector を導入。鍵盤入力元の表示・固定を Mixer に集約。
