# ROTO-CONTROL SysEx protocol — ladyland 実装ノート

> **Status**: PLUGIN モード recall フロー**実機開通**（2026-08-03、firmware 3.2.0 dcf8018）
> **実装**: `ladyland/Sources/RigBench/RotoProtocol.swift` / 実験: `RigBench roto-probe`
> **先行調査**: vantage-point doc 20（2026-06-12）。本ノートはその**誤読 2 点を訂正**し、
> ROTO-SETUP.app 同梱の一次資料で全コマンドを裏取りした決定版。

> **姉妹編**: 設定の読み書き（MIDI setup / PLUGIN 資産 / setup 切替）は SysEx では
> なく **USB CDC シリアルのアドミンポート**を通る — [admin-port.md](admin-port.md)
> （ROTO-SETUP の app.asar 解剖、2026-08-12）。

## 一次資料（この順で強い）

1. **ROTO-SETUP.app 同梱の Ableton スクリプト**（平文 Python、フロー全部が読める）
   `/Applications/ROTO-SETUP.app/Contents/Resources/app.asar.unpacked/ableton/ROTO_CONTROL.py`
   - 同じ場所に `bitwig/Roto-Control.bwextension`（Java）と `logic/config.lua` もある
2. **実機 Export All の JSON**（デバイスが何を保存したかの観測窓）
   `docs/roto-control/backups/` — ROTO-SETUP の File > Export All で採取
3. **Bitwig 拡張の javap**（フレーム書式の最終確認。JDK は brew の openjdk）

4. **公式 PDF**（`ladyland-gear-docs/roto-control/ROTO-UserManual-V1-1-4-April2025.pdf`）—
   SysEx の記載は無いが、**各信号のネイティブな意味**の裏付けに使える
   （2026-08-11 に通読。§「取説から判明したネイティブ意味論」参照）。
   誤タッチ（SENSITIVITY）や 矢印 2 本同時押し = リターン/マスターのような
   **観測を説明する装置側の仕様**はここにしか書いていない

ROTO-SETUP 3.2.1 同梱 firmware は `roto_control_rp2040_v3.2.0_dcf8018.uf2` —
**実機と同一版**なので接続しても書き換わらない（RP2040 = UF2 形式）。

## フレーム

```
F0 00 22 03 02 <type> <id> <payload…> F7
              0A = GENERAL（DAW 制御・track・LCD）
              0B = PLUGIN（device / parameter learn）
              0C = MIXER
```

受信側のスライスも同じ（payload = bytes[7..<末尾F7]）。index は 7bit×2（msb, lsb）。

## コマンド全カタログ（ROTO_CONTROL.py の定数、完全版）

### 0A GENERAL

| id | 名前 | 向き | 意味 |
|----|------|------|------|
| 01 | DAW_STARTED | → | 握手の口火 |
| 02 | PING_DAW | ← | hello/keepalive。**毎回 2 通で応答**（下記） |
| 03 | DAW_PING_RESP | → | 応答。payload = **DAW 種別**（1=Ableton, 2=Bitwig）。ladyland は 2 を名乗る |
| 04 | NUM_TRACKS | → | track 総数（14bit） |
| 05 | FIRST_TRACK | → | 表示窓の先頭（14bit） |
| 06 | SET_FIRST_TRACK | ← | デバイス側で表示窓がスクロールされた |
| 07 | TRACK_DETAILS | → | `<idx14> <name13> <colorIdx> <isGroup>` |
| 08 | TRACK_DETAILS_END | → | track バッチのコミット。**07 単発では表示されない** |
| 09 | SELECT_TRACK | ← | knob touch → 「track i を選べ」 |
| 0A | REQUEST_TRANSPORT_STATUS | ← | TRANSPORT モード切替（トグル） |
| 0B | TRANSPORT_STATUS | → | 8 byte（ビット意味は未検証） |
| 0C | ROTO_DAW_CONNECTED | ← | 接続確立通知。Bitwig 作法では `0A 0D` を返す |
| 14/15 | ROTO_PAGE_LEFT/RIGHT | ← | ページ移動 |
| 18 | PARAM_VALUES | ← | 表示値の要求（詳細未検証） |

### 0B PLUGIN

| id | 名前 | 向き | 意味 |
|----|------|------|------|
| 01 | SET_PLUGIN_MODE | ← | PLUGIN モードに入った |
| 02 | NUM_DEVICES | → | プラグイン台数（**1 byte**。track と違い 14bit でない） |
| 03 | FIRST_DEVICE | → | 表示窓の先頭（1 byte） |
| 04 | SET_FIRST_DEVICE | ← | デバイス側でスクロール |
| 05 | PLUGIN_DETAILS | → | `<idx> <hash8> <enabled> <name13> <rackKind> <pages>` ⚠️ doc 20 は誤読 |
| 06 | PLUGIN_DETAILS_END | → | バッチのコミット |
| 07 | ROTO_CONTROL_SELECT_DEVICE | ← | デバイス上でプラグイン選択 |
| 08 | DAW_SELECT_PLUGIN | → | `<idx> <pageIdx> <force>` **これが recall の引き金**（実測） |
| 09 | SET_DEVICE_LEARN | ← | 実機 LEARN モード on/off |
| 0A | LEARN_PARAM | → | teach / recall 応答（下記） |
| 0B | CONTROL_MAPPED | ← | **「この knob/button に param が割当済み」— learn で応答する義務** |
| 0C | SET_PLUGIN_ENABLE | ← | プラグイン on/off |
| 0D | SET_PLUGIN_LOCK | ← | LOCK ボタン |
| 0E | UNMAP_CTL | ← | 割当クリア（`0E 01 <val>` は macro 値でもある — Bitwig 拡張） |
| 0F | SET_MAPPED_CTL_NAME | → | `<00> <idx+1> <hash6> <name13>` 名前変更 |

### 0C MIXER

