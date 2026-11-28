# design/14 — Pattern と Story

- **起票**: `mem_1ChVB8zQ6FiRauYSVHMLmA`
- **設計原典**: `mem_1ChUmyfDVi6vo4rWitdeiD` Step 2
- **ステータス**: Draft
- **操作**: [Story & Pattern](../docs/guide/pattern-story.md)

## 配列と部分上書き

Pattern Pool は MIDI、Parametric、Raw Audio を共通の ID、Track、拍数で扱う。Story Step は ID 参照の配列で、参照先の拍数の累積が各区間の始点になる。Override は Story 全体の拍で指定する。内部では 0 拍始まりで、区間は始点を含み終点を含まない。

Replace は同じ Track と種類を対象とし、Parametric は同じノブ席まで照合する。範囲を出ると元のパターンが再開する。Layer は独立した発音やクリップを追加する。同じノブ席へ複数の値が来たときは、配列の後ろで有効な上書き値を適用する。Override を末尾より後ろに置いた場合は、その終点まで Story が伸びる。

Parametric は指定周期、位相、skew、段数から決定的に評価する。記録点は点の範囲で波形を置き換え、端の最大 0.25 拍で生成波形へ滑らかに戻る。点と点の間は線形補間する。Manual は点列の両端を保持する。

## 再生と録音

`StoryKit` は JSON モデル、区間の解決、CLI、テイク生成を持つ。Ladyland のコントローラは実時間を BPM で拍に換算し、進んだ範囲で MIDI 境界を順に処理する。Stop、シーク、ループのつなぎ目では進行中の Story 音を解放する。ノブ値は対象 Track の顔つまみ割当から AU へ渡す。Raw Audio は読み込んだファイルをラックのメインミキサーで原速再生し、Track の gain、pan、mute、solo に従う。

MIDI 入力の観測は受信時に決まった Route を使う。テイク内のノートは送り先 Track ごと、顔つまみは Track とノブ席ごとに分かれる。Punch In は開始時の小節を基準にローカル拍を記録し、同じ区間に Replace を追加する。

## JSON の共有

`StoryStore` は Ladyland と RigBench の更新を同じファイルロックで直列化し、読み直した文書に変更を適用して atomic write する。外部変更は約 0.5 秒ごとに読み直す。途中まで書かれた JSON や不正な参照を検出した場合、画面には直前の文書を残す。アプリと CLI の両方が同じ検証を使う。

## やってはいけないこと

- Track やノブを Story の表示位置で引き直さない。受信時に決まった Track と永続化された顔つまみ席を使う。
- Story の制御からラックの AVAudioEngine を停止しない。ライブの発音経路と AU に渡すホスト情報は [design/11](11-host-transport.md) に従う。

## Status log

- 2026-11-28 Step 2 のモデル、JSON 共有、トランスポート、Story Pane を追加。
