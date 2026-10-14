# Blender assets

空間（机・棚・照明・カメラ）だけをここで管理する。**機材単体の模型は midistage が正本**
（midistage `docs/design/04-gear-assets.md`、2026-10-14 に移設完了）。
`.blend` と確認用プレビューを Git に保存し、ファイル名には日付・版を付けない。履歴は Git で追う。

## 構成

- `scenes/studio.blend`: 机、照明、カメラと、8 台の機材へのリンク。
- `previews/studio.png`: 配置を開かずに確認する画像。
- `renders/`: 一時レンダー用（Git 管理外）。自動バックアップ `.blend1` 等も管理外。

機材の模型・配置データ・プレビューは midistage の `gear/<id>/` にある
（`gear.json` = 意味の層、`<id>.blend` = 見た目の層）。

現在の機材 ID（midistage の inventory に揃える）: `nanokontrol`, `lpd8`, `roto`, `minilab`,
`fgdp`, `keystage`, `numa`, `xtouch`。旧 ID の `fgdp50` / `ncxse` は使わない
（アプリは旧 ID の配置も読み替える）。

## 編集する場所

**機材の形は midistage の `gear/<id>/<id>.blend` で編集する。** 編集後は midistage で

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python gear/check.py   # 契約の検査
/Applications/Blender.app/Contents/MacOS/Blender --background --python gear/build.py   # 配布物へ
```

を回すと、`~/Library/Application Support/midistage/gear/` に `<id>.usdz` / `<id>.json` /
`<id>.blend` / `manifest.json` が書かれる。アプリはそこを読み、studio はそこの `.blend` を
リンクしている。

空間・照明・カメラは `scenes/studio.blend` で編集する。機材はコレクションインスタンスとして
配置し、リンク先は `//../../../../../Library/Application Support/midistage/gear/<id>.blend`
（このリポジトリが `~/repos/ladyland` にある前提の、ホーム起点の相対パス）。
兄弟の midistage checkout はリンクしない — そちらのブランチ次第で壊れる。
機材をローカル化して複製しない。配布物を更新したら studio を開き直すか、リンクライブラリを
リロードして反映する。

## 書き出し

- `../../ladyland/Gear/desk_layout.json`: studio から書き出した配置・棚の高さ・向き・初期カメラ。
- `../../ladyland/Gear/studio_export.py`: 編集済み studio の環境光、接地の陰影、机の USDZ の書き出し。
  **機材の USDZ / JSON は書き出さない**（midistage の build.py の仕事）。
- `../../ladyland/Gear/look.py`: 旧来の一枚机の生成と、AO 焼き込みの共通処理。

上記の相対パスはこの README のフォルダから辿る。JSON は mm、Blender は m。アプリの `(x, z)` mm は
Blender の `(x / 1000, -z / 1000, 0)` に対応する。

配置の正本は `scenes/studio.blend`。JSON の座標を手で二重管理しない。
機材のインスタンス名は機材 ID、底面が原点、縮尺 1、回転は垂直軸まわりに限る。
棚の天板には `ladyland_surface = True`、仮想部品の置き場の Empty には
`ladyland_tray = "mixer"` または `"trackKnobs"` を付ける。置き場の Z は棚の天面に置く。
カメラはアクティブなカメラを使う（平行投影・透視投影、位置・向き・画角を保持）。
平行投影では撮影範囲の全幅を RealityKit の半幅へ換算し、画面比が変わっても元の範囲全体を収める。
機材の傾き・拡縮、カメラのレンズシフトは誤って平らにせず書き出し時にエラーにする。

レポのルートで次を実行する。書き出しは新しい一時ディレクトリを指定する。

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python ladyland/Gear/studio_export.py -- --output /tmp/ladyland-studio-export
```

書き出しは blend を保存せず、機材の再生成もしない。机・棚を USDZ にし、
机の接地陰影を焼き、Area light とワールドを全周の環境光へ渡す。
出力の `desk_layout.json` を `ladyland/Gear/desk_layout.json` にコピーして差分を確認する。
アプリの停止後、既存の `~/Library/Application Support/ladyland/gear/` をバックアップして
書き出し一式を配置し、新しいアプリで開く。生成物はこの assets フォルダには混在させない。

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

2026-10-07、配置検討 `renders/studio-shelves.blend` を正式な studio に採用。
前面下段 Keystage と左 Numa 台の天面は 740 mm、正面上段は 850 mm。
Numa は左へ 90°、上段前列は FGDP / LPD8 / nanoKONTROL / MiniLab、奥は ROTO / X-TOUCH。
各棚の手前端は機材の手前端に揃えた。変更前の手編集 studio は
`~/.local/share/ladyland/backups/studio-20261007/` に退避済み。

2026-10-14、機材の模型・配置データ・生成器（`gear/<id>.blend`、`Gear/<id>.json`、
`gear_build.py`、`nanokontrol.py`、機材のプレビュー）を midistage へ移し、ここから削除した。
studio のリンクを midistage の配布物へ付け替え、インスタンス名を `fgdp` / `numa` に改めた。
配置（位置・向き・棚の高さ）は変えていない（書き出した desk_layout.json は ID 以外一致）。

## 更新時の確認

1. studio を開き直して、リンク切れ・テクスチャ欠落・機材の重複がないこと。
2. 機材を直したときは midistage 側で `check.py` → `build.py` を回してから studio を開くこと。
3. studio のプレビューを更新し、差分を目視すること。
