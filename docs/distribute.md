# Ladyland を他の Mac へ配る

> 対象: **Apple Silicon (arm64) / macOS 15 以降**（mako 裁定 2026-08-02 で Intel は対象外。2026-10-04 に 3D の机のため 14 → 15）

## 配る側の手順

### 初回だけ: 公証の資格情報を登録

```bash
xcrun notarytool store-credentials "ladyland" \
    --apple-id <Apple ID> \
    --team-id 3EQKG4B352 \
    --password <アプリ用パスワード>
```

**アプリ用パスワード**は account.apple.com → サインインとセキュリティ → アプリ用パスワード
で発行する（Apple ID 本体のパスワードではない）。証明書は
`Developer ID Application: Anycreative Inc. (3EQKG4B352)` を使う — 既に手元にある。

### 毎回: 配布物を作る

```bash
scripts/build-app.sh --dist
# → dist/Ladyland-v0.1.0.dmg

scripts/build-app.sh --publish
# → 同じことをして、その tag の GitHub Release に DMG と appcast.xml を添付する
#    （Release が無ければ作る。HEAD が tag の上・作業ツリーが clean・gh 認証済み、が前提）
```

リリースの流れは `release` スキル（nightly → main、tag、GitHub Release）のあとに
`git checkout main && scripts/build-app.sh --publish`。受け取る側は Release ページの
`Ladyland-vX.Y.Z.dmg` を落として /Applications へ入れるだけ。

中でやっていること:

1. release ビルド（arm64）
2. `.app` を組む（Info.plist + AppIcon）
3. **Developer ID 署名 + Hardened Runtime**
4. **公証へ提出して結果を待つ**（数分）
5. **staple** — 結果をアプリ本体に貼る。相手がオフラインでも検証が通る
6. **DMG** — 「Applications へドラッグ」の見慣れた形にする
7. **DMG も署名 → 公証 → staple**（中の .app だけだと Gatekeeper の `-t install` 検証で蹴られる）
8. `--publish` なら **EdDSA 署名付き appcast.xml を生成し、DMG と一緒に添付**

### アプリ内更新（Sparkle 2）

Ladyland メニューの「アップデートを確認…」から公開版を確認できる。
一日一回の定期確認で更新が見つかったときは、フッターに「更新あり」と表示する。
勝手にダイアログを開いたり、ダウンロード・適用・再起動したりはしない。
演奏が終わってから更新を開き、Sparkle の画面で適用を選ぶ。

**v0.3.0 には updater がないため、Sparkle 入りの最初の版だけ手動インストールが必要。**
その次の版からアプリ内更新を使える。配布側は Latest の Release に DMG と `appcast.xml` を
揃えること。`--publish` の代わりに DMG だけを手で添付すると、更新確認が失敗する。

署名鍵の正本は 1Password の **Engineering / ladyland — Sparkle EdDSA signing key** の password。
この Mac には login Keychain の account `ladyland` として取り込み済み。
別のビルド Mac では `swift package resolve`（`ladyland/` 内）で Sparkle を取得した後、
1Password から秘密鍵を権限 600 の一時ファイルへ取り出し、次で取り込む。

```bash
ladyland/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account ladyland -f /path/to/protected-key-file
ladyland/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account ladyland -p
```

取り込み後は一時ファイルを削除する。`-p` が表示する公開鍵と `scripts/build-app.sh` の
`SPARKLE_PUBLIC_KEY` が一致することを確認する。鍵を勝手に再生成しない。
コードには公開鍵だけを置き、秘密鍵をログや共有資料へ載せない。

ビルドした `.app` は起動せずに検査できる（CI でも実行する）。

```bash
scripts/build-app.sh
python3 scripts/test-app-bundle.py
```

## なぜ公証が要るのか

Developer ID で署名しただけでは足りない。ダウンロードや AirDrop で受け取った
ファイルには **quarantine 属性**が付き、Gatekeeper がそれを見て
「開発元を確認できません」で止める。公証は Apple にバイナリを検査させて
「悪意あるものは入っていない」という判定を得る手続きで、staple までやると
その判定がアプリに埋め込まれる。

自分の Mac でビルドして自分で使うだけなら quarantine が付かないので、
署名だけで足りる（`--install` はそれ）。

## 受け取る側へ伝えること

**入れ方**: DMG を開いて Ladyland を Applications へドラッグするだけ。
警告は出ない（公証済みのため）。

**⚠️ 楽器は同梱されていない**: ladyland は **AU プラグインのホスト**であって、
音源そのものは持っていない。相手の Mac に AU 音源（KORG Gadget 等）が
入っていなければ、ラックは空のまま並ぶ。各タイルのメニューから
その Mac にインストール済みの AU を選んでもらう形になる。

**必要な機材**（無くても起動はする）:

| 機材 | 無いとどうなるか |
|---|---|
| KORG Keystage | 鍵盤演奏とノブ操作ができない（GUI とキーボードだけで一応触れる） |
| AKAI LPD8 mk2 | パッド演奏と LED フィードバックが無い |
| AU 音源 | ラックが空のまま（一番効く前提） |

**データの置き場所**（アンインストールしたいとき）:

```
~/Library/Application Support/ladyland/
    ladyland.sqlite   ラック構成と音色
    window.json       ウィンドウ位置・表示モード
    thumbnails/       プラグインの顔
```

## バージョン

`CFBundleVersion` は git のコミット数（Sparkle の比較用）。短縮ハッシュは `LadylandCommit`。
`CFBundleShortVersionString` は直近の git タグから `v` を除いた版（無ければ `0.1.0`）。
配布のたびにタグを切ると、相手に「どれを渡したか」が伝わる。
