# bikeboy-ladyland プロジェクト

LPD8 MIDIコントローラーを活用したワークスペース管理ツール + オーディオ・ビジュアル・デバイス統合コントロールシステム。

> **Ladyland** = バンド Bikeboy Experience と、その楽器たち（electric ladies）が住むスタジオ。
> 命名は『Electric Ladyland』へのオマージュ（旧 repo 名: bikeboy、2026-07-23 リネーム）。

## ⚡ 現在の主戦場: `ladyland/`（Swift アプリ、2026-07-30 裁定）

**8/8 大阪ライブ用システムは `ladyland/` に Swift アプリとしてゼロから構築中**（[design/06](design/06-ladyland-app.md)）。
mako 裁定「cortex とかもろもろ既存のものは一度忘れよう。ゼロから、今言ったシステムを構築していこう。Swift アプリとして。」

- **cortex（Rust）はソースをそのまま残す** — 削除も凍結宣言もしない（「後で復活させれば良い」）。35 楽器発音済みの動く保険
- 設計資産（deny list / 切替作法 / Gadget 認証の罠など）は design/06 §5 に持ち越し済み
- Creo 正典: 裁定 `mem_1CdXkBX8ZpC2GWfWLBWir1` / 3D フィールドビジョン原典 `mem_1CdXiVM8pgKHpQRD9JbDGG`（field は 8/8 後の本丸）

## メモリ運用方針

**メインメモリ = Creo Memories の `bikeboy-ladyland` atlas（path `/bikeboy-ladyland`）**。他マシン・バンドメンバーと共有される正典（SSOT）。

- **Creo bikeboy-ladyland atlas が第一保存先**: 設計判断・命名/由来・到達点・仕様など「バンドで共有すべき事実」は必ず Creo に `remember`（`atlasId: "bokeboy"` ※ id は歴史的タイポのまま不変。handle は `bikeboy-ladyland`、2026-07-30 に repo 名へ追従リネーム）。
- **ローカルファイルメモリ**（`~/.claude/projects/<パス>/memory/`）は手元専用に限定: このマシン/パス依存の tips（例: リネーム時のセッション履歴引き継ぎ `cp -n` 手順）など。バンド共有すべき内容は Creo に置き、ローカルには Creo memory ID を書いてリンクする。
- 迷ったら Creo（越境共有される Layer 2）を優先。

## ブランチ運用

```
feature/* ──PR──→ nightly（開発の先端）──マージ──→ main（＝リリース）
```

- **開発の先端は `nightly`**。feature ブランチは nightly から切り、**PR は nightly に向ける**（main ではない）
- **main へのマージ = リリース**。nightly で安定したまとまりを main に上げる
- 2026-07-26 制定（それ以前の PR #1-6 は main 直行だった）

### CI（2026-08-09 導入。詳細は [docs/ci.md](docs/ci.md)）

- **makomac の self-hosted runner** が PR（→ nightly）と nightly push で
  フルマトリクス（`scripts/test-matrix.sh` = 3 モード + release ビルド）を回す
- check が pending のまま = runner が寝ているだけ。**required にしていない**のでマージは詰まらない
- ⚠️ **ライブ当日は止める**: `cd ~/actions-runner && ./svc.sh stop`

### レーン運用（サブエージェント）

- **作業中は nightly を追いかけない — 最後に 1 回だけ rebase**。フル検証は CI に任せ、
  ローカルは開発中 `swift test --filter` + push 前 `scripts/test-matrix.sh --quick`
- **push / PR 作成 / complete の直前に `git fetch` + wire inbox 確認**（指示との行き違い防止）
- lead はマージのたびに wire **event**（ack 不要）で「nightly → SHA、含む PR」を一報する

## プロジェクト構造

