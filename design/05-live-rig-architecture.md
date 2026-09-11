# Design 05: ライブリグ・アーキテクチャ — 試金石ライブに向けた音の基盤

> **Status**: 演奏要件確定・実装フェーズ（2026-07-30 改訂）。実装スライスは §7。
> **改訂履歴**: 2026-07-26 初版（機材調査完了時点）→ 2026-07-30 演奏要件の確定により §3/§4/§5/§6/§7/§8 を改訂。
> 主な変更: ①**Swift は入らない**（`rack` が AU GUI を持つ・§4）②**8楽器 × LPD8 選択**の要件を反映（§7）③**ROTO と L6max MIDI をスコープ外**へ
> **Why の起点**: mako 2026-07-26「まずは音。ビジュアルや field の構築は数ヶ月先。音だけでやりたいことができる基盤を作る」「現状はもう作り変える勢いで良い。使えるものは残す」「あせらずゆっくり、一歩一歩」。
> **スコープ**: 直近ライブは**試金石** — 次のライブをどうするかを知るために一度ちゃんと使う。cortex が扱うのは **mako 自身の音だけ**（バンドの他の音は L6max に直接入る）。
> **関連**: [doc 03 MIDI Focus](03-midi-focus-model.md) / [doc 04 sound & field 四層](04-sound-and-field-layers.md) /
> 機材リファレンス: [Keystage](../docs/keystage/README.md)・[L6max](../docs/l6max/README.md)・[FGDP-50](../docs/fgdp-50/README.md) /
> VP 資産: [doc 20 ROTO](~/repos/vantage-point/docs/design/20-roto-control-sysex-protocol.md)・[doc 22 LPD8 mk2](~/repos/vantage-point/docs/design/22-lpd8-mk2-protocol.md)・`midistage-profiles` crate

---

## §1. 目標と価値基準

試金石ライブに求める性質は2つだけ:

1. **確実に動く** — 本番で落ちない・音が出ないが起きない。機能の多さは価値基準ではない
2. **後から何が起きたか分かる** — 何を触ったか・何が足りなかったかが残り、次のライブの設計判断が事実に基づける

## §2. 機材グラフ（確定版・rigcheck 実測済み）

```
Keystage KBD/CTRL ─┐(USB MIDI)
LPD8 mk2          ─┼→ MacBook Air M5 [cortex] ─USB 4ch→ ┐
Roto-Control      ─┘         ↑14ch(将来)                 │
                                                  ZOOM L6max ─→ 会場
FGDP-50 ──自身の音(アナログ、ステレオミニ)──────────→ │   ↑↓ MIDI(卓の読み書き)
バンドの他の音 ─────────────────────────────────────→ ┘
```

- cortex → L6max: Mac 出力 ch1-2 → 卓 **CH7**、ch3-4 → 卓 **CH8**（`USB 1/2`/`USB 3/4` キー点灯必須）
- FGDP-50 は **cortex 非依存**（fail-open な飛び道具。アナログで直接卓へ）
- L6max は出口であり**ハブ**: 音声4系統 + MIDI 双方向（卓の CC 読み書き）+ 入力14ch（将来の自律層向け）
- 全台とも録音: 卓の 14tr 録音（48k/32float）が「後から分かる」の主装置。32GB で約3.2時間

## §3. 機材の役割と知識の所在

| 機材 | 役割 | 表現・表示面 | 知識の SSOT |
|---|---|---|---|
| **Keystage** | メイン楽器（鍵盤） | ポリ AT（`0xA0`）、OLED 9面（SysEx で書ける）、ノブ8 | `docs/keystage/README.md` |
| **LPD8 mk2** | **楽器選択**（パッド8 = 楽器8） | パッド8（フル RGB LED 一括更新可） | VP doc 22 + `midistage-profiles` |
| **ROTO-CONTROL** | パラメータ操作 — **今回オミット**（§7） | モーターノブ8（14bit）+ LCD 9 + RGB ボタン16 | VP doc 20 + `midistage-profiles` |
| **FGDP-50** | 飛び道具（自身の音源） | パッド26（ポリ AT）、cortex 非依存 | `docs/fgdp-50/README.md` |
| **L6max** | 出口＋記録 — **今回は手元ミキサー。MIDI 連携なし**（§7） | エンコーダ8（LED リング）、CC 双方向 | `docs/l6max/README.md` |

**リグの本質**: 全デバイスが双方向（触れると応え、状態を表示する面の集合）。sound & field の「歩く層」を張るキャンバス。

## §4. ソフトウェア構成

### 層構造

