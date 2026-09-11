# Design 04: sound & field — パラメータの三層＋自律層

> **Status**: 思想確定・写像済み。「合わせる」層（`VenueConfig`）は未実装（本ドキュメントが設計起点）。
> **Why の起点**: mako 2026-07-26。小説を読む体験（「すでに書いてあるのに、私の中で文章が“生まれていく”。進めるテンポはこちら側にある」）を起点に、BIKEBOY のインプロ観 = **sound & field** を結晶させた対話。
> **SSOT（思想）**: Creo bikeboy atlas `sound-and-field-concept`（`mem_1CdP4TsjoiugBQweYdcnpv`）。本ドキュメントはそれを cortex 実装へ写像した Living Doc。
> **関連**: [doc 03 MIDI Focus モデル](03-midi-focus-model.md)、`cortex-config`（KDL preset）、`cortex-gpu/shader_types.rs`（`ShaderUniforms`）、`cortex-midi/xtouch.rs`（Main フェーダー）

## 1. コンセプト要約

**sound & field = ライブ主体のフォーマット。** 素材はスタジオで作り込み、現地で部屋に合わせて調整し、本番でその上に**その場で物語を構築する**（自由に歩く）。

- **原理**: ナラティブは素材に内在しない。**素材 × 見方の間に発生する出来事**。同じ field から無数の物語 → *この部屋・この夜*でしか起きない → **録画不能 = ライブ必然**。
- **演者の芸 = 見立て**: 素材を足さず視点をずらして別の物語を現す（落語／茶室／枯山水の系譜）。
- **モデル**: 朗読（物語まで固定）ではなく**即興の語り**。固定＝素材の語彙、即興＝構成・順序・アーク・テンポ・間。
- **密度**: 素材レベルで高く、構成レベルで開く。field は一本道でなく「作り込まれた地形」。良い field の尺度＝**許容する見立て（歩き方）の数**。

## 2. 四層モデル

演奏中のパラメータは、**いつ確定するか**で四つに分かれる。この分類が設計の背骨。

```
  焼く（Studio）      合わせる（Venue）       歩く（Live）
  ─────────────      ─────────────────      ─────────────
  語彙を書く    →    部屋に組版し直す   →    その場でルートを引く
  本番 immutable     リハで一回確定          本番で連続操作
        │                  │                      │
        └──────────────────┴──────────┬───────────┘
                                       │
                              自律（Autonomous）
                              field が音楽に反応して息づく
                              （誰も触らない）
```

## 3. cortex 実体への写像

| 層 | 概念での役割 | cortex の実体 | 状態 |
|----|------------|--------------|------|
| **焼く**（スタジオ） | field を書く＝語彙 | shader source/path、`Scene` 定義（区画・shader_type・param上書き）、`Preset.midi_mappings`（どの CC がどの param を歩くか）、`transition_time`、param デフォルト | ✅ KDL preset（`cortex-config`） |
| **合わせる**（現地リハ） | 部屋に組版し直す | 現状 `master_gain=1.0` ハードコード・`RenderConfig`・`beat_interval` default が**散在** | ⚠️ **家がない → §4 で新設** |
| **歩く**（本番） | その場の物語＝ルート | `midi_cc[8]`（回転速度・mod・色相・glow）、`midi_pitch_bend`/`midi_mod_wheel`、`master_gain`（X-Touch Main フェーダー）、**scene 切替 1–8 ＝どの区画に居るか**、`scene_transition` | ✅ MIDI＋フェーダー＋シーン |
| **自律**（field が息する） | 素材が音楽に反応 | audio 解析（rms/bass/mid/high/beat_*）→ `ShaderUniforms::apply_analysis` で uniform 自動駆動 | ✅ 実装済み |

**「歩く × 自律」の重ね合わせ**が、「濃密だが歩ける地形」の手触りを作る。演者が MIDI/scene で歩き、field は audio で勝手に呼吸する。

## 4. 設計ギャップ: `VenueConfig`（「合わせる」層の新設）

概念上いちばん大事な「現地で部屋に組版し直す」に対応する場所が、今コードに無い。preset（焼く）でも MIDI（歩く）でもない、**リハで一回決める第三の層**を独立させる。

- **位置**: preset の上・MIDI の下（`preset → venue override → live walk` の順で合成）。
- **中身候補**: マスターゲイン基準（PA 適応）、全体輝度/glow スケール（会場照明適応）、基準 BPM（`beat_interval`）、出力解像度（プロジェクタ）。
- **原則**: preset と混ぜない。混ぜると本番で MIDI が地形ごと崩す事故になる（＝「歩く用」と「組版用」の混同）。
- **ライフサイクル**: 起動〜リハで確定 → 本番中 immutable。preset のように保存でき、会場ごとに別ファイル。

## 5. 設計原則（この表から落ちる指針）

1. **タイムラインは焼かない** — `Scene` は再生順を持たず「いつでも呼べる区画」のまま。現状の `PresetManager::select(index)` / キー 1–8 はこの思想に既に合致 ✅。
2. **歩く面は薄く連続に** — `midi_cc` / フェーダー / scene 切替だけが本番で動く。焼く・合わせるの値は本番中 immutable。
3. **合わせる層を分離** — `VenueConfig` を独立させ、preset と混ぜない。
4. **自律層を殺さない** — audio 反応は field の生命。歩く操作はそれを上書きせず、重ねる設計にする。

## 6. 未解決 / 次の一手

- [ ] `VenueConfig` struct の最小定義（§4 の中身候補から）。`cortex-config` に置くか新 crate か。
- [ ] 合成順序 `preset → venue → live` の実装ポイント（`ShaderUniforms` 構築時に一本化）。
- [ ] scene 切替の「見立て」表現力: transition の質（クロスフェード／カット／モーフ）をどこまで焼く／歩くに割るか。
- [ ] X-Touch Main フェーダー（歩く面）は実装中（`feature/xtouch-main-fader`）。他の歩くパラメータ（色相・glow）も同様にモーター/LED フィードバックを持たせるか。
