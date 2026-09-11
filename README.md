# Ladyland

バンド Bikeboy Experience のライブ用 macOS アプリと、その楽器たちが住むスタジオ。
名前は『Electric Ladyland』へのオマージュ。

- **AU ホスト** — KORG Gadget などの AudioUnit 音源をラックに載せて演奏する
- **機材統合** — ROTO-CONTROL / KORG Keystage / AKAI LPD8 mk2 をひとつの操作面にまとめる
- **Field** — Vision Pro 上に楽器たちを浮かべる 3D フィールド（`field/`、Rust の常駐サーバ `fieldd` + visionOS アプリ）

## 構成

| ディレクトリ | 中身 |
|---|---|
| `ladyland/` | Swift アプリ本体（`Ladyland`）と機材ベンチ（`RigBench`）、SysEx 純粋層（`Lpd8Kit` / `RotoKit` / `KeystageKit`） |
| `field/` | `fieldd`（Rust）と visionOS アプリ |
| `design/` `spec/` | 設計書・仕様書 |
| `docs/` | 機材ごとの実測ノート、CI、配布手順 |
| `src/` `crates/` | cortex — 旧世代の Rust オーディオ・ビジュアルエンジン（保守のみ） |
| `bikeboy-launcher/` `bikeboy-mcp/` `conductor/` | 旧世代のワークスペース管理ツール群 |

## 必要環境

- macOS 14 以降、Apple Silicon
- Xcode 26（Swift 6 ツールチェーン）
- Rust（`fieldd` のビルド）
- 音源として KORG Gadget などの AU プラグイン（無くても起動はする）

## ビルド

`ladyland/Package.swift` は同じ組織の 2 つのパッケージを **隣のディレクトリへの path 依存**で参照する。
先にこのリポジトリと同じ階層へ clone しておく。

```bash
git clone https://github.com/chronista-club/creo-ui.git
git clone https://github.com/chronista-club/club-unison.git
git clone https://github.com/chronista-club/ladyland.git
```

```bash
cd ladyland/ladyland
swift build
swift run Ladyland              # 開発時の起動
swift test                      # テスト
../scripts/build-app.sh --run   # .app として組んで起動（本番はこちら）
```

機材ごとの退避路フラグや実機確認の手順は [CLAUDE.md](CLAUDE.md) に集約してある。

cortex（`src/`, `crates/`）は `.cargo/config.toml` が Homebrew の FFmpeg を前提にしている。
Apple Silicon の macOS 以外では調整が要る。

## ドキュメント

- [design/06 — Ladyland アプリ](design/06-ladyland-app.md)
- [design/07 — Field](design/07-field-architecture.md)
- [docs/roto-control/protocol.md — ROTO-CONTROL SysEx 実装ノート](docs/roto-control/protocol.md)
- [docs/distribute.md — 配布（公証と DMG）](docs/distribute.md)

## ライセンス

[Apache License 2.0](LICENSE)。著作権表記は [NOTICE](NOTICE) を参照。

機材メーカーが配布するマニュアルや MIDI 実装チャートの原文は、第三者著作物のため
このリポジトリには含めていない。`docs/` に残しているのは実測に基づく実装ノートだけ。