```
┌───────────────────────────────────────────────┐
│ アプリ層  cortex (bikeboy-ladyland)            │
│   ├ I/O 層      cortex-midi: MidiHub(N台接続・  │ ← ladyland の宿題
│   │             識別・ホットプラグ)、ルーティング   │
│   ├ 楽器層      cortex-plugin: AU ホスト(既存)   │
│   ├ 音声層      cortex-audio: 出力デバイス選択    │
│   └ 設定層      cortex-config: KDL(焼く層)      │
├───────────────────────────────────────────────┤
│ プロトコル層  midistage-profiles (VP workspace)  │ ← path 依存で共有
│   DeviceProfile(投影) / ControlEvent(入力解釈)   │    I/O なし・純粋計算
│   ROTO / X-Touch / LPD8 mk2 実装済み            │
├───────────────────────────────────────────────┤
│ transport 資産  midistage-core (midistage repo) │ ← 必要になったら
│   CoreMIDI FFI (RX完備) / UMP                   │    (v0 で足りるか要評価)
└───────────────────────────────────────────────┘
```

- `midistage-profiles` は docstring に「bikeboy は cortex-midi の仕事」と**共有前提が明記済み**（2026-07-15 mako 決定）。Keystage profile を足す場合もここに書く（艦隊で共有）
- ladyland が書くのは **I/O 層だけ**: ポート接続・識別・polling・送出・ホットプラグ

### 言語判断

> **cortex は Rust で完結する。Swift は入らない**（2026-07-30 改訂）。

- **MIDI 層は Rust 継続**。根拠:
  - 実機検証済みのプロトコル資産（`midistage-profiles` 1448行）がそのまま使える
  - CoreMIDI の深い機能（Device/Entity 階層・UniqueID）が要る場合も `midistage-core` の FFI 直バインドという舗装済みの道がある
  - **訂正**: VP doc 20 §8 の「Keystage は MIDI 2.0 ネイティブで UMP バックエンド必須」は誤り。一次資料検証（`docs/keystage/README.md`）で **MIDI 1.0 バイトストリーム機と確定、midir で足りる**
- **AU の画面も Rust から出せる**
  - **訂正（2026-07-30）**: 旧版は「Swift が入るのは AU ホスティングの UI。ここは Rust から現実的に届かない」としていたが**誤り**。既存依存の **`rack 0.4.8`** が `PluginInstance` trait で safe API を提供している:

    | API | 用途 |
    |---|---|
    | `create_gui()` / `AudioUnitGui` | AU 画面の表示 |
    | `get_state()` / `set_state()` | 音色 blob の保存・復元 |
    | `preset_count()` / `preset_info()` / `load_preset()` | プリセット列挙・選択 |

  - **制約**: GUI は **main thread から呼ぶ必要**（macOS/AppKit 要件）。cortex は winit がイベントループを握り、プラグイン本体は別スレッドの `PluginProcessor` が所有するため、この受け渡しが実装上の山場
  - `get_state`/`set_state` の存在が「スタジオで 8 つの音色を作り込み、本番は選ぶだけ」を可能にしている（doc 04 の焼く層／歩く層がそのまま実装に落ちる）
  - `bikeboy-launcher/`（Swift）は LPD8 でワークスペースを切り替える**別アプリ**。cortex とは無関係
- 映像層（wgpu）は数ヶ月先まで凍結。既存資産のまま置く

> **教訓**: Swift の範囲は 3 回とも「**依存に既にあるものを確認したら縮んだ**」（`midistage-core` の CoreMIDI FFI → MIDI 層が外れ、`rack` の `create_gui` → AU UI が外れた）。本節は MIDI 2.0 の訂正も含め、**一次資料に当たると覆る記述の密集地帯**。言語・プロトコルの「できない」判断は手元の依存を確認してから下すこと。
> 経緯の詳細: Creo `mem_1CdWkMNEYd725c6CcdkBnw`

## §5. 設計原則（機材調査から導出）

1. **fail-open** — 各機材は「無くても他が完全に動く」。FGDP は構造的に独立、ROTO/LPD8 が無くても Keystage は鳴る（doc 03 の原則をリグ全体へ拡張）
2. **Realtime フィルタ** — Keystage は MIDI Clock (F8) を常時送信し止められない。入力段で Realtime メッセージを弾く
3. **エコー抑止** — L6max は CC 双方向。送信直後の同一 CC を無視する窓を持つ（X-Touch のタッチ抑制と同型）。⚠️ **今回スコープ外**（L6max は MIDI 連携しないため。§7）
4. **ホットプラグ再接続** — L6max は USB 再列挙でポートが stale になる。保存名（将来は UniqueID）での再接続処理を I/O 層に組み込む
5. **ピックアップ** — Keystage のノブは終点ありポット（値を送っても物理位置は動かない）。切替時は pickup 動作で段差を吸収
6. **表示は state projection** — OLED/LED/モーターへの出力は「値を送る」ではなく「意味（名前・色・値）を一括投影」（ROTO の learn モデルに倣う。doc 20 §5 の設計含意）
7. **入力は2層** — 物理 primitive（CC/note → 演奏系）と semantic（SysEx → モード切替系）を別ハンドラで受ける（doc 20 §7）
8. **CC マップはハードコードしない** — L6max の CC は卓側設定で変わる。設定（KDL）に外出しする。⚠️ **今回スコープ外**（同上。§7）

## §6. doc 04 四層との対応（今回のスコープ）

