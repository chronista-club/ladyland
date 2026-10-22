# 13. アプリ内更新

> **Status**: Draft
> **Related**: `mem_1CgGUt6c4wBCNzowECCFsR`、[配布手順](../docs/distribute.md)、Midistage PR #28
> **対象**: `LadylandApp.swift`、`ContentView.swift`、`scripts/build-app.sh`

## 要件

Ladyland メニューから新しい公開版を確認し、利用者が選んだ時点で適用・再起動する。
定期確認は一日一回。演奏中かどうかを idle 時間やウィンドウの状態から推測しない。
起動直後も含めて自動でダイアログを出さず、フッターの「更新あり」で知らせる。
開発用の `swift run` / `swift test` では updater を起動しない。

## 構成

- Sparkle 2.10 の `SPUStandardUpdaterController` を既存の `AppDelegate` が保持する。
  `SUFeedURL` のないバンドルでは作らない。メニューの有効状態は `canCheckForUpdates` に追従する。
- `SPUStandardUserDriverDelegate` の gentle reminders で、すべての定期確認の表示を引き受ける。
  通知を受けたら版を保持し、フッターにボタンを表示。ボタンとメニューは同じ手動確認を呼び、
  ダウンロード・適用の UI は Sparkle に委ねる。ユーザーが確認した時とセッション終了時に通知を消す。
  Sparkle の ObjC UI protocol は actor 未注釈のため `@preconcurrency` で MainActor に橋渡しする。
- `SUEnableAutomaticChecks=true`、`SUScheduledCheckInterval=86400`。
  `SUAllowsAutomaticUpdates=false`、`SUAutomaticallyUpdate=false` で、バックグラウンドでの
  ダウンロード・適用・終了時インストールを許可しない。
- Sparkle による再起動も通常のアプリ終了を通る。既存の `applicationShouldTerminate` による
  MIDI セッションの終了待ちと、`willTerminateNotification` での同期保存を維持する。
  同梱 `fieldd` の扱いは既存の起動処理に従う。外部の `midistaged` を更新する機能は持たない。

## 配布

- main の正式リリースを `releases/latest/download/appcast.xml` で追う。GitHub の Latest に指定する
  リリースには、必ず DMG と appcast の両方を付ける。初回導入前の v0.3.0 には appcast がない。
- Sparkle.framework を `Contents/Frameworks` に symlink を保って入れ、実行ファイルに rpath を追加。
  Sparkle の XPC / Autoupdate / Updater を内側から署名。Downloader の entitlements は維持する。
- `CFBundleVersion` はコミット数だけにし、ハッシュは `LadylandCommit` へ分ける。
  `CFBundleShortVersionString` は v を除いた tag。nightly → main は既存どおり no-ff merge なので、
  正式リリースの build 番号は増加する。
- `--publish` はアプリの公開鍵と Keychain の鍵が一致することを確認する。
  公証・staple 済みの今回の DMG だけから EdDSA 署名付き appcast を生成し、同じ Release に添付する。
  秘密鍵の正本は 1Password（Engineering）、署名時のコピーは login Keychain の account `ladyland`。

## やってはいけない

- Midistage の `SUAutomaticallyUpdate=true` をそのまま移す。
- 定期確認で `immediateFocus=true` を理由にダイアログを許可する。
- 更新のためにアプリを kill し、保存や MIDI 切断を飛ばす。
- 秘密鍵をリポジトリ・ログ・Creo に書く。
- v0.3.0 を上書きし、初回からアプリ内更新できると案内する。

## 検証

- `AppUpdatesTests`: delegate の gentle reminders と、起動直後を含む定期表示の抑止。
- `ApplicationTerminationTests`: 既存の非同期終了待ち。
- `scripts/test-app-bundle.py`: 実バンドルの自動適用禁止・feed/公開鍵・版番号・framework/rpath。
- 配布ビルドで署名・公証・staple・appcast 生成と署名検証。
- GUI の表示と、公開版間のダウンロード → 正常終了・保存 → 入れ替え → 再起動は実機確認が必要。
  初回の Sparkle 入りバージョンだけは手動インストールする。

## Status log

- 2026-10-22: 導入実装。適用・再起動は手動、定期通知はフッターに限定する裁定を記録。