| id | 名前 | 向き | 意味 |
|----|------|------|------|
| 01 | SET_MIXER_ALL_MODE | ← | MIXER 更新（= initialized の引き金） |
| 02 | SET_MIXER_SELECTED_MODE | ← | MIX モードへ |
| 03 | NUM_SENDS | → | send 数 |
| 04 | DAW_SELECT_TRACK | → | 選択 track 表示 `<idx14> <name13> <colorIdx> <isGroup>` |
| 05 | SET_MIXER_CHANNEL_MODE | ← | チャンネルモード変更 |
| 06 | TOGGLE_GROUP_TRACK | ← | group 開閉 |
| 0B | SET_MIX_VU_METER_POINTS | → | `0B 2F <val>` = meter threshold（握手の定型応答に使う） |
| 0C | SET_MIX_VU_METER_STATES | → | VU メーター有効化（8×bool） |

## hash（実機 export と突合検証済み）

**`SHA-1(text)` の先頭 N byte を各 `& 0x7F`**（MIDI data byte 化）。

- **plugin hash = 8 byte**。Bitwig はプラグイン名そのまま:
  `SHA-1("Phase Plant")[:8] & 0x7F = 29 0A 3E 1D 09 59 7D 01`（export JSON と一致 ✓）
  Ableton は Live デバイス→class_name 8 byte / 3rd party→`hash(class+name)[:4] + hash(name+class)[:4]`
- **param hash = 6 byte**。入力は DAW が決める安定 ID（Ableton は `param.name`、
  Bitwig は fullId パス）。**つまり hash は DAW ごとの名前空間** — Bitwig で learn した
  割当は Ableton では引けない。ladyland は自前の安定 ID（例: AU パラメータの path）で良い

## PLUGIN モード recall フロー（2026-08-03 実機開通 🎉）

```
DAW:    0B 02 [台数] → 0B 03 [先頭] → 0B 05 details×N → 0B 06
DAW:    0B 08 [idx, page, force]     ← ★これが引き金。バッチだけでは沈黙する（実測）
device: 0B 0B CONTROL_MAPPED  <paramIdx14> <hash6> <0=knob|1=switch> <controlIdx> <isMacro>
DAW:    0B 0A LEARN_PARAM     <paramIdx14 echo> <hash6 echo> <isMacro> <detent> <steps>
                              <pos14> <name13>
効果:   LCD に name 表示 + モーターが pos へ + knob の CC 入力が開通
```

- **learn の index14 は knob 番号ではなくプラグイン内の param 番号**（doc 20 の誤読 2 つ目）。
  どの knob に付くかはデバイス側の保存済み割当（or 実機 LEARN 操作）が決める
- vp demo（2026-06）で LCD が沈黙した理由: 告知なしの push learn は宛先不明。
  ROTO の PLUGIN モードは **pull 型**（デバイスが要求し、DAW が応える）
- 表示名・値は応答側の自由（実験では "LL Gain" / 0.75 を注入して表示された）—
  デバイスは hash で照合するだけ

### 実験再現

```bash
swift run RigBench roto-probe recall            # Phase Plant（Bitwig 名義の既存割当 1 本）
swift run RigBench roto-probe recall Ladyland   # 自作 setup で 8 knob 一斉開通
```

### 割当の bootstrap — knob を active にする 3 経路

knob（LCD・モーター・CC 入力）は**割当が recall されて初めて生きる**。割当を作る経路:

1. **実機 LEARN 操作**（LEARN 押下 → knob touch → DAW が LEARN_PARAM 送出）— 未実装・未検証
2. **ROTO-SETUP で自作 JSON を import** — ✅ **実証済み（2026-08-03）**。
   `docs/roto-control/Ladyland.json`（plugin "Ladyland" = hash8("Ladyland")、
   knob 0-7 ← param#0-7、paramHash = hash6("LL Knob N")）を File > Import で流し込み、
   `recall Ladyland` を走らせると **8 本の CONTROL_MAPPED が一斉に来て全 knob 開通**
   （LCD 8 枚 + モーター階段 0%→100% を実機確認）
3. SysEx のみで割当を新規作成できるか（announce 中の push learn が保存されるか）— 未検証

経路 2 が 8/8 の本命: 初回だけ import すれば、以後は**デバイスが割当の SSOT**。
ladyland は接続のたびに告知 → CONTROL_MAPPED 応答するだけで 8 本が起きる。

## 入力（機材 → DAW、全て ch16 = BF）

| CC | 意味 | 実測の条件（2026-08-11） |
|----|------|------|
| 12–19 / 44–51 | knob 0-7 回転（14bit、hi→lo） | MIX 面のノブ。Logic 方言では素通しになるので受け側の実装が要る |
| 52–59 | knob 0-7 touch（TOUCH_FIRST_CC=52） | ⚠️ **誤タッチ**が毎秒級で来ることがある（取説の SENSITIVITY 節。0A 09 とセット） |
| 20–27 | button 0-7（RK1-8） | ⭐ **MIX 面でのみ発話**（押 127 / 離 0）。**LED はエコーで完全制御**（7F 点灯 / 00 消灯、押下なしでも効く） |
| 28–35 | transport button 0-7 | 未検証 |
| 36 / 37 | ← / →（config.lua の表） | ⚠️ **この実機では 60 / 61（値 2）**。**MIX 面のみ** + **NUM_TRACKS > 8 の宣言が必須**（8 宣言だと 1 通も送らない） |
| 64 | DEFAULT_VOLUME_CC（MIX モード） | 未検証 |
| 65– | METERS_FIRST_CC（VU 送出） | 未検証 |

モーター駆動は同じ CC 番号への**送信**（`BF <12+i> <hi>` + `BF <44+i> <lo>`）。
knob は learn で active になるまで CC を送らない（ccInsBlocked ガード）。
**モーターも同じ門の内側**（実測 2026-08-03: 割当ありの knob 0 だけ動き、
不活性の 7 本は無反応）— 「learn なしでもモーターは動きうる」は否定された。

## Logic 方言 — SMART モード（2026-08-03 夜に発掘・実機開通 🎉）

