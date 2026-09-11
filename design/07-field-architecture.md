# design/07 — Field アーキテクチャ（fieldd + 2 クライアント）

**仕様**: [spec/08-field.md](../spec/08-field.md)
**ステータス**: v0 設計（2026-08-14）

## 1. 全体像

```
field/ (repo 直下)
├── fieldd (Rust)  ―― 常駐 Field サーバ
│     ├─ tokio task × N — 1 タスクが 1 field のライフサイクルを所有
│     │    （生成 → 常駐シミュレーション → 終了。field state の SSOT）
│     └─ Unison server (QUIC) — schema は field/schemas/field.kdl
│
│           ▲ QUIC (Unison Protocol)
│           │
├── ladyland (Mac, Swift) ―― クライアント①「楽器の供給者」
│     UnisonClient で接続し、64 スロットのアイデンティティ
│     （名前 / トラックカラー / 選択）と音の状態（per-slot peak）を流す
│
└── vision/ (visionOS, Swift) ―― クライアント②「降り立つ目」
      UnisonClient + RealityKit ImmersiveSpace。
      field state を受けて描画（v0 は選択中の lady 一体）
```

**設計の要**: ladyland と Vision Pro は**同格のクライアント**。field state の
SSOT は fieldd（Rust）に居る。ladyland が落ちても field は生きている
（ladies が眠るだけ）。cortex（Rust）の解析資産を将来 field 側で復活させる
道もこの配置なら開く（「後で復活させれば良い」— 2026-07-30 裁定）。

## 2. fieldd（Rust、mako 指定 2026-08-14）

- **1 tokio task = 1 field のライフサイクル**。task が field の state
  （エンティティ集合 + 場の物性）を所有し、シミュレーションを tick で回す。
  マルチ field（スタジオに複数の部屋）は task を増やすだけ
- 通信は **club-unison**（`club-unison = "1.8"`）。server は Rust が本家
  （Package.swift 冒頭「polyglot client base、server stays Rust」）
- クライアント → field: request（join / スロット状態の更新）
- field → クライアント: **状態ストリーム**。v0 は event で開始し、
  tick レートを上げる段で datagram channel（club-unison design/datagram-channel.md）
  へ移行を検討（順序不問・最新優先の値ストリーム向き）

## 3. スキーマ（field/schemas/field.kdl — Unison protocol dialect）

v0 の骨子（実装時に確定）:

```kdl
protocol "field" version="0.1.0" {
    namespace "ladyland.field"

    channel "presence" from="client" lifetime="persistent" {
        // 降り立つ / 楽器を供給する — role で同格クライアントを見分ける
        request "Join" {
            field "role" type="string" required=#true   // "instruments" | "visitor"
            returns "FieldSnapshot" {
                field "entities" type="json" required=#true
            }
        }
        // ladyland → field: スロットの姿（名前・色・選択・レベル）
        request "UpdateEntities" {
            field "entities" type="json" required=#true
            returns "Ack" {}
        }
        // field → 全クライアント: 場の状態（v0 は選択中エンティティ + レベル）
        event "FieldTick" {
            field "entities" type="json" required=#true
        }
    }
}
```

（`json` 型で始めて、形が固まったら field を型で書き下ろす —
lpd8-mk2-unison.kdl / page-defaults.schema.kdl と同じ「まず動かす」流儀）

## 4. v0 実装計画

1. **field/ の起工**: Cargo crate `fieldd` + `schemas/field.kdl`。
   tokio task 1 本で field を 1 つ常駐、Join / UpdateEntities / FieldTick
2. **ladyland に FieldLink**: UnisonClient で fieldd へ接続、
   選択・名前・色・peak を送る（既存 @Published からの写像。
   接続断で黙って再接続 — 機材と同じ扱い）
3. **vision/ の起工**: visionOS アプリ（ImmersiveSpace）。
   Join(role: visitor) → FieldTick を受けて、選択中の lady 一体を
   目の前に描画（球体 + トラックカラー + 名前 + レベルで脈動）
4. **実機で降りる**（mako 実機あり）— 「目の前に楽器が一つ」の検証

## 5. 未決（v0 で決めない）

- lady の造形（v0 は球体で良い — 原風景も球体。造形は v1 以降の楽しみ）
- 場の物性（粘性・乱流 — Behavior Engine の v2 領域）
- fieldd の常駐形態（v0 は手動起動。FleetFlow 管理は形が見えてから）
- Vision Pro からの入力（v3。v0 は見るだけ）
