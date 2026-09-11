# CI — makomac の self-hosted runner

2026-08-09 導入（mako 裁定: self-hosted / フルマトリクス毎回 / 実 AU テスト込み）。
workflow は `.github/workflows/ci.yml`、検証内容は `scripts/test-matrix.sh` が正典。

## なぜ self-hosted か

- private リポジトリの GitHub ホスト macOS runner は**分数 10 倍課金**（1 run ≈ 100 分換算、無料枠 2000 分/月が 2〜3 回で尽きる）
- この Mac には Xcode 26.6 / 音声デバイス / KORG プラグインが揃っていて、**実 AU 統合テストまで走る**（クラウドでは skip になる範囲）
- 温キャッシュで 1 run 5〜8 分

## 日常運用

- **何もしなくてよい**。PR（→ nightly）と nightly への push で勝手に回る
- check が **pending のまま** = runner が寝ている（Mac がスリープ / ログアウト / 停止中）。⚠️ required check にしていないので**マージは詰まらない** — 起きたら回る
- 実 AU 統合テストで**音量 0.02 の微音が数秒鳴る**（仕様。mako 承認済み）
- ⚠️ **ライブ当日は止める**: `cd ~/actions-runner && ./svc.sh stop`（再開は `./svc.sh start`）

## 前提（この Mac 固有）

- `/Users/makomac/repos/creo-ui` と `/Users/makomac/repos/club-unison` が存在すること — workflow が workspace の隣へ symlink して `ladyland/Package.swift` のパス依存を解決する（開発レーンの `.vp/lanes/` 踏み台と同じ実体）。⚠️ **Package.swift にパス依存を足したら workflow の symlink 節にも足す**
- runner は LaunchAgent（ユーザーセッション常駐）。**ログイン中だけ動く** — daemon 化すると CoreAudio / AU カタログに触れなくなるので変えないこと

## runner の登録（再セットアップが要るとき）

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
# 最新の actions-runner-osx-arm64 を https://github.com/actions/runner/releases から取得して tar xzf
TOKEN=$(gh api -X POST repos/chronista-club/bikeboy-ladyland/actions/runners/registration-token --jq .token)
./config.sh --url https://github.com/chronista-club/bikeboy-ladyland --token "$TOKEN" --name makomac --unattended
./svc.sh install && ./svc.sh start
```

確認: `gh api repos/chronista-club/bikeboy-ladyland/actions/runners --jq '.runners[] | "\(.name) \(.status)"'` が `makomac online` を返すこと。

撤去: `./svc.sh stop && ./svc.sh uninstall && ./config.sh remove --token <除去トークン>`
