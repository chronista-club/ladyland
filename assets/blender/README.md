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
- `../../ladyland/Gear/desk_layout.json`: アプリと Blender が共有する配置・机寸法・初期カメラ。
- `../../ladyland/Gear/look.py`: 環境光、接地の陰影、USDZ の生成。

上記の相対パスはこの README のフォルダから辿る。実際のレポ内パスは
`ladyland/Gear/`。JSON は mm、Blender は m。アプリの `(x, z)` mm は Blender の
`(x / 1000, -z / 1000, 0)` に対応する。

**再生成は機材コレクションを作り直すため、手で修正したメッシュ・材質・部品は失われる。**
生成元を変更する場合は、別の一時シーンで生成して比較し、必要な修正を反映してから
該当の `gear/<id>.blend` を更新する。既存ファイルへ一括上書きしない。
手修正を加えたら、その内容と再生成時の戻し方をこの README に追記する。

`.blend` の編集だけでは JSON やアプリの配置は更新されない。配置変更は共有 JSON にも
反映し、Blender では機材インスタンスを同じ位置へ移す。アプリ向けの USDZ/JSON/照明は
`~/Library/Application Support/ladyland/gear/` へ書き出す生成物で、ここには混在させない。

## 現在の状態

2026-10-06、既存の `~/Documents/Blender/Ladyland-XTouch.blend` から 8 台を分離した。
元の Documents 内ファイルは移行元として保持し、今後の編集先はこのフォルダとする。
現在は生成した模型で、移行時に形の手修正はしていない。

X-TOUCH は標準モデル。寸法・参照写真は `ladyland/Gear/xtouch.json` の `source` に記載。
筐体の傾斜と背面端子は簡略化している。模型の追加は MCU/HUI 実機制御の実装を意味しない。
机の接地陰影は 1K / 16 samples。プレビューの画質は実機表示の検証とは区別する。

## 更新時の確認

1. 機材ファイルが単独で開け、原点・向き・実寸を保持していること。
2. studio を開き直して、リンク切れ・テクスチャ欠落・機材の重複がないこと。
3. 相対リンクのまま別のディレクトリへコピーして開けること。
4. 該当する機材と studio のプレビューを更新し、差分を目視すること。
