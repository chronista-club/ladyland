# Blender assets

機材単体と空間を分けて管理する。`.blend` と確認用プレビューを Git に保存し、
ファイル名には日付・版・追加した機材名を付けない。履歴は Git で追う。

## 構成

- `gear/<id>.blend`: 実寸の機材単体。各ファイルを直接開ける確認用シーン付き。
- `scenes/studio.blend`: 机、照明、カメラと、8 台の機材への相対リンク。
- `previews/<id>.png`, `previews/studio.png`: 形と配置を開かずに確認する画像。
- `renders/`: 一時レンダー用（Git 管理外）。自動バックアップ `.blend1` 等も管理外。

現在の機材 ID: `nanokontrol`, `lpd8`, `roto`, `minilab`, `fgdp50`, `keystage`,
`ncxse`, `xtouch`。

## 編集する場所

機材の形は `gear/<id>.blend` で編集する。機材のコレクションだけが studio から
リンクされ、確認用カメラ・ライトはリンクされない。ルートオブジェクト名は機材 ID。
原点は機材の底面中央、単位はメートル、Blender の Z が上、−Y が手前。
ルートの位置は `(0, 0, 0)`、スケールは 1 を保つ。

空間・照明・カメラは `scenes/studio.blend` で編集する。機材はコレクション
インスタンスとして配置する。機材ファイルを保存したら studio を再度開くか、
リンクライブラリをリロードして反映する。機材をローカル化して複製しない。

依存するテクスチャは `.blend` にパックし、機材ライブラリへのリンクは
`//../gear/<id>.blend` にする。フォルダ全体を移しても開ける構成を維持する。

## 生成元との関係

- `../../ladyland/Gear/<id>.json` と `gear_build.py`: nanoKONTROL2 以外の機材の生成元。
- `../../ladyland/Gear/nanokontrol.py`: nanoKONTROL2 の生成元。
- `../../ladyland/Gear/desk_layout.json`: studio から書き出した配置・棚の高さ・向き・初期カメラ。
- `../../ladyland/Gear/studio_export.py`: 編集済み studio の環境光、接地の陰影、USDZ の書き出し。
- `../../ladyland/Gear/look.py`: 旧来の一枚机の生成と、AO 焼き込みの共通処理。

上記の相対パスはこの README のフォルダから辿る。実際のレポ内パスは
`ladyland/Gear/`。JSON は mm、Blender は m。アプリの `(x, z)` mm は Blender の
`(x / 1000, -z / 1000, 0)` に対応する。

**再生成は機材コレクションを作り直すため、手で修正したメッシュ・材質・部品は失われる。**
生成元を変更する場合は、別の一時シーンで生成して比較し、必要な修正を反映してから
該当の `gear/<id>.blend` を更新する。既存ファイルへ一括上書きしない。
手修正を加えたら、その内容と再生成時の戻し方をこの README に追記する。

配置の正本は `scenes/studio.blend`。JSON の座標を手で二重管理しない。
機材のインスタンス名は機材 ID、底面が原点、縮尺 1、回転は垂直軸まわりに限る。
棚の天板には `ladyland_surface = True`、仮想部品の置き場の Empty には
`ladyland_tray = "mixer"` または `"trackKnobs"` を付ける。置き場の Z は棚の天面に置く。
カメラはアクティブなカメラを使う（平行投影・透視投影、位置・向き・画角を保持）。
機材の傾き・拡縮、カメラのレンズシフトは誤って平らにせず書き出し時にエラーにする。

レポのルートで次を実行する。書き出しは新しい一時ディレクトリを指定する。

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python ladyland/Gear/studio_export.py -- --output /tmp/ladyland-studio-export
```

書き出しは blend を保存せず、機材の再生成もしない。家具と各機材を別々の USDZ にし、
机の接地陰影を焼き、Area light とワールドを全周の環境光へ渡す。
出力の `desk_layout.json` を `ladyland/Gear/desk_layout.json` にコピーして差分を確認する。
アプリの停止後、既存の `~/Library/Application Support/ladyland/gear/` をバックアップして
書き出し一式を配置し、新しいアプリで開く。高さ・向きに未対応の旧アプリへ先に配置しない。
生成物はこの assets フォルダには混在させない。

書き出しの単体検証:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python ladyland/Gear/test_studio_export.py
```

書き出した実資産を RealityKit で読み込み、棚の高さ・回転・操作子を検証する:

```sh
LADYLAND_STUDIO_ASSETS=/tmp/ladyland-studio-export \
  swift test --package-path ladyland --filter StudioLayoutTests
```

## 現在の状態

2026-10-06、既存の `~/Documents/Blender/Ladyland-XTouch.blend` から 8 台を分離した。
元の Documents 内ファイルは移行元として保持し、今後の編集先はこのフォルダとする。
現在は生成した模型で、移行時に形の手修正はしていない。

X-TOUCH は標準モデル。寸法・参照写真は `ladyland/Gear/xtouch.json` の `source` に記載。
筐体の傾斜と背面端子は簡略化している。模型の追加は MCU/HUI 実機制御の実装を意味しない。
机の接地陰影は 1K / 16 samples。プレビューの画質は実機表示の検証とは区別する。

2026-10-07、前日の配置検討 `renders/studio-shelves.blend` を正式な studio に採用。
前面下段 Keystage と左 Numa 台の天面は 740 mm、正面上段は 850 mm。
Numa は左へ 90°、上段前列は FGDP / LPD8 / nanoKONTROL / MiniLab、奥は ROTO / X-TOUCH。
各棚の手前端は機材の手前端に揃えた。変更前の手編集 studio は
`~/.local/share/ladyland/backups/studio-20261007/` に退避済み。

## 更新時の確認

1. 機材ファイルが単独で開け、原点・向き・実寸を保持していること。
2. studio を開き直して、リンク切れ・テクスチャ欠落・機材の重複がないこと。
3. 相対リンクのまま別のディレクトリへコピーして開けること。
4. 該当する機材と studio のプレビューを更新し、差分を目視すること。