出典: 同じ app.asar.unpacked の `logic/config.lua`（**3.2.10** — Python 版 3.2.0 より新しい）。
**ping 応答で DAW 種別 3（Logic Pro）を名乗ると、デバイスの MODE に「SMART」が出現**し、
別方言が解禁される。Bitwig/Ableton 方言（hash + learn + CONTROL_MAPPED の pull 型）とは
思想が違い、**ROTO を「素直な表示 + ノブ面」として直接駆動する push 型**。

### 直接 setter 群（hash も learn も不要、実機確認済み）

| コマンド | payload | 意味 |
|----------|---------|------|
| `0A 11 SET_TRACK_DETAILS` | `<0> <idx> <name13> <color> <0>` | track セル 1 個を直接更新（バッチ枠不要） |
| `0A 12 RESET_TRACK_DETAILS` | `<0> <idx>` | track セルのクリア |
| `0A 13 SET_TRACK_COLOR` | — | （未実験） |
| `0A 16 SET_CURRENT_TRACK_NAME` | `<0> <0> <name13>` | ⚠️ **SMART 面で送ると面を殴って knob LCD が消える**（実測 08-04、下記） |
| `0A 17 SET_CURRENT_TRACK_COLOR` | `<0> <0> <color>` / RGB 6 byte | ⚠️ **無害だが無反応**（実測 08-05、下記） |
| `0B 13 SET_PLUGIN_CTL_DETAILS` | `<0> <idx> <name13> <color>` | **knob LCD へラベル直書き**（SMART 面に表示） |

init は `logicInit()`（NUM_SENDS → NUM_TRACKS → FIRST_TRACK → NUM_DEVICES →
FIRST_DEVICE → VU points）。⚠️ **デバイスは表示を保持しない** — モード切替通知
（`0C 02` / `0B 01`）を受けるたびに DAW が再投影する義務がある（Logic の CSLabel 相当）。

### 多チャンネル CC 配置（config.lua の動的生成規則、実測一致）

| ch | 用途 |
|----|------|
| 16 (0xBF) | 主: MIX knob 12-19/44-51、MIX touch 52-59、button 20-27、transport 28-35、meter 65+ |
| 15〜8 (0xBE→0xB7) | **plugin/SMART param**: param N → ch `0xBE−N/32`、CC `N%32` (MSB) / `+0x20` (LSB)、touch `0x40+N%32` |
| 7 (0xB6) | command（モードセレクト等の semantic） |

物理 8 knob（SMART 面）= param 0-7 = **ch15 の CC0-7 / 32-39、touch 64-71**。

### モーター + haptic

**同じ ch15 CC への 14bit echo でモーターが動く**（`smartMotor()`、実機確認済み）。
値が届くとデバイスが**物理的な端 stop（haptic）を張る** — フリースピンではなく
ポテンショメータの手応えになる。learn は一切不要。

### 2 方言の使い分け（ladyland 設計判断の材料）

| | Bitwig/Ableton 方言（pull） | Logic 方言（push、SMART） |
|---|---|---|
| 割当の SSOT | **デバイス**（hash で永続、再接続で自動復元） | **DAW**（毎回投影。デバイスは保持しない） |
| bootstrap | learn 操作 or setup JSON import が必要 | **不要 — 接続後すぐ全 knob 使える** |
| 表示の自由度 | 割当済み knob のみ | **任意のタイミングで任意のラベル** |
| 向き | 固定的なプラグイン操作面 | **動的な面（シーン切替・一時表示）** |

**mako 裁定（2026-08-03）: ladyland は push 型（Logic 方言）を採用**。
ladyland は自分が SSOT（GRDB）なので毎回投影で困らず、bootstrap 不要・ラベル自由・
実装が単純。pull 型（Bitwig 方言）はデバイス内永続が効く場面（ladyland を立ち上げず
ROTO 単体で使う等）のための第二経路として温存 — 実装は RigBench に残すのみ。

## 3 つの面と、それぞれの上限（実測 2026-08-03）

ROTO は 3 つの面を持ち、**ラベルの経路も上限も別**。ladyland はこの 3 つを
使い分ける。

| 面 | ラベルの経路 | セル数の上限 | 型 |
|----|------------|------------|-----|
| **MIX** | `0A 11` 直接書き込み | **16 トラック** | push |
| **SMART** | `0B 13` 直接書き込み | **16**（8 ノブ × 2 ページ） | push |
| **PLUGIN** | 告知 → CONTROL_MAPPED → `0B 0A` learn | **64**（8 ノブ × 8 ページ） | pull |

- SMART の 16 は Logic の Smart Controls を模した設計（config.lua の
  `SMART_MODE_PARAMS = 16` は Logic 側スクリプト内部の定数で、デバイスへは
  送られない。上書きできる「設定」ではなかった）
- PLUGIN の 64 は**ノブの上限**。マニュアルの "up to 128 controls per
  device/plugin" は「ノブ 64 + ボタン 64」と読める（128 セルの setup を
  import しても 8 ページ目以降は暗いまま — 実測）
- ladyland のマトリクスは 128 セル（16 ページ）なので、**ROTO から届くのは
  前半 8 ページ（CC0-63）**。残りは ladyland 側の操作で扱う

### PLUGIN 面は「骨組みはデバイス、中身は DAW」

**押し込みの learn は効かない**（実測: 告知 → 選択 → learn ×24 を押し込んでも、
デバイスは保存済みの 8 セルしか聞いてこなかった）。PLUGIN 面に存在するのは
**デバイスに保存された割当だけ**。

ただし**保存された割当は骨組みにすぎず、名前も値も learn 応答で DAW が自由に
決められる**。よって:

> **「Ladyland」という架空のプラグインを 64 セルぶん一度だけ import しておけば、
> 以後 ladyland がトラックごとに中身を書き替えて使い回せる**

bootstrap は**生涯 1 回**（`docs/roto-control/Ladyland.json` を ROTO-SETUP の
File > Import）。push 型の自由さと pull 型の到達範囲を両取りできる。

### デバイスは表示中のページしか聞いてこない

`CONTROL_MAPPED` は **今表示している 8 セルぶんだけ**来る（64 セル保存していても
一度に来るのは 8 件）。ページを繰るたびに聞き直すので、DAW は
**`CONTROL_MAPPED` が来るたびに答える**だけでよい（全セルを一度に投影する
必要はない — push 型の SMART 面とは対照的で、通信量はずっと小さい）。

