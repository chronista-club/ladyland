# CI — makomac の self-hosted runner

2026-08-09 導入（mako 裁定: self-hosted / フルマトリクス毎回 / 実 AU テスト込み）。
workflow は `.github/workflows/ci.yml`、検証内容は `scripts/test-matrix.sh` が正典。

## なぜ self-hosted か

- private リポジトリの GitHub ホスト macOS runner は**分数 10 倍課金**（1 run ≈ 100 分換算、無料枠 2000 分/月が 2〜3 回で尽きる）
- この Mac には Xcode / 音声デバイスがあり、認証不要のテスト専用 AU で実エンジンの統合テストを走らせる
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
TOKEN=$(gh api -X POST repos/chronista-club/ladyland/actions/runners/registration-token --jq .token)
./config.sh --url https://github.com/chronista-club/ladyland --token "$TOKEN" --name makomac --unattended
./svc.sh install && ./svc.sh start
```

確認: `gh api repos/chronista-club/ladyland/actions/runners --jq '.runners[] | "\(.name) \(.status)"'` が `makomac online` を返すこと。

撤去: `./svc.sh stop && ./svc.sh uninstall && ./config.sh remove --token <除去トークン>`


## 認証不要の AU と Gadget 互換性テスト

既定の `IntegrationTests` は、テストプロセス内だけに登録する
`TestInstrumentAU` をロードする。インストール・ライセンス認証・外部サンプルは不要。
発音部は LadySynth を再利用し、Level パラメータと fullState、640×360 の
リサイズ対応エディタを加えている。登録に失敗した場合はスキップせず失敗する。
2つの component ID を使って差し替えと Draft の往復も確認する。

これは実際の AUAudioUnit / AVAudioUnit / AVAudioEngine を通すテストだが、
プロセス内 AU のため、AUv3 の別プロセス通信や WebView、ベンダー認証は検証しない。
GUI セッションと使用可能な音声出力は引き続き必要。テストAUはアプリ本体には含めない。

Gadget の元の9シナリオは `GadgetCompatibilityTests` として残し、既定では無効。
Gadget のインストール・認証を確認したうえで、次のコマンドで明示実行する。
指定時に必要なプラグインが無ければ失敗する。

```sh
LADYLAND_TEST_GADGET=1 swift test --package-path ladyland --filter GadgetCompatibilityTests
```

Gadget の認証ダイアログは自動操作で回避しない。認証待ち・ベンダー互換性の失敗と、
認証不要のホスト回帰テストの結果を区別して記録する。