```
bikeboy-ladyland/
├── ladyland/                  # ⚡ 8/8 ライブ用 Swift アプリ（主戦場。design/06）
├── bikeboy-launcher/          # Swift製macOSアプリ（MIDIコントローラー連携）
├── bikeboy-mcp/               # MCP (Model Context Protocol) サーバー（Bun + TypeScript）
├── conductor/                 # Rustサービスモニター
├── src/main.rs                # cortex メインアプリケーション
├── crates/
│   ├── cortex-types/          # 共有データ型（AudioFrame, AnalysisData, エラー型）
│   ├── cortex-audio/          # オーディオ処理（cpal + symphonia + rustfft）
│   ├── cortex-gpu/            # GPUレンダリング + 動画エンコード（wgpu + video-rs）
│   ├── cortex-midi/           # MIDI入力（midir）
│   ├── cortex-plugin/         # AudioUnitプラグイン
│   ├── cortex-config/         # KDLプリセット + 設定
│   └── cortex-device/         # MARUデバイス連携
├── spec/                      # 仕様書
├── design/                    # 設計書
└── .fleetflow/                # FleetFlow設定
```

## 技術スタック

- **言語**: Rust (2021 edition), Swift, TypeScript
- **ランタイム**: Bun（Node.jsより高速）
- **リンター**: Biome（ESLintより高速）
- **データベース**: SurrealDB v2.x（Docker via FleetFlow）
- **MCP**: @modelcontextprotocol/sdk
- **オーディオ**: cpal 0.15, symphonia 0.5, rustfft 6.2
- **グラフィックス**: wgpu 28.0, glyphon 0.10, winit 0.30
- **MIDI**: midir 0.10, midi-msg 0.6
- **動画**: video-rs 0.9
- **設定**: knuffel (KDL)

## 開発コマンド

### FleetFlow（データベース）

```bash
fleetflow up -s local    # SurrealDB起動
fleetflow down -s local  # 停止
fleetflow ps             # 状態確認
```

### cortex（Rustオーディオエンジン）

```bash
cargo build               # ビルド
cargo run                 # 実行
cargo run --release       # リリースビルドで実行
cargo test                # 全テスト
cargo test -p cortex-types   # 特定クレート
cargo check               # 型チェック
cargo clippy              # Lint
cargo fmt                 # フォーマット
```

### bikeboy-mcp

```bash
cd bikeboy-mcp
bun install              # 依存関係インストール
bun run start            # サーバー起動
bun run dev              # 開発モード（watchモード）
bun run check            # 型チェック
bun run lint             # Biomeリント
```

### ladyland（⚡ 主戦場）

```bash
# 本番の起動 = Mac アプリとして（mako 裁定 2026-08-02）
# ⭐ 実機確認の既定は --reinstall（mako 運用 2026-08-12「基本 Applications
#    直下の Ladyland で実機確認」）。--run の dist 直起動は /Applications 版と
#    二重起動になりやすい — 実機確認前の積み込みは必ず --reinstall で
scripts/build-app.sh --reinstall # 開発の輪: 終了 → ビルド → /Applications 差し替え → 起動
scripts/build-app.sh --run       # dist/Ladyland.app を組んで起動
scripts/build-app.sh --install   # さらに /Applications へ（Spotlight から起動できる）
scripts/build-app.sh --dist      # 他の Mac へ配る（公証 + staple + DMG。docs/distribute.md）

cd ladyland
swift build              # ビルド
swift run Ladyland       # 開発時の実行（※ swift run 単体は RigBench と
                         #  曖昧になりエラー — 必ずターゲット名を付ける）
swift run -c release Ladyland   # 実音確認（debug は負荷余裕が別物。クリップ検証も release で）
swift run RigBench       # 機材測定ベンチ集（一覧表示。lpd8-led-rate 等）
swift test               # 全テスト
scripts/test-matrix.sh          # フルマトリクス（3 モード + release ビルド。CI と同一）
scripts/test-matrix.sh --quick  # push 前チェック（既定 env の swift test のみ）

# render コストの計測（192kHz の締切に対する占有率。既定の swift test では skip）
LADYLAND_BENCH=1 swift test -c release --filter RenderBenchTests
```