## ⚠️ 方言は「名乗り 1 バイト」で全レイヤーが入れ替わる（2026-08-03 夕、実測で確定）

**`0A 03` の payload（DAW 種別）を変えると、その下の全コマンド体系が連動して変わる。**
片方だけ変えると必ず壊れる。

| | 種別 3（Logic） | 種別 2（Bitwig） |
|---|---|---|
| PLUGIN 面 | **死んでいる** — 告知も選択宣言も届くが `CONTROL_MAPPED` が **1 件も来ない** | **生きている** — 8 件が一斉に来て learn で名前・値を注入できる |
| SMART 面 | ある（16 セル、`0B 13` 直書き） | **無い** |
| トラック名 | `0A 11` 直接（セル単位・色指定可） | `0A 07` 枠付きバッチ（`04→05→07×N→08`、色は一括。選択は `0C 04`） |
| knob ラベル | `0B 13` 直接 | learn（`0B 0A`）→ 以後 `0B 0F` |
| モーター | ch15 に**絶対セル番号**（全ページを一度に置ける） | ch16 CC12-19 の**物理 8 本**（表示中のページのみ） |
| knob 入力 | ch15 CC 0-7 / 32-39 | ch16 CC12-19 / 44-51 |

**b190dbd が「PLUGIN 面開通」と記録できた理由**: RigBench の実験は種別 2、本番の
RotoService は種別 3 で走っており、**その食い違いに気づかないまま両者の結果を混ぜた**。
実験と本番で環境がずれていた、の MIDI 版。

### Bitwig 方言では Logic のコマンドを 1 通も混ぜてはいけない

まったく同じ learn を送っても、**RigBench（投影なし）は LCD が変わり、ladyland
（投影 32 通）は変わらなかった**。差は「何を送るか」ではなく**「何を送らないか」**。
`0A 11` / `0B 13` は種別 2 では未定義コマンドで、PLUGIN 面の応答まで巻き添えにする。

### 送信は 1 本のキューで — 追い越し車線を作ると壊れる

応答（learn / hello）を「遅らせないため」に即時送信の第 2 経路を作ると、**告知バッチ
（`0B 02`〜`08`）がキューに並んでいる間に learn が追い越し**、デバイスは告知処理中の
learn を捨てる。LCD は保存名のまま残る。

- キュー統一で投影が重い → learn が**遅すぎる**（届いた時には手遅れ）
- 即時送信を足す → learn が告知を**追い越す**（順序が壊れる）

**正解は経路を増やすことではなく、キューに積むものを減らすこと**（方言ガード + 面ごとの上限）。

### 3 つの面の上限を超えると固まる

`0A 11` を 16 席より先へ書くと**デバイスが停止する**（実測: ラック 24 スロットを
そのまま `NUM_TRACKS` に宣言して 0-23 へ書き込み、MIX 面を選んだ瞬間に停止 →
電源の差し直しが必要）。**宣言と書き込みの両方**を上限で切ること — 宣言だけ大きいと、
ユーザーが 17 席目へ繰った時点で行き先が無くなる。

### 診断の死角: 骨組みと中身を同じ命名規則で埋めない

`Ladyland.json` の `controlName` が `P1-1`…`P8-8` で、ladyland 側の**未割当時の
フォールバック名と完全に一致**していた。そのため LCD を見ても「learn が無視されている」
のか「割当が見つからずフォールバックを送っている」のか**区別できなかった**。
bootstrap 用 JSON の名前は、DAW 側が出しうる名前と**必ず変える**こと。

### ページの主導権も方言で反転する（2026-08-04 実機確定）

| | Logic 方言 | Bitwig 方言 |
|---|---|---|
| 誰が繰るか | デバイス | **デバイス**（表示も自分で変える） |
| 通知 | 来ない | **`0A 14` / `0A 15` が来る** |
| CC の番号 | **絶対パラメータ番号**（ch が下がる） | **物理 8 本に固定**（ch16 CC12-19） |
| `CONTROL_MAPPED` の controlIndex | — | **ページ内の位置（0-7）** |
| ホストの仕事 | 何もしない | **ページ番号を覚える**（← → を数える） |

Bitwig 方言では CC もセル番号もページ情報を持たないので、**ホストが `0A 14`/`0A 15` を
数えて現在ページを保持する**しかない。踏んだ罠 2 つ:

- **`CONTROL_MAPPED` からページを逆算してはいけない** — controlIndex はページ内位置
  なので常に 0-7。逆算すると ← → で進めた直後に 0 へ巻き戻り、**ページ 2 から先へ
  行けない**
- **ページを繰った後に選択宣言（`0B 08`）を送ってはいけない** — デバイスの表示が
  **1 ページ目へ戻る**。`pages` に現在ページを添えても戻った。ホストは番号を覚えるだけでよい

### PLUGIN 面の名前は面に入り直すまで変えられない

3 通り試して全滅（2026-08-04）:

| 手 | 結果 |
|---|---|
| `0B 0F` SET_MAPPED_CTL_NAME | 効かない（カタログは DAW→機器だが、実際は機器→DAW） |
| learn（`0B 0A`）の再送 | 効かない（**聞かれたときの答え**しか受け取らない） |
| `0B 08` で聞き直させる | 名前は変わるが**ページが 1 に戻る**副作用の方が痛い |

よって **LCD には保存名（`P1-1` 形式）が出る**前提で設計する。これは弱点ではなく、
**座標系として使うと強い**:

```
ROTO の LCD         P1-1
ladyland の割当一覧   P1-1   ← 同じセルを指す
Keystage のノブ       P1-1   ← CC 0（マトリクス座標）
```

3 つが同じ番号で同じパラメータを指すので、**実機を見ただけで位置が確定する**。
割当を変えたら MODE で面を出入りすれば新しい内容で learn される。

### ⚠️ 実験環境に他のホストが居ないか確かめる

