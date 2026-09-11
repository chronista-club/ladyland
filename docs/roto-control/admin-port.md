# ROTO-CONTROL アドミンポート — USB シリアル直結の設定読み書きプロトコル

**出典**: ROTO-SETUP.app（Electron）の `app.asar` 解剖（2026-08-12。
`/Applications/ROTO-SETUP.app/Contents/Resources/app.asar` → `backend/protocol.mjs` /
`backend/device.mjs` / `backend/connection-manager.mjs` / `common/js/payload.mjs`）。
公式スクリプト完全地図（official-scripts-map.md）の姉妹編 — あちらは DAW セッション
（MIDI SysEx）、こちらは**設定の読み書き（USB シリアル）**。

## なぜ重要か（mako 発案 2026-08-12「動的に ROTO を更新できたら開発捗るしね」）

**MIDI setup の読み書きは MIDI ポートを通らない** — RP2040 の複合 USB デバイスが
生やす **CDC シリアルポート**で行う。だから MIDI の盗聴では何も見えなかった。
ladyland がこのポートを喋れば:

1. **64 冊を直接焼ける**（ROTO-SETUP の File > Import 手作業が消える）
2. **ノブ LCD のライブラベル書き換え**（MIDI モードでパラメータ名を出す）
3. **SEL のリモート操作**（`MIDI_SET_SETUP` — 曲ごとのシーン切替をホスト主導で）
4. **読み戻し検証**（GET 系 — Export All に頼らず実機の現状を照合できる）

## 接続

- **USB VID/PID**: `0x2E8A` (Raspberry Pi) / `0xF010`。実体は RP2040
- CDC シリアル **115200 baud**。ポートが 2 本生えることがあり、
  **1 本目 = アドミンポート、2 本目 = デバッグコンソール**（あれば。
  文字列ログがそのまま流れてくる）
- macOS では `/dev/cu.usbmodem*`。POSIX open + termios で足りる（依存不要）
- **リクエストは常に 1 本だけ in flight**（公式実装の作法 — 詰めて送ると失う）

## フレーミング

```
コマンド:  5A <family> <sub> <sizeMSB> <sizeLSB> <data …>
レスポンス: A5 <responseCode> …（期待バイト数はコマンドごとに既知）
```

- responseCode `00` = OK / `FD` = RESPONSE_UNCONFIGURED（未設定の席を GET したとき）
- データ長は 16bit（最大 0xFFFF）

## コマンドカタログ

### GENERAL (0x01)

| sub | 名前 | 意味 |
|---|---|---|
| 01 | GET_FW_VERSION | ファームバージョン取得 |
| 02/03 | GET/SET_ATARI_MODE | （命名の由来は不明） |
| 04 | **START_CONFIG_UPDATE** | 設定書き込みの開始括弧 |
| 05 | **END_CONFIG_UPDATE** | 終了括弧（フラッシュ確定と思われる） |
| 06 | FACTORY_RESET | ⚠️ 工場出荷リセット |

**全ての設定書き込みは 3 連リクエスト**: `START_CONFIG_UPDATE` → 本体 → `END_CONFIG_UPDATE`
（公式 `configUpdateRequest()`）。

### MIDI (0x02)

| sub | 名前 | 意味 |
|---|---|---|
| 01 | GET_CURRENT_SETUP | 現在の setup index + 名前 |
| 02 | GET_SETUP | 指定 index の setup 名 |
| 03 | **SET_SETUP** | **setup 切替（= SEL のリモート操作）** |
| 04 | SET_SETUP_NAME | setup 名の書き込み |
| 05/06 | GET_KNOB/SWITCH_CONTROL_CONFIG | 席の設定読み出し |
| 07/08 | **SET_KNOB/SWITCH_CONTROL_CONFIG** | **席の設定書き込み** |
| 09 | CLEAR_CONTROL_CONFIG | 席のクリア |
| 0B | CONTROL_LEARNED | （実機→ホストの通知。LEARN 完了） |

### PLUGIN (0x03)

