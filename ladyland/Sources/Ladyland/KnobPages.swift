//! ⭐ **ページの正典** — 楽器 1 台につき 64 席 × 8 ページ、**ページ = CC ÷ 8**。
//!
//! `KnobAssignView` の 3 層語彙（surface / assignment / mapping）で言うと
//! **assignment 層**。どのサーフェス — Keystage の物理ノブ、ROTO の SMART 面、
//! 画面の割当一覧、**これから増える 2nd キーボード** — も、この席割りを
//! 映すだけで、**ページの定義そのものはここ以外に存在しない**。
//!
//! ## 経緯
//!
//! - mako 裁定 2026-08-09「他の用途で使う時はあると思うけど、**Page は 8 つで**」
//!   — 席 = CC0-63 の 64 個で打ち止め（CC65+ は将来の別用途に温存）
//! - mako 裁定 2026-08-10「**A だね。近いうち、2nd キーボードが増える。
//!   別々の二つの音源同時に弾きたい**」— Keystage の名前空間（`KeystageKnobs`）
//!   から独立。新しいサーフェスはこのファイルだけ見ればよい
//! - ⚠️ **64 という数字の由来は Keystage の物理**（CC64 = Damper の壁。
//!   経緯の全文は `KnobPages.swift` 冒頭）だが、いまは**アプリの決め** —
//!   機材が変わっても動かさない
//!
//! ## ⚠️ 9 ページ目を足すな
//!
//! CC64 から先はペダル帯（64 Sustain / 65 Portamento / 66 Sostenuto /
//! 67 Soft / 68 Legato / 69 Hold2）。席にすると**回した瞬間に音が張り付く**。
//! `fillsExactlyUpToPedalRange` が番人

import Foundation

enum KnobPages {
    /// 1 ページの席数（= 物理ノブ 8 本。Keystage も ROTO も 8 本で揃っている）
    static let perPage = 8

    /// ページ数（mako 裁定 2026-08-09「Page は 8 つで」）
    static let pageCount = 8

    /// 席の総数（64。⚠️ CC64 = ペダル帯の壁 — ファイル冒頭参照）
    static var seatCount: Int { perPage * pageCount }

    /// 全席（CC0-63）
    static let all: [Int] = Array(0..<(perPage * pageCount))

    /// ページ（0 始まり）。⚠️ **席の外は nil** — ペダル帯（CC64〜）や
    /// 演奏席（Mod 116 / Exp 115）はページを名乗らない
    static func page(forCC cc: Int) -> Int? {
        guard all.contains(cc) else { return nil }
        return cc / perPage
    }

    /// ページ内の位置（0-7）
    static func index(forCC cc: Int) -> Int? {
        guard all.contains(cc) else { return nil }
        return cc % perPage
    }

    /// ページ p の 8 席
    static func page(_ page: Int) -> [Int] {
        guard page >= 0, page < pageCount else { return [] }
        return Array((page * perPage)..<((page + 1) * perPage))
    }

    /// 全ページ（`AssignList` が並べる単位）
    static var pages: [[Int]] { (0..<pageCount).map(page) }

    /// 表示名（`P1-1` … `P8-8`）
    static func label(forCC cc: Int) -> String? {
        guard let page = page(forCC: cc), let index = index(forCC: cc) else { return nil }
        return "P\(page + 1)-\(index + 1)"
    }
}
