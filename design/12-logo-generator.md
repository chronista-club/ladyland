# 12. Billboard Logo Generator

> **Status**: Draft（形の検討中）
> **Related**: design 06 §8、Creo `mem_1Cft9Di4PSzVCwhu9BCbA4`
> **対象**: `scripts/brand/`, `assets/brand/source.svg`

## 目的と裁定

「この現状を出発点としよう」。既存 AppIcon の 4 列 × 3 行、一灯だけが
ミント色で点灯する billboard を、対話しながら調整する。
現行の CoreGraphics 版の配置・色・比率から開始する。SVG のぼかしと
CoreGraphics の shadow は描画器が異なるため、ピクセル一致を目標にしない。

## 正本と構成

- 正本は `assets/brand/source.svg`。metadata の version 1 に全編集値を保存する。
- `logo-model.mjs` はパラメータ検証、4×3 配置、SVG の再生成を担う。
- 2D は SVG、3D は同じ配置から Three.js の角丸押し出し面を構成する。
  厚み・マットさ・光は 3D、SVG の通常表示は正面図。発光は 2D ではぼかし、
  3D では emissive material として表現する。カメラは作業用で保存対象外。
- `studio.mjs` は調整、16/32/64px の小サイズ確認、SVG import/export、PNG 2048 出力。
  画面下の文字はプレビュー用で、画像には含めない。
- `studio-server.mjs` は loopback のみで待ち受け、正本の SHA-256 revision を
  比べて保存競合を 409 で止める。保存は同一サーバー内で直列化し、rename で置換。
- `build-studio.mjs` は依存込みの配布物を `output/brand/logo-generator/` に生成。
  単独版では同梱 `source.svg` が保存先。生成物は Git 管理外。

## 保存と再開

「保存」で正本を更新する。ブラウザの下書きは読み込んだ revision が一致する
場合のみ復元する。外部更新があるときは SVG を書き出して編集を退避する。
同じ source.svg を複数サーバーから同時に編集する運用は対象外。
単独版の編集を元リポジトリへ戻すには、編集用SVGを読み込んで保存する。

## やってはいけない

- SVG import の生マークアップを DOM に挿入しない。metadata を検証して描画を再生成する。
- スライダーの step で保存値を丸めない。盤面の角丸は既存の 0.2246 を保つ。
- AppIcon は SVG metadata から CoreGraphics で正面図を生成する。3D のカメラ・厚み・照明を Dock に焼き込まない。
- nightly への merge は別の承認。アプリ差し替えはユーザー指示時のみ。

## 検証

`node --test scripts/brand/*.test.mjs` で配置・SVG 往復・不正値・競合保存を検証する。
ブラウザで 2D/3D、点灯変更、保存と再読み込み、PNG を確認する。

## Status log

- 2026-10-10: 初版。現行 billboard を起点に SVG 正本と単独 Generator を追加。

- 2026-10-10: ユーザー「このアイコンでビルドしたものでswapしよう」。保存済み SVG を AppIcon 生成器へ接続。sRGB 色・点灯位置・透過余白・10サイズを統合テストで検証する。
