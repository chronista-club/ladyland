//! ライブ用フォントスケール（mako 裁定 2026-08-01「UI フォントサイズを 15pt で」）。
//!
//! ## 値ではなく「視距離」を名前にする
//!
//! ladyland には**見る距離が 2 つ**ある。サイズを並べても新しい画面を足すときに
//! 迷うが、距離で名前を付けると迷わない。
//!
//! | | 誰が見るか | 距離 | 基準 |
//! |---|---|---|---|
//! | **stage** | 演奏中の自分 — タイル・ノブストリップ・footer・サンプラー | ステージ上、譜面台の向こう（~2m） | **15pt** |
//! | **desk** | 設営中の自分 — 設定ウィンドウ・LPD8/Keystage/ROTO エディタ・Snapshot・Debug | 手元（~50cm） | **12pt** |
//!
//! creo-ui の typography トークンは s=14 / m=16 で 15 を持たない。ladyland は
//! **離れた位置から一瞬で読む**のが要件で、既定の .caption / .caption2
//! （12-11pt）では小さすぎた。トークンから外れる根拠は上記の視距離。
//!
//! ⚠️ **演奏面に `desk` を使わないこと**。2026-08-06 の実測では演奏面に
//! `.font(.caption)`（12pt）が 4 箇所漏れていた。「小さすぎる」は本番の
//! ステージでしか気付けない — 軸に名前が無いと、漏れても誰も気付けない。
//!
//! ⚠️ **固定 pt なので Dynamic Type には追従しない**。用途が「決まった Mac の
//! 決まった画面をステージから読む」ことなので、環境で伸縮しない方が読みの
//! 確度が高い（既存の 15pt 裁定もこの前提）。
//!
//! 数値は monospacedDigit を既定にする — 音量・CC 値が桁で揺れないため。

import SwiftUI

enum LadylandFont {

    // MARK: - stage（演奏面 ~2m）

    /// 基準 15pt — トラック名・ノブのパラメータ名など「読む」テキスト
    static let base: CGFloat = 15

    /// 補助 13pt — 単位・状態・footer の操作ガイド（base より 1 段下）
    static let small: CGFloat = 13

    /// トラック番号 20pt — 数字キー 1-8 との対応を遠目に確認する要素
    static let badge: CGFloat = 20

    /// 本文（トラック名・パラメータ名）
    static let body = Font.system(size: base)

    /// 本文の強調（ページ見出しなど）
    static let bodyBold = Font.system(size: base, weight: .semibold)

    /// 数値（音量・CC 値）— 桁の揺れを止める
    static let number = Font.system(size: base).monospacedDigit()

    /// 補助テキスト
    static let caption = Font.system(size: small)

    /// 補助の数値
    static let captionNumber = Font.system(size: small).monospacedDigit()

    /// トラック番号バッジ
    static let badgeNumber = Font.system(size: badge, weight: .medium).monospacedDigit()

    // MARK: - chip（密なインライン標識）

    /// チップ 9pt — ノブ割当の CC 番号、サンプラーの FX 名など、
    /// **「読む」のではなく「点いているか」を見る**極小の標識。
    ///
    /// ⚠️ stage でも desk でもない第 3 の category。距離ではなく**役割**で
    /// 決まる（読字ではなく点灯の確認）ので、15pt へ上げると隣と重なって
    /// かえって読めなくなる。色と太さで差を付け、**サイズには頼らない**
    static let chipSize: CGFloat = 9

    /// チップ（消灯側）
    static let chip = Font.system(size: chipSize)

    /// チップ（点灯側）— 太さで差を付ける
    static let chipBold = Font.system(size: chipSize, weight: .bold)

    /// チップの見出し（割当パネルのノブ番号など）
    static let chipHeading = Font.system(size: chipSize, weight: .semibold)

    /// INST マトリクスのセル 10pt — chip より 1 段大きい。セルは「点灯確認」
    /// ではなく**パラメータ名を読む**場所で、2x4 化（2026-08-14）でセル幅にも
    /// 余裕ができた（mako 要望「中のフォントサイズ一つあげて」）
    static let matrixCell = Font.system(size: chipSize + 1)

    // MARK: - desk（設定・エディタ ~50cm）

    /// 設定面の基準 13pt — ラベル・選択肢
    static let deskBase: CGFloat = 13

    /// 設定面の補助 12pt — 説明文・注記
    static let deskSmall: CGFloat = 12

    /// 設定面の本文
    static let deskBody = Font.system(size: deskBase)

    /// 設定面の見出し（タブ内の節）
    static let deskHeading = Font.system(size: deskBase, weight: .semibold)

    /// 設定面の説明文 — 「⚠️ …」「切替時に音が一瞬途切れます」等
    static let deskCaption = Font.system(size: deskSmall)

    /// 設定面の数値（CC 番号・ノート番号の一覧）
    static let deskNumber = Font.system(size: deskSmall).monospacedDigit()

    // MARK: - log（等幅の流し読み）

    /// ログ本文 11pt 等幅 — **桁を揃えて縦に流す**のが目的なので等幅。
    /// desk より小さいのは、1 画面に入る行数の方が読みやすさに効くため
    static let log = Font.system(size: 11, design: .monospaced)

    /// ログ本文（compact = 窓を小さくして演奏の邪魔をしない状態）
    static let logCompact = Font.system(size: 10, design: .monospaced)
}
