//! **いま実機がどうなっているか**の読み取り専用スナップショット
//! （mako 要望 2026-08-06「ROTO の状態と一致してる shadow データを表示したい」）。
//!
//! `RotoShadow` は「最後に何を送ったか」の帳簿 = **ladyland が信じている実機の姿**。
//! それをそのまま画面へ出す。
//!
//! ## ⚠️ これは診断器
//!
//! 飾りではなく、**そのまま切り分けに使える**ことが要件（mako が「ノブと値が
//! 連動していない」を追っている最中）:
//!
//! | 症状 | 読み方 |
//! |---|---|
//! | ノブを回して **`motorRaw` が動かない** | 入力が届いていない（受信段より手前） |
//! | **動くのに音が変わらない** | 適用側（`apply()` のガード） |
//!
//! ⚠️ **`roto: [受信]` のログは値ストリームを落としている**
//! （`isKnobStream` で除外。1 回転 100 行を避けるため）。**その判断は正しい** —
//! だから影の表示で見えるようにするのがここの趣旨。
//!
//! ## ⚠️ 読むだけ
//!
//! 影は**差分抑止の根拠**なので、表示のために触ると送信が壊れる。
//! この型は値のコピーしか持たず、`RotoService` 側も `get` しか公開しない。

import Foundation
import RotoKit

/// 影から起こした「いまの姿」（値型 — 画面へ渡すコピー）
struct RotoInspection: Equatable {
    /// 1 セル分
    struct Cell: Equatable, Identifiable {
        /// マトリクス座標（= CC 番号。影のキー）
        let cell: Int
        /// 物理ノブの位置 1-8（画面の並び）
        let knob: Int
        /// 最後に送ったラベル。**`nil` = 影に無い**（まだ一度も送っていない）
        let label: String?
        /// 最後に送った色 index
        let color: UInt8?
        /// 最後に控えたモーター位置（14bit raw）。`nil` = まだ何も無い
        let motorRaw: Int?

        /// ⚠️ **その値が受信で裏を取れたものか**（mako 要望 2026-08-07）。
        ///
        /// `motorRaw` は**送信でも受信でも進む**ので、これが無いと
        /// 「実機がそこに居る」と「そこへ送っただけ」が混ざる。
        /// **`FaceBelief` と同じ規則**で、確認なら緑・推定なら黄で出す
        let motorConfirmed: Bool

        /// **この席に割当があるか**。⚠️ 未割当の K は
        /// `LADYLAND_PARK_EMPTY_KNOBS` の対象で、**値を送っていない = 触っても
        /// 動かない**のが正常。それが読めないと「壊れている」に見える
        let assigned: Bool

        var id: Int { knob }

        /// **正規化した位置 0...1**（`apply` が使う値と同じ計算）
        var motorNormalized: Double? {
            motorRaw.map { RotoInspection.normalize($0) }
        }
    }

    /// 実機と繋がっているか
    let connected: Bool
    /// いま表示している面（**送信を決めている値** = `currentFace`）
    let face: String
    /// **実機がどの面に居ると信じているか + その確からしさ**
    /// （mako 要望 2026-08-07）。⚠️ `face` とは別勘定 — あちらは送信を決め、
    /// こちらは**実機との食い違いを見せる**ためにある
    let belief: FaceBelief
    /// SMART 面のページ（0 始まり）
    let page: Int
    /// 握手（DAW 種別の名乗り）が済んでいるか
    let handshakeDone: Bool
    /// **影が空か** — 空 = 次の投影で全セルを送り直す、という状態
    let shadowEmpty: Bool
    /// 現在ページの 8 セル
    let cells: [Cell]

    /// 影を読む前の初期値（未接続・空）
    static let empty = RotoInspection(
        connected: false, face: "—", belief: .unknown, page: 0, handshakeDone: false,
        shadowEmpty: true, cells: [])

    // MARK: - 純関数（テスト対象）

    /// 14bit raw（0-16383）を 0...1 へ。**`apply` と同じ割り算**にする —
    /// ここがずれると「画面では合っているのに音が違う」を作る
    static func normalize(_ raw: Int) -> Double {
        RotoValue14.normalized(raw)
    }

    /// 影のラベル欄を分解する。
    ///
    /// ⚠️ 影は **`"\(色)|\(ラベル)"`** の 1 本の文字列で持っている
    /// （`RotoService` の `entry`）。**ラベル側に `|` が入りうる**ので、
    /// **最初の 1 個でだけ切る**（`split` の `maxSplits: 1`）。
    /// 分解できなければ色は `nil`、全体をラベルとして返す — **表示は落とさない**
    static func parseEntry(_ entry: String?) -> (color: UInt8?, label: String?) {
        guard let entry else { return (nil, nil) }
        let parts = entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let color = UInt8(parts[0]) else {
            return (nil, entry)
        }
        return (color, String(parts[1]))
    }

    /// 影から現在ページの 8 セルを起こす（**コピーするだけ**）。
    ///
    /// `cellForKnob` は物理ノブ位置 → マトリクス座標の対応
    /// （席が無いページ端は `nil`）
    static func cells(
        shadow: RotoShadow, knobs: Int, cellForKnob: (Int) -> Int?,
        isAssigned: (Int) -> Bool = { _ in false }
    ) -> [Cell] {
        (0..<knobs).map { knob in
            guard let cell = cellForKnob(knob) else {
                return Cell(
                    cell: -1, knob: knob + 1, label: nil, color: nil, motorRaw: nil,
                    motorConfirmed: false, assigned: false)
            }
            let (color, label) = parseEntry(shadow.label[cell])
            return Cell(
                cell: cell, knob: knob + 1, label: label, color: color,
                motorRaw: shadow.motorRaw[cell],
                motorConfirmed: shadow.motorObserved.contains(cell),
                assigned: isAssigned(cell))
        }
    }
}
