//! ROTO の表示内容を、影との差分を取った送信列へ変換する層。
//!
//! `RotoDisplay` が文字と色を決め、ここが「前回と違うものだけ送る」という
//! 投影規則を担当する。MIDI I/O は持たないので、送信前の順序と影の進み方を
//! 実機なしで検証できる。
//! 実測の経緯: docs/roto-control/refactor-invariants.md「送信と影」。

import Foundation
import RotoKit

enum RotoProjection {
    /// SMART 面の 1 セルぶんの、確定済み表示内容。
    struct SmartCell: Equatable {
        let deviceCell: Int
        let isMapped: Bool
        let label: String
        let color: UInt8
    }

    /// SMART 面の差分だけを SysEx にする。
    ///
    /// 空セルを送らない設定でも、割り当て済みだが名前を解決できなかったセルは
    /// 投影する。活性状態を示す `isMapped` と表示名の有無は別の事実だからである。
    static func smartMessages(
        cells: [SmartCell], fillsEmpty: Bool, shadow: inout RotoShadow
    ) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        for cell in cells {
            guard fillsEmpty || cell.isMapped else { continue }
            guard let index = UInt8(exactly: cell.deviceCell) else { continue }
            let entry = "\(cell.color)|\(cell.label)"
            guard shadow.label[cell.deviceCell] != entry else { continue }
            shadow.label[cell.deviceCell] = entry
            messages.append(
                Roto.setPluginControlDetails(index, name: cell.label, color: cell.color))
        }
        return messages
    }

    /// MAIN LCD の差分を、実機が要求する「据える → 文字 → 色」の順で返す。
    /// 2026-08-06: 据え直しは実機が無視したため、影が空の初回だけ据える。
    /// 影は文字と色の両方を含める。文字が同じでも色変更は送る。
    static func mainLcdMessages(
        track: Int, text: String, color: UInt8, enabled: Bool,
        shadow: inout RotoShadow
    ) -> [[UInt8]] {
        guard enabled else { return [] }
        let entry = "\(color)|\(text)"
        guard shadow.menu != entry else { return [] }

        let (red, green, blue) = RotoDisplay.mainLcdBackground(paletteIndex: color)
        var messages: [[UInt8]] = []
        // 面に入った直後だけ据える。実機は 2 度目以降の据え直しを無視する。
        if shadow.menu == nil {
            messages.append(
                Roto.selectFocusTrack(
                    UInt8(min(15, max(0, track))), name: text,
                    red: red, green: green, blue: blue))
        }
        shadow.menu = entry
        messages.append(Roto.setMenuText(text))
        messages.append(Roto.setMenuColor(red: red, green: green, blue: blue))
        return messages
    }

    /// Bitwig 方言のトラック一覧を、枠付きバッチと選択通知の組で返す。
    static func trackMessages(
        names: [String], selected: Int, shadow: inout RotoShadow
    ) -> [[UInt8]] {
        let entry = "\(selected)\u{1}" + names.joined(separator: "\u{1}")
        guard shadow.trackBatch != entry else { return [] }
        shadow.trackBatch = entry

        var messages = Roto.trackBatch(names)
        if names.indices.contains(selected) {
            messages.append(Roto.selectedTrack(selected, name: names[selected]))
        }
        return messages
    }
}