CoreMIDI に排他制御は無く、**同じ機材を複数のホストが同時に駆動できる**。
2026-08-04 の検証では VantagePoint が裏で ROTO に接続しており、
**ノブが 2 本連動する / ページが勝手に戻る**という症状を出していた。

資料と実機が食い違ったとき、疑う順序は「自分のコード → 資料」の前に
**「同席者の有無」**。`ps aux | grep -i <他ホスト>` で 10 秒で潰せる。

### 応答義務のあるメッセージ — 黙ると面が死ぬ

pull 型のバグは「送りすぎ」ではなく**「聞かれたのに答えない」**の形で出る。
デバイスは DAW の確定を待って止まるので、**無応答 = 進行不能**になる。

| 受信 | 返すもの | 落とすとどうなるか |
|------|---------|-----------------|
| `0A 02` PING_DAW | `0A 03` + `0C 0B` | 切断扱い |
| `0A 0C` ROTO_DAW_CONNECTED | `0A 0D` | 接続が確立しない |
| `0B 0B` CONTROL_MAPPED | `0B 0A` learn | その knob が起きない |
| `0B 07` SELECT_DEVICE | `0B 08` DAW_SELECT_PLUGIN | **プラグイン一覧から先へ進めない** |
| `0B 04` SET_FIRST_DEVICE | 同上 | スクロール先が確定しない |

**踏んだ罠（2026-08-03、`b190dbd` の回帰）: MODE で PLUGIN 面に戻ると進行不能。**
`0B 08` は握手直後の `projectAll()` にしか無く、`0B 01`（PLUGIN 面へ）では
ラベル投影しか走らなかった。**PLUGIN 面は入り直すたびに告知 + 選択宣言が要る** —
面を「塗る」のは push 型の作法で、pull 型の面は塗っても起きない。

同時に踏んでいた 2 つ:

- `logicInit(devices: 8)` が「8 台ある」と宣言した直後に `pluginBatch` が「1 台」と
  言い直していた → 一覧に名前のないゴーストが 7 台。**告知する台数と揃える**
- モード切替のたびに `0B 13` を 128 通（5ms ペーシングで **640ms**）流していた。
  learn も hello も同じ送信キューの後ろで待たされる。**面の上限（上表）で
  打ち切る** — 応答義務のあるメッセージを一括投影の人質にしない

## VU メーター — 一旦棚上げ（mako 裁定 2026-08-03「一旦使わないでおこう」）

**専用の表示器は無い**（8 枚の knob LCD に描かれるはず、という仮説）。プロトコル上の
根拠は両実装に揃っている:

- `ROTO_CONTROL.py`: `METERS_FIRST_CC = 65` / `METER_LEVEL_YELLOW = 87` / `RED = 113` /
  `AUDIO_METER_FPS = 12`
- `config.lua`: `CONTROL_ID_METER_0`〜`15` =「Meter 1 Left / Right … Meter 8」、CC `0x41`(=65) から
- SysEx: `0C 0B` 閾値 / `0C 0C` 有効化（8×bool）

### 試したこと（3 回、いずれも視認できる反応なし）

`swift run RigBench roto-probe meter` — Logic init → トラック名 ×8 → 閾値 `0C 0B` →
有効化 `0C 0C` → **ch16 CC65-80 に 12fps でレベル**（位相をずらした波）。
DAW 種別は Logic(3) を名乗る。接続は維持されていた（hello 応答が続いた）ので
**送信経路の問題ではない**。

⚠️ 最初の実装は **15 秒ブロックして流していたため hello に応答できず切断扱い**に
なっていた（自分たちで見つけた罠を自分で踏んだ）。受信ループを止めずに流す形に
修正済み — 追試するならこの版から。

### 残る仮説（どれも当てずっぽうになるので保留）

1. レベルの送り先チャンネルが違う（ch16 ではなく ch7 command / ch15 側）
2. `0C 0C` の payload が bool 8 個ではない
3. **メーターは Ableton/Bitwig 方言専用**で Logic 方言（SMART）には無い

8/8 に必須ではないので保留。実装（`Roto.meterStates` / `meterPoints` / `meter`）は
RotoKit に残してあるが**未検証**。

## 実測で裏付いた多チャンネル配置（2026-08-03、SMART 面の実トラフィック）

推測ではなく実データ。SMART 面で 60 秒操作したログの集計:

| ch | 受信した CC | 意味 |
|----|------------|------|
| **ch15** | 0-7 / 32-39 / 64-71 | SMART・PLUGIN 面の param（MSB / LSB / touch） |
| **ch16** | 12-19 / 44-51 / 52-59 | MIX 面の knob（MSB / LSB / touch） |

**2 つの面は別チャンネルで完全に分離している**。config.lua の動的生成規則
（param N → ch `0xBE−N/32`、CC `N%32`）が実トラフィックと一致した。

同ログで確認できた SysEx: `0C 01` MIXER 更新（モード切替で来る）、`0A 09` selectTrack
（knob touch のたび）、そして**未解読の `0B 0F`**（カタログ上は DAW→機器の
`SET_MAPPED_CTL_NAME` だが、**機器から来ている**。SMART 面で名前に関わる何かが
起きたときらしい）。

## 未検証（次の宿題）

1. 実機 LEARN 操作起点のフロー（0B 09 → touch → DAW が learn 送出）— ladyland で
   「実機からつまみを割り当てる」体験に必要
2. steps 付き learn（quantised。steps≤16 で stepNames を**ゼロ埋めで**送る — 実文字列は
   後で別要求される、が Python の記述）
3. TRANSPORT_STATUS（0A 0B）の 8 byte の意味 / PARAM_VALUES（0A 18）の応答書式
4. 色パレット 83 色（vantage-point `roto_palette.rs` に転記済み。ladyland へ持ち込みは未）
5. MIX モードの volume CC / VU メーター経路

## ladyland 統合への設計含意

- Track = 0A 系（MIX 面）、プラグイン/パラメータ = 0B 系（PLUGIN 面）の **2 面 projection**
- ladyland は「DAW」として振る舞う: 握手常駐 + hello 応答ループ + CONTROL_MAPPED への
  応答責務。**接続は常駐サービス**（RigBench の 20 秒ループの昇格が必要）