| 層 | 今回やる範囲 |
|---|---|
| **焼く**（スタジオ） | **8つの楽器を作り込み、`get_state` で音色を保存**（§7 S-B/S-C）。KDL 外出しは今回スコープ外 |
| **合わせる**（現地リハ） | 最小限: L6max の卓側設定（USB キー・シーン）+ cortex の出力デバイス固定。`VenueConfig` の本格版は次のライブ以降 |
| **歩く**（本番） | **LPD8 パッドで楽器を選び、Keystage で演奏する**。ROTO・卓エンコーダは今回オミット |
| **自律** | 既存の audio 解析のみ（映像は凍結中のため出番は薄い） |

## §7. 実装スライス（2026-07-30 改訂 — 演奏要件の確定により再構成）

### 確定した演奏要件

- **8つの楽器を準備**し、**LPD8 のパッド 1-8 で選択**する
- **Keystage は選択中の楽器を演奏**する
- **同時に鳴るのは 1 つ、多くて 2 つ**。30分のライブの中で 8 つを使い分ける
  → 8つは**ロードのみ常駐**させ、`process` は**選択中 + リリース中の最大 2 つ**に絞る
- **L6max は手元ミキサー**。cortex からは音声出力先としてのみ扱う（**MIDI 連携はしない**）
- **ROTO はオミット** — コントロールが難しく、handshake+learn という前提条件を抱えて重い

### スライス

| # | スライス | 状態 | 内容 |
|:--:|---|:---:|---|
| **S0** | 8 インスタンスのロード確認 | 軽 | **同時発音が 1〜2 のため CPU は非問題**（`process` を呼ばない AU はほぼ無負荷）。確認するのは**メモリと起動時の一括ロード時間**のみ。実機は M5 / 10コア / **24GB** のため実質クリア |
| **S-A** | AudioMixer の 8 スロット化 | 新規 | 現状 `AudioMixer.instrument` は `InstrumentSlot` の**単数保持**。8つは**ロードのみ常駐**させ、`process` は**選択中 + リリース中の最大 2 つ**に絞る（切替時に前の音を鳴らし切るため。即停止するとブツ切れになる）。本番中のロードは音が途切れるため事前ロード必須 |
| **S-B** | 音色の保存・復元 | 新規 | `get_state`/`set_state`（§4）。「準備する」の実体 |
| **S-C** | AU 画面 | 新規 | `create_gui`（§4）。音色を作るのに必要。main thread 制約の統合が山場 |
| **S1b** | MidiHub を main に配線 | **未完** | S1a でモジュールは書かれたが**実行経路がゼロ**（`main.rs` から参照されていない）。Realtime フィルタ（§5 原則2）も未実装 |
| **S-E** | LPD8 パッド → スロット選択 | 旧 S2 縮小 | **パッド8 = 楽器8**。`Lpd8Profile` の LED 一括更新で選択中を表示 |
| **S-F** | Keystage → 選択中スロット | 旧 S2 縮小 | |
| **S3** | 出力デバイス固定 + レイテンシ実測 | 既存 | 「ZOOM L6max」に名前で固定（OS 既定任せをやめる）。4ch 送出の割当 |

各スライスは小さく完結させ、実機で確認してから次へ（あせらず一歩一歩）。

### スコープ外（本番後に回収）

- **S4: 焼く層の KDL 外出し** — ハードコードで本番を通す。`cortex-config` は死んだまま置く
- **S5: 投影の残り** — ROTO handshake+learn、Keystage OLED
- **L6max の MIDI 連携** — §5 原則3（エコー抑止）・原則8（CC マップ外出し）は今回**不要**
- **旧「別線: Swift AU UI」** — §4 のとおり `rack` で Rust から出せるため**消滅**

## §8. 未解決・実機で確定する事項

- **AU GUI の main thread 統合**（§4）。winit のイベントループと別スレッドの `PluginProcessor` をどう繋ぐか — **最大の未知数**
- 起動時に 8 インスタンスを一括ロードする所要時間（本番前のセットアップなので許容範囲は広いが、実測しておく）
- 楽器切替時のリリース処理 — 前スロットの `process` をいつ止めるか（無音を検出するか、固定時間で切るか）
- 各機材 README の ⚠ 項目（Keystage: SysEx 宛先ポートの実証ほか6件）
- 実効レイテンシ（鍵盤 → cortex → L6max 出音）の実測。往復 16-17ms の報告があるため、出音遅延が演奏感を損なう場合はバッファ/経路の再検討

**解決済み**:
- ~~Serum 級の AU を 8 インスタンス同時に回せるか~~ → **同時発音は 1〜2**（30分の中で 8 つを使い分ける）と確定。`process` を呼ばない AU はほぼ無負荷のため CPU は非問題。メモリも実機 24GB でクリア
- ~~Swift AU UI の具体形（プロセス分離の方式）~~ → §4 のとおり `rack 0.4.8` の `create_gui()` で Rust から出せる。Swift 不要
- ~~ROTO learn の PLUGIN mode 表示~~ → ROTO オミットによりスコープ外
- ~~L6max のエコーバック・LED 追従~~ → MIDI 連携しないためスコープ外
