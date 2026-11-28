# Story & Pattern

中央の **Story** タブで Pattern Pool とタイムラインを開く。タブ右側から別ウィンドウに切り離せる。初回は MIDI、Parametric、最後の小節を置き換える Override が並ぶ。MIDI を聴くには T1 に音源を、つまみの動きを聴くには T1 の最初の顔つまみに AU パラメータを割り当てる。

## 作成と録音

1. **Add Pattern** で MIDI、Parametric、Raw Audio を選ぶ。MIDI は ノート番号を選び **Add Note** で 16 分音符を置ける。Raw Audio は **Choose Audio File** で波形を読み込む。参照元のファイルは同じ場所に置いておく。
2. Parametric は対象 Track と Knob を選び、波形と周期、振れ幅、位相、Skew、Steps を調整する。**Sample** は選択中 Track の顔つまみの現在値を点として記録する。**Shape waveform with ROTO / face knobs** はノブ 1〜7 に Waveform、Cycles、Min、Max、Phase、Skew、Steps を割り当てる。
3. **Append Pattern** で選んだ Pattern を末尾へ置く。ブロックを押すとその位置へ移動する。選んだ Step は矢印で順番を変えられる。
4. **Place Override** で指定小節に置く。Start Bar の 1 は曲頭を指す。**Replace** は同じ対象を区間内だけ置き換え、**Layer** は重ねる。
5. **Rec** を押して鍵盤か顔つまみを操作する。**New Pattern** は **Finish Rec** または **Stop** で Pattern Pool に追加する。**Punch In** は現在位置の小節から指定の長さを録音し、テイクを Replace としても追加する。X-Touch と nanoKONTROL2 のトランスポートも同じ操作を呼ぶ。

## CLI

Ladyland の実行ファイルへの `story` 引数、または Swift パッケージの RigBench から同じ `~/Library/Application Support/ladyland/story.json` を扱える。書き換えると開いている Story Pane に反映される。読み込み状況を確かめたいときは **Reload JSON** を押す。

```sh
cd ladyland
swift run RigBench story list
pattern_id="$(swift run RigBench story add-parametric --track 1 --knob 1 --wave sine --bars 2 --steps 0)"
swift run RigBench story story-append --pattern "$pattern_id"
swift run RigBench story eval --beat 1
```

- `add-midi --track 1 --notes 0:1:60:100,1:1:64:95` の列は開始拍、長さ、ノート番号、ベロシティの順。
- `add-audio --track 1 --file /path/to/take.wav` で波形と秒数を取り込む。長さは `--bars` で指定できる。
- `story-override --start-bar 2 --bars 1 --pattern "$pattern_id" --mode replace` で 2 小節目に置く。
- `story-clear` は並べた Step と Override を空にする。Pattern Pool はそのまま使える。
