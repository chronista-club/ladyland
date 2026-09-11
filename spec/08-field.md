# spec/08 — Field（常駐する場、Vision Pro から降り立つ）

**ステータス**: v0 計画（2026-08-14 起工）
**正典**: ビジョン原典 `mem_1CdXiVM8pgKHpQRD9JbDGG`（2026-07-23、Taicoclub/Madlib 原風景）
**設計書**: [design/07-field-architecture.md](../design/07-field-architecture.md)

## What — Field とは

**Field は Ladyland System 上に常駐する「場」**。楽器（electric ladies）が
役割を持って住み、音を出しながら場を満たす。演奏者は Vision Pro を被って
**field に降り立つ**。

- **root の名は Field**（mako 裁定 2026-08-14）。20 年前の原風景を mako 自身が
  「フィールドを満たしていく」と語った、その言葉をそのまま root に立てる。
  sound field（音場）= 「フィールド = 部屋（媒質）、エンティティ = 楽器」という
  原典の設計原則にも一直線
- 候補だった **Axis は温存**（Hendrix 3 部作で 2nd だけ未襲名 —
  Are You Experienced = Bikeboy Experience / Electric Ladyland = Ladyland。
  Axis: Bold as Love は次の大物のために取っておく）。
  **Frame は却下**（creo-ui packages/frame・SwiftUI .frame・audio frame と衝突）

## Why

- 20 年前の原風景（浮かぶ球体が役割を持って音を出し、場を満たす）が
  bikeboy プロジェクト全体の起点。8/8 ライブ（音側）が成立した今、
  「field は 8/8 後の本丸」の時が来た
- 原典の未決だった**カメラの主体**に回答が出た: **カメラ = 演奏者本人**。
  Vision Pro で自分が降り立つ。原則 1「主語は演奏中の自分」と一直線

## v0 — 降り立つと、目の前に楽器が一つ

mako 裁定（2026-08-14 ヒアリング）: 「**目の前楽器が一つ見えてて欲しい**」。

- 降り立つと、**選択中の楽器（lady）が目の前に浮いている**
- トラックカラーで光り、名前が読め、**出音のレベルで脈打つ**
  （ladyland の per-slot peak ~23Hz が既にある — 新規の解析は不要）
- ladyland（または ROTO の RK）で選択を変えると、目の前の lady が入れ替わる
- 音は Mac（L6max）から出続ける。Vision Pro は**場に立つ目**

これが「field に居る」ことの最小の証明。64 体で場を満たすのは v1 以降。

## スコープの階段

| 版 | 内容 | 原典との対応 |
|---|---|---|
| **v0** | 降り立つ + 目の前に選択中の lady 一体（色・名前・レベル脈動） | 場に立つ、反同期の種（音→形ではなく「lady が鳴っている」） |
| v1 | 音源単位の解析（FFT）を lady に配線、複数体が場を満たす | 原典「ミキシングコンソールの設計問題」 |
| v2 | Behavior Engine の自律（無音でも生きてる、state の時定数） | 入力階層: 自律 > 意図 > 影響 |
| v3 | 触る — 視線 + ピンチで選択（ROTO RK の空間版）、場のモーフ | 全パラメータは演奏可能 |

## 決定事項（2026-08-14 ヒアリング）

- Vision Pro **実機あり** — 最初から実機検証で進める
- 置き場所は **repo 直下 `field/`**
- **Field サーバは Rust**（mako 指定）。**1 つの tokio タスクが 1 field の
  ライフサイクルをまかなう**。通信は Unison Protocol（club-unison、QUIC）—
  Swift クライアントは visionOS 対応済み
- ladyland と Vision Pro は**同格のクライアント** — ladyland は楽器の
  アイデンティティと音の状態を field へ流し、Vision Pro は field を視る