### 🚨 会場での退避路（何かが壊れたとき）

**すべて既定 on。`=0` で切る。** 当日フラグを思い出す必要がある状況＝
何かが壊れている状況なので、**探し回らずに済むようここへ集めてある**。
⚠️ `=0` 系の退避路を足したら **`scripts/test-matrix.sh` の ESCAPE_HATCHES にも足す**
（マトリクスのモード 2 = 退避路すべて 0 の検証がズレる）。

```bash
# 音が間延びする / 音程がおかしい → 44.1kHz で一貫させる（確実に鳴る）
LADYLAND_BUS_FOLLOW=0 swift run -c release Ladyland

# ROTO の knob が死んだ / 面が殴られる → MAIN LCD の投影を止める
LADYLAND_MAIN_LCD=0 swift run -c release Ladyland

# ROTO の knob が活性を失う → 空セルへの表示送信を止める（残像は戻る）
LADYLAND_FILL_EMPTY=0 swift run -c release Ladyland

# 空きノブを触りたい / 挙動が変 → 空きノブにも値を送る（従来の挙動）
LADYLAND_PARK_EMPTY_KNOBS=0 swift run -c release Ladyland

# Keystage の PAGE -/+ が効かない / VALUE エンコーダーが反応しない
#   → 接続手順を 1 つずつ止めて切り分ける
# ⚠️ **切り分けには USB の差し直しが要る** — Controller Mode はアプリを
#    終了しても機材に居座るので、⌘Q だけでは元の状態に戻らない
LADYLAND_KEYSTAGE_CONNECT=0 swift run -c release Ladyland     # 0x6F 接続を送らない
LADYLAND_KEYSTAGE_ASSIGNABLE=0 swift run -c release Ladyland  # Assignable 固定を送らない

# ⭐ **PAGE が生きたまま設定も読める**（既定 on、2026-08-07 に既定化）
#   握手（Dump 取得）を済ませてから **切断**（0x6F payload 00）を送る。
#   繋ぎっぱなしだと PAGE が死ぬ、が実機で確定している。
#   書き戻し（ボタンを焼く / 設定変更 / 和音）の**間だけ繋ぎ直す**。
# ⚠️ OLED 表示（0x28）や Clock → BPM が変なら、まずここを切って切り分ける
LADYLAND_KEYSTAGE_RELEASE=0 swift run -c release Ladyland     # 切断を送らない（繋ぎっぱなし）

# Keystage のノブ OLED 表示は**既定 off**（恒久表示はファームウェア制約で不可 —
#   0x28 は接続中のみ有効・切断約 1 秒後に実機が CCn へ描き直す・
#   接続しっぱなしは PAGE が死ぬ。実測 2026-08-10）。
#   `=1` で「切替時 1 回のフラッシュ表示」として試せる
LADYLAND_KEYSTAGE_OLED=1 swift run -c release Ladyland        # OLED フラッシュ表示を有効化

# 計測そのものを切りたい → render の実測を止める
# ⚠️ **ログを黙らせる目的では要らない**（2026-08-07 に既定を静かな側へ倒した）。
#    平時は何も出ず、**レート変化 / ブロック長変化 / 締切が危ない**ときだけ出る。
#    ここを切るのは「計測の費用そのものを削りたい」ときだけ
LADYLAND_RENDER_STATS=0 swift run -c release Ladyland

# 逆に、render の実測値を毎回見たい（リハで数字を残す）
LADYLAND_RENDER_STATS_ALL=1 swift run -c release Ladyland

# Field（Vision Pro）が怪しい → field 接続ごと切る（音は field と無関係に鳴る）
LADYLAND_FIELD=0 swift run -c release Ladyland

# fieldd の自動起動・自動入れ替えを止める（手動運用 / 別 PC 構成のとき）
LADYLAND_FIELD_SPAWN=0 swift run -c release Ladyland
```

