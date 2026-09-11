# OSS 公開チェックリスト（保留中 — 時間が取れたら再開）

> 2026-08-10 の棚卸し（全履歴 374 コミット監査）に基づく。
> 状態の正典: Creo `mem_1CdtL2fmkZak1o2HgsJSsP`。
> ⭐ **秘密情報ゼロ・GPL 依存ゼロ・個人情報なし**は監査済み — 怖いものは残っていない。

## 裁定済み（mako 2026-08-10）

| 判断 | 結論 |
|---|---|
| 公開の単位 | **このリポ丸ごと公開**（ladyland 切り出しではなく） |
| ライセンス | **Apache-2.0** |

## 済んでいる作業

- [x] メーカー原文（KORG 実装チャート・各社マニュアル PDF 約 50MB）を私有
      [`ladyland-gear-docs`](https://github.com/chronista-club/ladyland-gear-docs) へ退避（PR #99）。
      実測知見の README / protocol.md は本体に残し、行番号引用の注記済み
- [x] 旧パス symlink `.mcp.json` の削除（旧ユーザー名の露出）
- [x] 誤配置の無関係 PDF 削除

## ⚠️ 未裁定 — 大きいのは 1 つだけ

### CreoUI のパス依存（公開ブロッカー）

`ladyland/Package.swift` が `../../creo-ui/packages/swift` を参照 — 外部ではビルド不能。

| 選択肢 | 含意 |
|---|---|
| **A. creo-ui も OSS 公開** | Creo エコシステムのデザイン言語ごと世に出る。⚠️ creo-ui 側の棚卸しがもう 1 周要る |
| B. 使用分だけ vendor（同梱コピー） | すぐできるが以後二重管理 |
| C. 依存を剥がす | 見た目のアイデンティティを失う。作業量大 |

## 小さい判断（再開時に 5 分ずつ）

- [ ] `assets/Narrow Down.wav`（LFS 635MB、バンド音源）— 公開する？
      ⚠️ 抜くと `cortex-audio` のテスト 1 本が落ちる + LFS 帯域課金の話
- [ ] Apple Team ID `3EQKG4B352` + 社名の doc 記載（`docs/distribute.md` / `scripts/build-app.sh`）—
      署名バイナリに元々入る公開情報だが、doc に残すか
- [ ] `RotoProtocol.swift` の 83 色パレット — デコンパイル由来の出自コメントの濃さ
      （相互運用目的の RE として防御可能）
- [ ] 追跡中の `.claude/`（32 ファイル、個人 skills 参照あり）— 公開版から落とす？
- [ ] Creo memory ID 14 個・vantage-point / club-unison への相対リンク —
      外部では無意味（無害）。消すかは可読性の問題

## 再開時の作業手順（順番どおり）

1. CreoUI の裁定（上の三択）
2. `git filter-repo` で履歴から PDF 群 + `.mcp.json` を抜く
   （pack 56.5MB の 9 割が PDF blob。秘密は無いので author 書換え不要。
   ⚠️ force-push になるので clone し直しの連絡をバンドへ）
3. `LICENSE`（Apache-2.0）+ `NOTICE` を追加
4. 外部向け `README.md` 新設（今はルートに無い。ビルド手順は CLAUDE.md にのみ）
5. CI（GitHub Actions — swift test / cargo test。今は workflows ゼロ）
6. `.cargo/config.toml` の `/opt/homebrew` 決め打ちを直す（Intel/Linux で壊れる）
7. 小さい判断の消化 → 公開スイッチ
