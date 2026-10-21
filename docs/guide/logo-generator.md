# Ladyland Logo Generator

ロゴを見ながら形と色を調整する。初期値は現行 AppIcon の billboard。

## 起動

Node.js 22 以降と Bun を使用する。リポジトリのルートから:

```sh
bun install --cwd scripts/brand
node scripts/brand/serve-studio.mjs
```

http://127.0.0.1:12095/ を開く。VP Board にも同じ URL を表示できる。
ポートを変える場合は `LADYLAND_LOGO_PORT=12096 node scripts/brand/serve-studio.mjs`。

## 調整

- 2D は正面、3D は厚み・質感・照明を見る。3D はドラッグで回転、スクロールで拡大。
- 間隔・丸み・余白・厚み・色を調整し、12 個のボタンで点灯位置を選ぶ。
- 「保存」で `assets/brand/source.svg` を更新する。「保存値に戻す」は最後の保存値へ戻す。
- 「編集用SVG」でバックアップし、「SVGを読み込む」で再開できる。
- 「PNG 2048px」は現在の 2D/3D 表示を書き出す。「透過PNG」をオンにすると外背景が透明になる。
  盤面は残る。PNG はダウンロードされ、`output/brand/logo-generator/exports/` にも保存される。
- 画面下の文字はプレビュー用。PNG/SVG はシンボルのみ。

別の場所で正本が更新された場合、上書きせず警告する。編集用SVGを退避してページを開き直す。
下書きは同じブラウザで復元できるが、確実に残すには「保存」を使う。

## 単独版

```sh
node scripts/brand/build-studio.mjs
```

`output/brand/logo-generator/` をフォルダごとコピーし、そこで `node start.mjs` を実行する。
Node.js 以外のインストールは不要。保存先は同梱 `source.svg`。
再ビルドすると同梱 SVG はリポジトリの正本に置き換わるので、編集した配布フォルダへ
再ビルドで上書きしない。`index.html` の直接起動は未検証。通常はサーバーで開く。

## 検証

```sh
node --test scripts/brand/*.test.mjs
```

Generator の保存だけではインストール済みアプリは変更しない。
`scripts/build-app.sh` の次回ビルドでは、保存 SVG の正面図が AppIcon に反映される。

AppIcon の検証: `swift scripts/brand/test-appicon.swift`。