⚠️ **ライブ当日は CI runner も止める**（render に割り込ませない）:
`cd ~/actions-runner && ./svc.sh stop`（docs/ci.md）

**複数まとめて切ることもできる**（原因が絞れないときは全部切って素の状態へ）:

```bash
LADYLAND_BUS_FOLLOW=0 LADYLAND_MAIN_LCD=0 LADYLAND_FILL_EMPTY=0 \
  LADYLAND_PARK_EMPTY_KNOBS=0 swift run -c release Ladyland
```

⚠️ **起動ログに現状が出る** — `bus-follow: …` と `roto flags: …` の 2 行を見れば、
いまどのモードで動いているか分かる。


> **本番は必ず `.app` から起動する**。CLI 直起動（unbundled）は **⌘Q も
> AppleScript quit も効かず**、終了時保存（`willTerminate`）が走らない —
> TERM 落ちで状態を失った実例がある（design/06 §8）。バンドルなら
> Dock/⌘Tab にアイコンが出て、終了時の保存も確実に走る。

### bikeboy-launcher

```bash
cd bikeboy-launcher
swift build              # ビルド
swift run                # 実行
```

### conductor

```bash
cd conductor
cargo build              # ビルド
cargo run                # 実行
```

## cortex 操作方法

### キーボード

| キー | 機能 |
|------|------|
| Space | ファイル再生/一時停止（インストゥルメントのライブ演奏は継続） |
| Tab | 演奏モード切替（A行=白鍵、W行=黒鍵、Z/X=オクターブ変更） |
| I | インストゥルメント循環選択（初回はSerum優先） |
| M | MIDIフォーカス切替（bikeboy ⇄ 外部/VP。design/03参照） |
| E | AUReverb2 をエフェクトチェーンにロード |
| B | エフェクトチェーンのバイパス切替 |
| R | 録画開始/停止 |
| O | テスト用オーディオファイルのロード |
| 1 / 2 | シーンインデックス切替（※下記「現状の配線」参照） |
| Esc | 終了 |

演奏モード中も Space / R / B / I / M / Esc / Tab は有効（E と O は黒鍵に割当のため無効）。
ハードウェアMIDIキーボード（Keystage等）のノート入力はインストゥルメントへルーティングされる
（MキーでMIDIフォーカスを外部アプリに譲っている間は無視。[design/03-midi-focus-model.md](design/03-midi-focus-model.md)）。

### MIDI（ビジュアル向け CC）

CC のルーティング境界は `VISUAL_CC_MAX = 7`（CC 0-7 → ビジュアル、CC 20+ → プラグインパラメータ）。

| CC | パラメータ | 配線状況 |
|----|-----------|---------|
| 0 | 回転速度 | ✅ 有効（WGSL が参照） |
| 1-7 | （モジュレーション／色相／グロー等を想定） | ⚠️ uniform までは届くが**シェーダ未参照** |
| 16-19 | custom_params | ⚠️ 同上（未参照） |

### 現状の配線（2026-07-26 実地調査）

> ドキュメントと実装のズレを防ぐため、**実際に効いているもの**を明記する。
> 詳細と改善方針は [design/04](design/04-sound-and-field-layers.md)。

**映像側で実際に生きているのは 2 つだけ**:
- **オーディオ自律反応**（bass / mid / high / beat_intensity → WGSL が参照）
- **CC 0 の回転速度**