- plugin hash を `hash8(トラック/プラグイン名)`、param hash を `hash6(安定ID)` で発行すれば
  割当はデバイス内に永続し、次回接続時に CONTROL_MAPPED で戻ってくる —
  **ladyland 側に割当 DB を持たなくても復元できる**（デバイスが SSOT）

---

## 2026-08-04〜05 の実測 — SMART 面を実用にするまで

Logic 方言（SMART 面）で 1 日回した記録。**資料と食い違った点**を残す。

### ⚠️ ← → キーはホストに何も届かない

**UMP の最下層（`SysEx7Assembler` に渡す前の生ワード）まで降りて確認した。**
MIDI Clock（type 1、毎秒 3400 個）と Utility（type 0）を落とすと、← → を何回押しても
**1 バイトも増えない**。CoreMIDI に届いていないので、ホスト側でどうにかする余地は無い。

デバイス内部でページを繰るだけで、その通知も来ない。

| ROTO の操作 | ホストに届くか |
|---|---|
| つまみ | ✅ ch15 CC（絶対セル番号） |
| MODE | ✅ SysEx `0B 01` |
| SEL | ✅ SysEx `0B 15` — ただし**押すと PLUGIN 面へ飛ぶ**ので使えない |
| **← →** | ❌ **何も送らない** |
| （常時） | MIDI Clock を垂れ流す |

**ページ送りはホスト側に置くしかない**（ladyland は ⌥←→ と画面のボタン）。

> ⚠️⚠️ **2026-08-11 訂正: この否定は条件付きだった。** ← → は
> **MIX 面 + NUM_TRACKS > 8 宣言**のときだけ ch16 CC60/61（値 2）として届く。
> 上の測定は SMART/PLUGIN 面で行っていた（RK の「喋らない」と同型の
> 「否定測定は条件ごと記録せよ」の実例）。詳細は下の 2026-08-11 節。

---

## 2026-08-11 の実測 — MIX 面を実用にするまで（切り分け 1 日ぶん）

Creo 確定版 `mem_1CdvSucMFyzZ4BEpFgJVpX`。**朝の測定の多くが「毒された実機」相手の
誤測定だった**という一日。順に:

### ⚠️⚠️ 外部からの初期化再生は実機の MIDI 出力を殺す（毒）

dawStart（0A 01）を含む init シーケンスを**アプリの握手と別に**再生注入すると、
実機は「**表示は生きるが MIDI 出力が全停止**」になり、やがて表示も固まる（2 周期で再現）。
- 独立 CoreMIDI リスナー（アプリ非経由）でワイヤに 1 バイトも出ないことを確認
- **この状態で取った否定測定は全部無効**（「LED 消せない」「窓の外では書けない」等）
- 掟: **セッション状態を持つメッセージ（0A 01）は注入禁止**。状態なし（0A 11 / LED CC /
  モーター）は単発注入して安全

### ⭐ 健全な実機で確定した真実

| 項目 | 結果 |
|---|---|
| RK LED（ch16 CC20-27 エコー） | **7F 点灯 / 00 消灯、完全制御**。押下なしの一方的送信でも効く。実機保存のミュート染みも洗える |
| 0A 11 枠書き込み | **セッション途中でも効く**（「初期化の窓」説は死亡） |
| ← →（CC60/61 値 2） | MIX 面のみ + **NUM_TRACKS > 8 宣言が必須**。実機表示は矢印では不動（自分で繰らない）= 窓スライドは DAW の仕事 |
| NUM_TRACKS（0A 04） | 「トラックが何本あるか」の真実を宣言する（64 まで）。**書き込みは見えている枠 0-7 だけ**、と役割を分ける |
| ペーシング | 0A 11 の **5ms バーストは 3 回固まらせた。50ms はゼロ**。大きな塗りは 50ms |
| 0A 09 selectTrack | ⚠️ **毎秒級で勝手に届くことがある**（矢印操作中も）。取説の「false touches」（SENSITIVITY 過敏）が有力。**選択に直結してはいけない**（鳴る楽器が飛ぶ実害を踏んだ） |
| MIX モーター送出（BF 12+i / 44+i） | ⚠️⚠️ **作法未確定のまま送るな** — ブート中の実機に 16 通被せたら黒画面で進行不能になった（単発 Inject で作法を確定させてから） |

### 取説（V1.1.4）から判明したネイティブ意味論

ladyland は Transform 方針（来た信号を内部モデル操作に翻訳）なので、
**実機が各信号に込めている意味**が翻訳の根拠になる:

| 実機ネイティブ | 対応する信号 | ladyland での翻訳 |
|---|---|---|
| ノブタッチ = トラック選択 | 0A 09 + touch CC | （誤タッチ多発のため配線保留） |
| ノブ = VOLUME（**SEL 長押しで PAN / SEND A-L に切替**） | ch16 CC12-19/44-51 | 窓トラックの gain ⚠️ SEL で機能が切り替わっても**同じ CC で届く**はず — PAN に切り替えた状態を検出できないと誤訳になる（未検証） |
| RK = トラック ON/OFF、LED = その状態 | ch16 CC20-27 | ページ直選 + LED = 現在ページ（mako 裁定） |
| ← → = トラックナビ（**64 トラック / 8 ページ**） | ch16 CC60/61 | 窓スライド ±8 — 設計が実機の想定と一致 |
| **← → 同時押し = リターン/マスタートラック**（最大 12） | 未観測 | ⚠️ 未対応。うっかり両押しで未知の信号が来る可能性 |
| LOCK = タッチ選択の無効化 | （実機内で完結？） | ライブ中の誤選択防止にそのまま有用 |
| SYSTEM > SENSITIVITY | — | 誤タッチ（0A 09 スパム）の実機側対処 |

### 未検証（2026-08-11 追加ぶん）

1. MIX モーター送出の正しい作法（黒画面事故の再発防止 — 単発 Inject で 1 通ずつ）
2. SEL 長押しでノブ機能を PAN/SEND に切り替えたとき、DAW に**何か通知が来るか**
   （来ないなら gain 直結は誤訳リスク）