PLUGIN モードの資産も完全 CRUD がある（GET_FIRST/NEXT で列挙、ADD/SET/CLEAR、
KNOB/SWITCH config、SET_PLUGIN_NAME）。Ladyland.json 相当を直接読み書きできる。

### MAINTENANCE (0x04)

ENTER/EXIT_MAINTENANCE、**ENTER_BOOTLOADER**（ファーム書き込みは picoboot
mass-storage へ落として UF2 — `firmware_utils/rp2040-picoboot-*.mjs`）。

## MIDI_SET_KNOB_CONTROL_CONFIG (02 07) のペイロード

```
SI CI CM CC CP NA:2 MN:2 MX:2 CN:13 CS HM HI1 HI2 HS SN:16×13
```

| 欄 | 意味 |
|---|---|
| SI | setup index 00-3F |
| CI | control index 00-1F（ページ主導連番 = 実機確認済み） |
| CM | 0=CC 7bit / 1=CC 14bit / 2=NRPN 7bit / 3=NRPN 14bit |
| CC | MIDI ch 00-0F |
| CP | CC 番号（未使用は FF） |
| NA | NRPN アドレス（BE 16bit） |
| MN/MX | min/max（BE 16bit。7bit モードは MSB=00） |
| CN | 13 byte NULL 終端 ASCII（パディング 00） |
| CS | colorScheme |
| HM | 0=KNOB_360 / 1=KNOB_300 / 2=KNOB_300_TOP_INDENT / 3=KNOB_16_STEP_ENDLESS / 4=KNOB_N_STEP |
| HI1/HI2 | インデント位置（FF = off） |
| HS | ステップ数 02-16（N_STEP のみ） |
| SN | 16 本の 13 byte 文字列（ステップ名） |

ボタン (02 08) は `LN LF`（LED on/off color。既定 on=14 白 / off=70 黒）が入り、
モードは 0=CC7 / 4=ProgramChange / 5=Note、タイプは PUSH(0)/TOGGLE(1)。

Export JSON（`RotoMidiSetup`）のフィールドと 1:1 — JSON はこのペイロードの
別表現に過ぎない。

## 検証結果（2026-08-12、実機 3.2.0 dcf8018 + RigBench roto-admin）

1. ✅ **「CC が止まる」の真の主語はアドミンポートの open** — ladyland/RigBench が
   open している間だけ MIDI モードの CC 送出が止まり、**close で即復帰**
   （単離実験: info の open 窓 70-80 秒だけ CC が消えた）。差し直しは不要。
   **読み書きは瞬間芸（open → 用事 → close）にする** — これが設計の掟
2. ✅ **読み取り（GET 系）と SEL リモート（SET_SETUP）は安全** — 64 冊列挙も
   遠隔切替（rc=00、実機表示も追従）も、close 後の CC に後遺症なし
3. ⚠️ **MIDI clock は生存信号ではない** — Motion Recorder の INT/EXT CLK 設定で
   出たり出なかったりする（INT 120BPM = 48/秒、EXT = 0 発）。
   死活判定に clock を使うな（2026-08-11 深夜の lore を訂正）
4. 未検証のまま: **書き込み系（SET_KNOB_CONTROL_CONFIG + START/END 括弧）の
   反映タイミングと後遺症** — ROTO-SETUP の File > Import（= 全冊書き込み）後は
   差し直しが要った実績があるので、席単位の書き込みで再確認してから
   64 冊焼きを実装する

## ladyland 実装の設計素描

- `RotoAdminPort`（POSIX serial、`/dev/cu.usbmodem*` を VID/PID で特定 →
  IOKit か `ioreg` 照合）+ `RotoAdmin`（フレーミング純粋層、RotoKit）
- 64 冊焼き = setup ごとに `SET_SETUP_NAME` + `SET_KNOB_CONTROL_CONFIG` × 32
  （それぞれ START/END 括弧つき、1 リクエストずつ直列）
- 検証は GET 系での読み戻し照合が Export All より速くて確実