**器はあるが未配線**（構造体・パーサは存在するが実行経路に繋がっていない）:
- `PresetManager` — main.rs で構築されるのみ。`.kdl` プリセットは 0 個、ロード処理も未呼び出し
- `Scene` 定義 / `transition_time` / `Preset.midi_mappings` — preset 経由のため全て未接続
- `scene_index` — uniform には届くが WGSL が読まないため**切り替えても画は変わらない**（`scene_transition` は常に 0.0）
- シェーダ選択 — `GEOMETRIC_SHADER` をハードコード
- `keystage_default_mappings()` / `CcMapping` — 未使用（dead code）
- `MidiHub`（cortex-midi、2026-07-26 追加）— **main.rs から一度も参照されていない**。main は今も `MidiHandler` + `MidiController` で動いており、リグ4台の同時接続は未稼働。`pub use` で re-export されているため **dead_code 警告も出ない**（配線し忘れをコンパイラが検出できない例）。配線は [design/05](design/05-live-rig-architecture.md) §7 の S1b

**楽器側は実装済みで稼働**: AU インストゥルメント・エフェクトチェーン、PCキーボード演奏、X-Touch Main フェーダー、MIDI focus、MARU 連携。

## アーキテクチャ

### Context × Scene モデル

- **Context**: 作業文脈（例: "開発", "執筆", "学習"）
- **Scene**: Context内の具体的なシーン構成
- **App**: Scene内で起動するアプリ情報

### LPD8マッピング

- パッド1-8: Context切り替え（起動中ならScene循環）
- ノブ1-8: 音量調整（将来的に拡張予定）

### cortex パイプライン

cortex は当初「オーディオファイルを映像化するツール」として作られたが、
現在は **AU 音源をホストして演奏できるライブ楽器**に育っている（主語が「再生」から「演奏」へ）。

```
                              ┌→ Analysis (FFT) ─┐
Audio File → Decoder → Player ┘                  │
                                                 ↓
Instrument (AU) ← 演奏 ← PCキーボード / ハードMIDI   Shader Uniforms → wgpu → 画面
       ↓                                         ↑                      └→ Encoder → MP4
  Effect Chain → master_gain ⇄ X-Touch フェーダー   │
                                                 │
                        MIDI CC 0-7 ─────────────┘   （CC 20+ → プラグインパラメータ）
```

- **音の経路**: ファイル再生と AU インストゥルメントのライブ演奏は独立（Space はファイル側のみ制御）
- **映像の経路**: FFT 解析結果と MIDI CC が `ShaderUniforms`（128バイト）に集約され毎フレーム GPU へ
- **MIDI focus**: M キーで外部（VP/Bastet）に譲れる（[design/03](design/03-midi-focus-model.md)）

## ドキュメント

- [仕様書: spec/03-wave-generator.md](spec/03-wave-generator.md)
- [設計書: design/02-wave-generator-architecture.md](design/02-wave-generator-architecture.md)

## 注意事項

### SurrealDB接続（TypeScript SDK v2.x + SurrealDB v2.x）

**接続は `connect()` に一本化**。v1 の `connect` → `signin` → `use` の 3 段は廃止：

```typescript
await db.connect(DB_URL, {
  namespace: 'bikeboy',
  database: 'launcher',
  authentication: { username: 'root', password: 'root' },
});
```

**テーブル名・レコードIDは生文字列を渡さない**。v2 では型付きラッパーで区別する
（v1 は `"context"` がテーブル名かレコードIDか実行時まで判別できなかった）：

```typescript
import { StringRecordId, Surreal, Table } from 'surrealdb';

await db.select(new Table('context'));                       // テーブル全件
await db.create(new Table('context')).content(data);         // 作成（.content() 後置）
await db.update(new StringRecordId(id)).merge(data);         // 更新（v1 の db.merge 相当）
await db.delete(new StringRecordId(id));                     // 削除
```

### wgpu

- macOS: Metal backend
- Windows: DirectX 12 / Vulkan
- Linux: Vulkan

### シェーダー

- WGSL形式
- ユニフォームは16バイトアライメント
- フルスクリーン三角形パターンを使用

### 動画エンコード

- video-rsはFFmpegを内部使用
- H.264エンコードにはシステムにFFmpegが必要な場合あり
