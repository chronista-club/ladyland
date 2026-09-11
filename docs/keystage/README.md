# Keystage — ladyland 機材リファレンス

> ⚠️ **メーカー配布の原文（PDF・MIDI 実装チャート等）は私有リポジトリ
> [`chronista-club/ladyland-gear-docs`](https://github.com/chronista-club/ladyland-gear-docs)
> へ退避した（2026-08-10、OSS 公開準備 — 第三者著作物は再配布できない）。
> この README の「L123」形式の行番号引用は、そこの原文をそのまま指す。


> **一次資料**（`ladyland-gear-docs/keystage/`、これが正典）:
> - `Keystage_MIDIimp.txt` — MIDI Implementation v1.00 (2023.8.31)。以下 `L123` は本ファイルの行番号
> - `Keystage_PE_MIDIimp.txt` — Property Exchange (MIDI-CI) 実装
> - `Keystage_PE_ResourceList.txt` — PE リソース一覧
> - `Keystage_om_J2.pdf` — オーナーズマニュアル（日本語）
>
> **役割**: ladyland のメイン楽器（キーボーディストの主戦場）。
> 検証日: 2026-07-26。⚠印は実機未確認。

## 結論ダイジェスト

- **MIDI 1.0 バイトストリーム機**。「MIDI 2.0」は Property Exchange（SysEx 上の MIDI-CI）のみで UMP ではない
- **ポリ AT は `0xA0` Polyphonic Key Pressure、工場デフォルト有効**（L21、AT Mode L880）
- ノブは **8個 × 16ページ = 128 定義**、**CC 番号は位置で固定**（設定フィールド自体が無い。L741-750）
- **OLED 9面（メイン+ノブ8）にホストから文字を書ける**（Display Message、L548）
- ⚠️ **Func 2B/41 は BPM 専用**（TABLE 3 に 1 行しかない。L950-956）。
  Arp / Chord / ノブ割当は **Scene Dump 経由でしか触れない** — 下記「Dump の二重構造」
- パッド・フェーダーは**無い**

## 1. ポート構成（macOS 実測 + 公式）

| ポート | 方向 | 内容 | ladyland の扱い |
|---|---|---|---|
| `Keystage KBD/CTRL` | IN | 鍵盤・ポリAT・PB・Mod・ノブCC・ペダル・アルペジエータ | **これを開く（楽器の本線）** |
| `Keystage CTRL` | OUT | MIDI Clock 送出（アルペジエータ同期）、PE ホスト側 | テンポ同期・SysEx 送出時 |
| `Keystage DAW IN` | IN | DAW 制御（Native Mode: ch16 の CC 群） | 本線では開かない |
| `Keystage DAW OUT` | OUT | LED・表示・ノブ値のフィードバック | Native Mode 統合時のみ |

⚠ Display Message 等の SysEx をどのポートへ送るか（CTRL か DAW OUT か）は実機確認が必要。

## 2. 鍵盤が送るもの（L14-34）

| ステータス | 内容 | 注意 |
|---|---|---|
| `9n kk VV` | Note On, velocity **1-127** | |
| `8n kk XX` | Note Off, **リリースベロシティ 1-64**（鍵盤由来） | 第3バイトを 0 と決め打ちしない。Button/Encoder 由来は固定 64（L18-19） |
| `An kk vv` | **Polyphonic Key Pressure**（鍵盤ごとの圧力） | メインの表現手段（L21） |
| `Dn vv` | Channel Pressure | AT Mode=Channel 時 |
| `En vv vv` | Pitch Bend（ホイール） | |
| `Bn cc vv` | CC（ペダル×2 / Mod / ノブ / ボタン / エンコーダ） | |
| `Cn vv` | Program Change（ペダル・ボタン割当時） | |
| `F8` | Timing Clock — **送受信とも**（L40-45, L178） | |

- Active Sensing は **USB では送出されない**（DIN のみ）→ フィルタ不要
- 鍵盤側はノート等をほぼ**受信しない**（音源を持たないため）

## 3. アフタータッチ設定（Global パラメータ、L873-884）

| # | パラメータ | 値 |
|---|---|---|
| 0 | Global MIDI Ch. | 0-15 = ch1-16（⚠工場出荷値は実機で確認。メイン画面左下に常時表示） |
| 1 | Controller Mode | 0-11 = Assignable/Logic/... (*List7 L959) |
| 3 | Velocity Curve | 0-20 = -10〜+10 |
| **4** | **AT Mode** | **0-3 = Off / Channel / Polyphonic / MPE**（工場デフォルト = Polyphonic） |
| 5 | AT Curve | 0-20 = -10〜+10 |
| 6 | AT Threshold | 0-127 — **高すぎるとポリATが出ない** |
| 7 | AT Max | 0-127 |

**ポリATが来ないときの確認順**: ① AT Mode = Polyphonic か → ② AT Threshold が高すぎないか → ③ 開いているポートが `DAW IN` になっていないか。

⚠ **AT Mode = MPE にすると鍵ごとに別チャンネルへ分散**する（ch2-16 に 1 鍵ずつ）。既存の AU（Gadget 等）は ch1 しか聞かないので **MPE にした瞬間に無音になる**。

**2026-08-05 に自作 AU（`LadySynth` = "Lady MPE"）で対応した** — チャンネルごとに 1 ボイスを持てばそのまま MPE になる。ただし ladyland のルーティング自体は透過なので、**受け手が対応しているかどうかが全て**。⚠ MPE 中は CC74 が鍵ごとに飛ぶので、顔つまみに CC74 を割り当てていると弾くたびに動く。

## 4. ノブ（8個 × 16ページ、L681-756）

- Scene パラメータ 62-445 が Knob1〜128（= 8ノブ × 16ページ）
- 各ノブの設定は **MIDI Ch / Left Value / Right Value のみ**。**CC 番号フィールドは存在しない** → **CC# は位置で固定**: ページ p のノブ k は `CC#(p-1)×8+(k-1)` を送る（ページ1 = CC0-7、ページ2 = CC8-15 … ページ16 = CC120-127）
- 各ノブに個別 OLED があり、Left/Right Value で出力レンジをスケール可能（KONTROL Editor）

現行 cortex の CC0-7 → ビジュアル割当は「ページ1」とそのまま一致する。

## 5. SysEx 機能（ここが Keystage の本領）

フレーム: `F0 42 4g 00 01 69 mm <len×3> <Func> <data...> F7`（g=Global Ch, mm=01:49鍵/09:61鍵。L100-115）

| Func | 機能 | 送出条件 | 行 |
|---|---|---|---|
| `4F` | Scene Change | 要求時 + **シーン変更時に Push** | L118 |
| `40` / `51` | Scene / Global Data Dump | 要求時 | L119-120 |
| `2B` → `41` | **Get Parameter Request → Parameter Change** | 要求時 + **本体で値が変わると Push** | L594-628 |
| `28` | **Display Message — OLED に文字表示** | ホスト→機器 | L548-563 |
| `2A` → `4A` | **Knob Position Request → Reply**（8ノブの現在値） | 要求時 | L565-592 |
| `49` → `5F` | Controller Mode Change Request → 通知 | | L518-546 |
| `01` | Native Mode Enter/Exit | | L124 |
| `23`/`24` | ACK / NAK | | L121-122 |

### Dump の二重構造 — 「書けるが読めない」（2026-08-04 実機確定）

**`current scene data`（作業中）と `internal memory`（保存済み）は別物**で、
Dump の向きによって触る先が違う。

| 向き | 触る先 | 結果 |
|---|---|---|
| `40` を**送る**（ホスト → 機器） | **current scene data** | **即座に効く**（Transpose を書いて実機の音程が変わるのを確認） |
| `10` で**要求**（機器 → ホスト） | **internal memory** | **保存済みの値**が返る。書いた値は見えない |
| `11` Scene Data Write Request | current → internal | 保存先シーン 00-07 を指定 |

つまり:

- **ホストから設定を送り込むのは動く**。ACK も本物（`23`）
- **書いた直後に読み直しても古い値が返る** — 失敗ではない。二重バッファのため
- **本体で操作した内容はホストから読めない**（保存しない限り Dump に出ない。
  60 秒 × 29 回サンプルの差分監視で変化ゼロを確認）
- 送った設定は**本体に焼き付かない**（`11` を送らない限り）。電源を入れ直せば
  手設定に戻るので、曲ごとに送り込んでも壊さない

**ladyland の設計含意**: ホストが SSOT を持つ push 型が正しい。ROTO の PLUGIN 面
（デバイスが割当の SSOT）で苦労した「どちらが正か」問題が、こちらでは生じない。

### ARP / CHORD の持ち方（実測）

```
Global（機器に 1 つ）
└─ User Chord Set ライブラリ 32 個
     ├─ 名前   19-210（6 byte × 32）
     └─ データ 211-3666（108 byte × 32 = 12 キー × [Size + Note×8]）
          初期値は全キー メジャートライアド（空ではない — 使用済み判定には使えない）

Scene（保存先 00-07）
├─ Scene 名 0-9 / ノブ CC 割当 62-445（Knob 1-128）
├─ **Arp の全設定** 31-46   … 曲ごとに丸ごと変えられる
└─ **Chord は参照だけ** 47-49 … どのセットを使うか + Strum Time/Dir
```

**ARP は設定そのものがシーンに、CHORD はセット番号だけがシーンに**（中身は
Global の共有ライブラリ）という非対称。**ARP / CHORD の on/off は Dump に載らない**
（`Arp Mode` に Off が無く、差分監視でも出ない）ので、**起動は手で、中身はホストから**
という分担になる。

### 受信側の落とし穴 — アセンブラの寿命

`SysEx7Assembler` を **CoreMIDI コールバックの中で作ってはいけない**。呼ばれるたびに
状態がリセットされ、**複数コールバックに跨る長い SysEx が永久に組み上がらない**。
Device Inquiry の応答（14 byte）だけ届いて Dump（584 byte）が 1 本も来ない、という
症状になり、機器側を疑って時間を溶かす（2026-08-04 に踏んだ）。

### Display Message 詳細（L548-563）

```
F0 42 4g 00 01 69 mm <len> 28 <addr> <line> <text...> F7
  addr: 0=メイン画面, 1-8=ノブ1-8 の OLED
  line: 0=上段, 1=下段
  text: ASCII 0x20-0x7F、最大124バイト。機器は ACK/NAK を返す
```

**Property Exchange を実装せずとも、ノブに「何のノブか」を表示できる。** ライブでの視認性に直結する最重要機能。

### Device Inquiry（標準機器照会、L50-76）

`F0 7E 7F 06 01 F7` を送ると `F0 7E 0g 06 02 42 69 01 mm 00 <ver×4> F7` が返る。
**ポート名の文字列一致に頼らない機材識別**＋ファームウェアバージョン取得が可能。rigcheck の強化に使える。

## 6. Native Mode（DAW ポート、L995-1105）

Controller Mode = Assignable 時の生プロトコル:

- ノブ: `BF 00-07 vv`（**ch16**、CC0-7）← 機器から
- ホスト→機器のノブ値通知: `BE 00-07 vv`（**ch15**）→ OLED 表示が同期
- トランスポート: ch16 の CC（PLAY `29` / STOP `2A` / REC `2D` / LOOP `2E` 等）
- VALUE ノブ回転: `BF 3E/3F 7F` 連打

## 7. その他の表現手段

- ペダル2系統（DAMPER=ハーフダンパー対応 / EXPRESSION）、Assign Mode: Damper/Expression/CC/ProgUp/ProgDown（*List8 L971）
- アルペジエータ（Ratchet を AT/Mod/ペダル等でリアルタイム制御可）、コードモード
- シーン 16 個（Scene Change SysEx で Push 通知あり → cortex がシーン切替を検知できる）

## 8. コミュニティ実証情報（2026-07-26 調査）

### OLED 表示の実証シーケンス（コードで実証）

Ableton Live 12 同梱の公式 Remote Script（[デコンパイル公開](https://github.com/gluon/AbletonLive12_MIDIRemoteScripts)）と
[Gig Performer コミュニティの実運用スクリプト](https://community.gigperformer.com/t/example-display-message-on-korg-keystage-oled/21427)（21会場ツアーで実績）が一致:

```
1. Device Inquiry (F0 7E 7F 06 01 F7) → 応答 byte[6] から member (01/09) を動的取得
2. 接続: ヘッダ + 02 00 00 6F 01 F7   （Ableton方式。切断時は 6F 00）
   または Native Mode Enter: ... 00 01 F7（GigPerformer方式、Func 0x00）
3. 表示: ヘッダ + <len> 28 <addr> <line> <ASCII> F7
```

- **送信先は DAW OUT ポート**（Ableton スクリプトのポート宣言で実証。KORG 公式の DAW 設定手順とも一致）
- 文字数制限: **メイン OLED 上段 = 6文字（右寄せ）**、下段 = 12文字。ノブ OLED = 12文字（中央寄せ、name/value 2行）
- ⚠ KBD/CTRL 側ポートでも受理されるかは未検証（GigPerformer 例はポート名が曖昧）

### Native Mode の副作用（設計上の要注意）

**Native Mode 中はノブが KONTROL Editor の割当を離れ、CC0-7 / ch16 固定になる**（GigPerformer スクリプトで実証）。
トランスポートは CC41-49 モーメンタリ。→ **OLED 表示を使うことと、16ページの CC 割当は排他**。cortex 側でどちらを取るか設計判断が要る。

### 物理仕様の重要事実

- **ノブはエンドレスエンコーダではなく、始点・終点のあるポット**（実機報告）。ホストから `BE` で値を送っても物理位置は動かない → ページ/音色切替時に物理位置と値がズレる。ピックアップ動作の設計が必要
- **MIDI Clock (F8) が常時送信され、OFF にできない**（KORG 近年製品の既知問題）→ **cortex の入力側で Realtime メッセージをフィルタすること**
- AT センサーは強く押し込みすぎると摩耗の恐れ（マニュアル警告）。半数の鍵の AT が死んで基板交換になった報告例あり

### MPE モードの実態（複数証言）

**per-note pressure のみ**。per-note pitch bend / CC74 (slide) は送信しない。「MPE 対応」表記は送信側3次元がオプションである仕様上は合法だが、full MPE ではない。→ Polyphonic モード運用の方針を補強。

### ファームウェア

最新 v1.0.7 (2025-06)。v1.0.6 で「ch16 受信時のパラメータ表示バグ」修正（Native Mode の内部 ch=16 と符合）。
[公式アップデータ](https://www.korg.com/us/support/download/software/0/927/5079/)は macOS Catalina 以降のみ。

## 9. 実機で確認すること（⚠残り）

1. ~~Display Message をどのポートに送るか~~ → **DAW OUT で実証済み**。KBD/CTRL 側でも受くかのみ未検証
2. 接続メッセージは 0x6F（Ableton式）と 0x00 Native Mode Enter（GigPerformer式）どちらでも表示が効くか
3. 工場出荷時の Global MIDI Ch（推定 ch1）
4. AT Threshold の出荷時デフォルト
5. 通常モードでのノブ CC 実送出（ページ1 = CC0-7 の導出の実証）
6. Knob Position Reply の応答性（起動時同期に使えるか）

---

## 2026-08-05 の実測 — 何が焼けて、何が固定か

ladyland から Scene Dump を書き換えて実機に焼いた記録。**チャートの記載と食い違った点**を残す。

### 焼けるもの / 焼けないもの

| | CC 番号 | Scene Dump |
|---|---|---|
| **ノブ 8 本** | ❌ 位置で固定 | 62-445 に Ch / Left / Right のみ。**CC 番号フィールドが無い** |
| **Mod ホイール** | ✅ **焼けた** | 53-55 は Ch / Lower / Upper だけに見えるが、**実機では変えられた**（チャートの記載が不完全）。CC1 → **CC119**（2026-08-05）→ **CC116**（2026-08-07） |
| **ペダル 1/2** | ✅ **焼けた** | 8-15 に CC Number があり `0-95, 102-119` を許容。KONTROL EDITOR にも Pedal タブがある（Mode=CC + CC#、2026-08-16 確認）。⚠️ 2026-08-07 の「CC115 へ焼いた」は Dump 上の確認で**実機の送出は変わっていなかった**（下記） |
| **エンコーダー** | ✅ 焼ける | 56-61（Play Position REW/FF）。ただし**実機のどの操作に繋がるか不明** |
| **ボタン 9 個** | ✅ 焼ける | 446-499、1 個 6 バイト（Ch / 種別 / 挙動 / CC番号 / Off値 / On値） |

**CC1 は解放できた**（Mod ホイールを **CC116** へ。111-116 の空き帯）。これで物理ノブ 2（CC1 固定）が席の一員になる。
**CC11 の解放は撤回**（2026-08-16）。「EXPRESSION ジャック無反応」（2026-08-07 実測）は**誤りだった** — ペダルを踏むと**ネイティブの CC11 が届く**ことを実機確認（当時は送出の実証ができないまま「解放できた」と記録していた）。**mako 裁定: CC11（と CC64）はそのまま** — 帰結として **P2-4 の席（CC11）はどの楽器でもペダルで踏める**のが仕様。CC# を振り直すなら 111-116 の空き帯へ（102-110 のボタン焼き帯は誤発火するので不可）。
**CC64 だけは固定**（Damper）— ノブ帯は CC64 の壁で止まる（`KeystageKnobs.limit`）。

### ⚠️ ch16 の Native 通知は Native Mode 専用

実装チャートの `(4) Native Mode Knob Output` / `(5) Native Mode Transport Controllers Output`
（`BF 3A` NEXT TRACK、`BF 3E` turn VALUE KNOB など）は、**Assignable では一切来ない**。

Native Mode に入ればこれらが使えるが、**入るとノブが CC0-7/ch16 固定になり 16 ページの
割当が丸ごと壊れる**（§8 の排他）。よって使えない。

### Assignable で実機が出すのは 2 つだけ

| 操作 | 経路 |
|---|---|
| **VALUE を回す** | **Program Change**（ch1、連続値 1,2,3,4,5,6,7,6,5,4…） |
| **焼いたボタン** | **CC**（ch はまちまち — 焼くとき MIDI Ch を触らないと実機の設定が残る） |

⚠️ **PC を楽器へ流してはいけない** — 回すたびにプラグインのプリセットが変わる
（実測: Firenze が勝手に切り替わった）。ladyland が食い止めること。

### ⚠️ Controller Mode は勝手に Live へ寄る

Assignable にしても実機が Live に戻る現象があった。Ableton 方式（`0x6F` 接続）で
繋いでいるのが原因の疑い。**握手のたびに Func `49` で Assignable を上書きする**
（応答は Func `5F`）。値は `00 = Assignable` / `01 = Logic` / `04 = Ableton Live`。

### ⚠️ 焼いただけでは保存されない（Dump の二重構造）

書き込み先は `current scene data`、KONTROL EDITOR が読むのは `internal memory`。
**Write Request（Func `11`、宛先 Scene 00-07）を送って初めて保存される**。

EDITOR 側も「シーン・**データ**を読み込み」（⇧⌘L = current scene）でないと拾えない。
「シーン・**セット**を読み込み」（⌘L）は internal memory を読むので、保存先が違うと古いまま見える。

### テンポは MIDI Clock でしか取れない

`Func 2B/41` が BPM 専用と文書化されているが、**実機で BPM を変えても Push は 1 通も飛ばない**。

一方 **MIDI Clock（F8）は追従する** — 80 → 102 に変えると 32 tick/秒 → 40 tick/秒。
`BPM = 60 / (24 tick ぶんの秒数)`。送っているのは `Keystage KBD/CTRL` 1 本だけで、
`DAW IN` は 0（2 本繋がっているが本線しか出さない）。

⚠️ **測り始めの数拍は捨てること**。起動直後は握手・プラグイン復元の負荷で間隔が伸び、
102 BPM が 67.1 と読めた。しかもヒステリシスのせいでそこから更新されず張り付く。

### ladyland での役割分担（2026-08-05 時点）

```
VALUE を回す        → トラック移動（REW/FF = CC117/118）
Loop（焼いた CC105）→ ROTO のページ +
Rec（焼いた CC104） → ROTO のページ −
EXIT（CC120）       → パニック（All Sound Off の仕様どおり）
CC102-110           → 焼いたボタン（仕様で未定義の空き帯）
```

ボタンは **CC102-110（仕様で明示的に未定義の空き帯）** に焼いてある（2026-08-07 裁定、
`Button.allCases` の順に 102 から連番）。一度「危険牌の領域（96-101 / 121-123）へ
寄せる」案で焼いたが、ノブ帯が CC0-63 に確定して空き帯が使えるようになり移した。
焼く前は CC41-49 / 58-59 という実用領域のど真ん中に居て、そこに割当があると
**押した瞬間にパラメータが最大へ飛んだ**（0 か 127 しか送らないため）。

焼くのは ladyland の設定画面か、`swift run RigBench keystage-scene burn`
（⚠️ ladyland を終了してから — CoreMIDI に排他制御は無い）。