3. ← → 同時押し（リターン/マスター）で何が届くか
4. transport button（CC28-35）

### ✅ MAIN LCD は 2 行 — **2 行目はホストが書ける**（2026-08-06 開通）

8/4・8/5 と 2 度外したが、公式 `config.lua`（3.2.10）を読み直して**両方の原因が分かった**。

| | 8/4-05 に送っていたもの | 正しい形（`config.lua`） |
|---|---|---|
| payload | `0A 16 <0> <0> <name13>`（15 byte） | **`0A 16 <name13>`**（13 byte だけ。L2092-2101） |
| 順序 | いきなり差分を送っていた | **`0C 0A` で名前と色を据えてから**差分（L1508-1540） |

`config.lua` は `0C 0A DAW_SELECT_FOCUS_TRACK` を撃った直後にだけ
`filter_track_name = false` にする — コメントいわく *"Once we set up the track name
and color we can allow track name updates via feedback"*。**据える前の差分は 1 通も送らない。**

```
0C 0A DAW_SELECT_FOCUS_TRACK  <0> <idx> <name13> <RGB6>   据える（名前 + 色）
0A 16 SET_CURRENT_TRACK_NAME  <name13>                     以降、名前だけ
0A 17 SET_CURRENT_TRACK_COLOR <RGB6>                       以降、色だけ
```

実機の反応（`swift run RigBench roto-probe mainlcd`）:

| 通 | 結果 |
|---|---|
| `0A 16`（名前 13 byte） | ✅ **2 行目に出た** |
| `0A 17`（RGB 6 byte） | ✅ **2 行目の背景色が変わった** |
| `0C 0A` の**据え直し** | ❌ 無視された（一度据えたら差分でしか動かない） |

- **1 行目は面の名前**（`SMART`）でデバイスが握っている — ホストからは触れない
- **2 行目は 12 文字**。色は **RGB 直接**（knob LCD と違い 83 色パレットに縛られない）

> **これで「ページ番号は色で示すしかない」が覆る**。knob LCD は 12 文字が名前で
> 埋まるが、MAIN LCD の 2 行目に `P1 Berlin` と出せる。ladyland は SMART 面の
> 投影時にここへ「ページ + 席名」を出し、色は席のページ色と揃える。

### ⚠️ `0A 16` / `0A 17` は MENU 窓ではない

「MENU 窓に現在ページを出す」つもりで送ったら、**ページを繰るたびに LCD が消えた**。

カタログ上は `SET_CURRENT_TRACK_NAME/COLOR` で、`0A 13 SET_TRACK_COLOR` と同じ
**track 系 = MIX 面のコマンド**。`0A 11` を面ガードで塞いだのに、同じ系統の
`0A 16`/`0A 17` をガードの内側に置いていた。

> **追記（2026-08-05）— 撤去した 2 通のうち、悪かったのは `0A 16` だけ**。
> このとき 2 通を一緒に送っていたので切り分けができていなかった。
> 単独で撃ち直したところ **`0A 17` は面を殴らない**（が、効きもしない。下記参照）。

症状の非対称がこれで説明できる:

| | 送信タイミング | 結果 |
|---|---|---|
| 初回描画 | SMART 面へ切り替わる **0.3 秒前** | 副作用が見えない → P1 は正しく出る |
| ページ送り | SMART 面に **居る最中** | 面を殴る → LCD が消える |

### ⚠️ 表示と入力でセル番号がずれている

SMART 面の 16 セルに対し、**LCD は 0-7 を表示しながら、つまみは 8-15 を名乗る**。

実測: 物理ノブ 1-4 が `CC8/40`, `CC9/41`, `CC10/42`, `CC11/43`（MSB/LSB）を送っていた。
一方 LCD には セル 0-7 に書いた内容が出ている。

「セル 0-7 = P1 / 8-15 = P2」と割り当てたら、**LCD には P1 が出ているのに P2 の
パラメータが動いた**。16 セルを 2 ページとしては使えない。

**両方に同じ 8 個を置き、入力は `% 8` で吸収する**のが正しい。

### ⚠️ `Face` に SMART を表す値が要る

面切替は**ホストが起こす**（`selectFace`）ので、デバイスからの通知（`0C 02`）は
MIX 面のものしか来ない。通知を待つ設計だと SMART 面は永久に立たず:

- `.mix` のまま → **SMART 面のラベル投影が恒久的に死ぬ**（面ガードが false）
- `.unknown` のまま → **SMART 面へ `0A 11` を撃つ**（自分で禁じている行為）

送った時点で立てること。

### ⚠️ デバイスは自発的に PLUGIN 面へ帰る

`0B 01` が MODE キーを押していないのに届く（実測: 10 秒後、5 秒間隔で 2 通）。
Logic 方言では PLUGIN 面の LCD をホストから変えられないので、そこに居られると
何を塗っても見えない。**受けたら SMART 面へ引き戻す**（押し合いを避けて 2 秒に 1 回まで）。

### 面に入った直後に塗り直す

面に入る**前**に 16 通を 3 回送っていたため影が埋まり、本命の「入った直後」が
**0 通**になっていた。デバイスが `0B 13` を受け付けるのが面に入った直後だけなら、
唯一のチャンスを使い潰していたことになる。

### 握手が済んだら保険の投影を撃たない

firmware 通知（`0A 0E`）が ~1 秒で来るのに、2 秒後の保険が**必ず二度目の全投影と
面切替を撃っていた**（ログに `smart → smart` の無駄な切替が残る）。

### モーター帳簿のキー空間を揃える

入力側（`handleShort` の `.lsb`）は **Ctrl 番号**で書き、送信側は**物理ノブ番号**で
読んでいた。P1 では ctrl {2,3,4,5,6} がノブ {0,1,2,3,4} の記録を汚し、
「自分の声のこだま」抑止が効かずモーターが往復していた。

### 輻輳は真因ではなかった

ページ送り 1 回で **26 通 / 274 バイト / 66ms**、最大バーストでも 176ms。
`smartCells` を 128 にしていた頃の 640ms 回帰は解消済み。
ただし `MIDISendSysex` の completion を捨てているので、**ROTO が 1 通を何 ms で
飲むかは今も未計測**（LPD8 は 107ms/frame と実測済み）。

### ⚠️ knob LCD は 1 色・1 行だけ（2026-08-05 実測、3 通り試して全部外れた）

「上半分をユーザーの色、下半分をページ固定色」という 2 色表示を狙って総当たりした。

| 試したこと | 根拠にしたもの | 結果 |
|---|---|---|
| `0B 13` の色を 2 バイトに伸ばす | 兄弟の `0A 11 SET_TRACK_DETAILS` が `<color> <0>` と色の後にもう 1 バイト持つ | ❌ 上半分だけが変わる。公式 `config.lua` も 1 色しか積んでいない |
| `0A 17` に RGB 6 バイト（`setFaceColor`） | 公式 `config.lua` L1685-1702 が **SMART / PLUGIN 面**で呼んでいる | ❌ 実機は無視。ただし**壊れもしない** |
| 名前を 12 字未満に詰めて折り返しを狙う | `name13` は 12 字 + NUL 埋めの 13 バイト枠 | ❌ 1 行のまま |

**LCD が受けるのは `0B 13` の 1 色・1 行だけ**。上下 2 色にはできない。

帰結:

- **ページ番号は色で示すしかない**（`0A 16` は面を殴るので使えない → 上記）。
  既定は色相を一周させた 16 色 — 隣のページと違う方が「繰れたか」が分かる。
  ladyland はこの並びを**席ごとに 3 つずつ回して**使う（3 は 16 と互いに素なので
  15 席先まで衝突しない）。**1 色で「どのページか」と「どの席か」を兼ねる**
  ことになるが、2 色を持てない以上これが上限
- LCD の文字にページ番号を添えられるのは「名前 + 空白 1 + 番号」が **12 字に収まるときだけ**。
  溢れたら名前を優先する（ページは色でも分かるが、名前は色では分からない）
- `0A 17` は**無害だが無効**。「公式が SMART 面で呼んでいる」という一次資料つきで
  実装したのに実機が黙った — **`config.lua` に載っていることは実機が応える保証にならない**

---

## 2026-08-11 深夜 — 計測ラウンド（Stage A）の全結果と、MIX 投影の隠れ状態問題

生死判定を自動化した上での計測（`roto-live`: 実機は **MIDI clock を毎秒 24 発**
常時送出 — これが生存信号。⚠️ hello 0A 02 は毎秒**来ない**、旧 lore の訂正）。

| プローブ | 内容 | 結果 |
|---|---|---|
| A-1 | NUM_TRACKS を **MSB 先**（公式スクリプトの形 `00 10`）でセッション中盤に注入 | ⚠️⚠️ **即死**（clock 停止）。下位先 `10 00` は同条件で 3/3 生存 — この個体は下位先でしか受けない |
| A-2 | 宣言 + 16 枠 + **`0A 08` END**（Ableton 方言のコミット） | ⚠️⚠️ **即死** — 方言またぎのオペコード混入は毒（2026-08-03 の掟の再確認） |
| A-4 | 公式正値（SENDS=12 / DEVICES=8 / VU=[106,120]）+ 宣言 + 枠 | 死（ただし下記の隠れ状態問題に飲まれた可能性） |
| 402 | 門（0A 0C）+500ms で投影（= フラッシュロード**前**） | **3/3 生存・3/3 不表示** — 実機は ~4.5 秒後の 0C 01 でフラッシュの保存セットをロードし、それ以前の枠を上書きする |
| 403 | 0C 01 後の settle（初発話 or +5 秒）で投影 | 表示 ✓ → **即死** |
| 再現テスト | 夕方 3/3 生存したレシピ（QUIET + 宣言 + 枠、0C 01 の 10 秒後） | **即死** — 同一条件で結果が割れた |

### 結論: 受け入れ/死は観測外の隠れ状態に支配されている

アプリ差（QUIET/通常）・オペコード・タイミング（+0.5s/+1.5s/+5s/+分）の全変数を
潰しても、同一バイト列の結果が時間帯で割れた。当日この実機は数十回の抜き差しと
十数回のフリーズを経ており、**実機側の蓄積状態の劣化**が最有力。

**MIX モデル投影は `LADYLAND_ROTO_MIX=1`（既定 off）の実験フラグに格下げ**。

### その他の確定事項（今夜ぶん）

- 実機は 0C 01 の後、**自発メッセージを発するときと発しないとき**がある
  （誤タッチ由来のスパムは ready 信号として不安定）
- 「フラッシュへの確定」は**表示成功と別**（夕方の成功 3 回は全部ライブ層止まり、
  電源またぎで消えた）。フラッシュに残った 2 例（朝）はどちらも**二重 dawStart 込み
  + 直後に出力死** — 確定と死が同じ引き金の疑い
- 実機が `0A 0A`（REQUEST_TRANSPORT_STATUS）を要求してくることを初観測
  （応答 0A 0B 8 bytes は未実装 — 未応答でも即死はしない）
- Expression ペダル: Keystage のジャックは**生きていた**（「無反応」の旧実測を反証）。
  ただし CC11（ノブ帯 P2-4 の席）で届く — KONTROL EDITOR で CC115 への再設定が必要

### 次の一手（正規ルート、この順）

1. **ROTO-SETUP でファームウェア再書き込み**（蓄積状態のリセット。別日の最初の一手）
2. 再計測: `roto-live`（clock 生存監視）+ `roto-seq`（scratchpad — 要再建。台本は
   このセッションの記録参照）で、下位先宣言 + 枠のレシピを差し直し 3 連で
3. それでも不安定なら **Ableton 方言（dawType 1）の評価** — ベンダーが実運用で
   出荷している経路（0A 07/08 バッチ + 0A 06 バンク要求、完全仕様が Python で
   読める）。⚠️ PLUGIN 面の stored 資産（Ladyland.json）への影響評価が前提
4. USB ポート / ケーブルの交換も一応の変数
