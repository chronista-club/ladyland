//! ROTO-CONTROL の LCD 表示を組み立てる純粋層。
//!
//! MIDI 接続や送信状態を持たず、表示文字列と色だけを決める。
//! `RotoService` は投影のタイミングを管理し、この型が返す値を送る。
//! 実測の経緯: docs/roto-control/refactor-invariants.md「LCD の表示」。

import Foundation
import RotoKit

enum RotoDisplay {
    private static let lcdCapacity = 12

    /// ページピッカーの表示。仮選択中のページだけ印を付ける。
    static func pickerLabels(current: Int, pages: Int = 8) -> [String] {
        (0..<pages).map { page in
            page == current ? "▶ #\(page + 1)" : "#\(page + 1)"
        }
    }

    /// SMART セル1個の表示内容。
    struct SmartCellFace: Equatable {
        let label: String
        let color: UInt8
    }

    /// 未割り当ては `-` と空席色にする。
    ///
    /// 空文字では実機のLCDに前の表示が残る。空席にページタグを付けると
    /// 割り当て済みに見えるため、タグも出さない。
    /// 2026-08-06 裁定: 記号は短い `-`（hyphen）。`—`（em dash）へ替えない。
    static func smartCellFace(
        name: String?, pageTag: String, emptyColor: UInt8, assignedColor: UInt8
    ) -> SmartCellFace {
        guard let name else {
            return SmartCellFace(label: "-", color: emptyColor)
        }
        return SmartCellFace(
            label: labelWithPage(name, page: pageTag), color: assignedColor)
    }

    /// 名前とページ番号が12文字に収まるときだけ、ページ番号を右寄せする。
    /// 収まらなければパラメータ名を優先する。
    /// 2026-08-05: 実機は折り返さず1行のままだったため、改行に頼らない。
    static func labelWithPage(_ name: String, page: String) -> String {
        let needed = name.count + 1 + page.count
        guard needed <= lcdCapacity else { return String(name.prefix(lcdCapacity)) }
        let gap = String(repeating: " ", count: lcdCapacity - name.count - page.count)
        return name + gap + page
    }

    /// MAIN LCDの2行目。トラック名を先頭、ページ番号を右端に置く。
    /// 2026-08-06 裁定: `[1]` → `#1` で名前に1文字を回す。右端を固定し、
    /// 名前が溢れた場合もページを残す。1行目はデバイスが所有する。
    static func mainLcdText(page: Int, track: String?) -> String {
        let tag = "#\(page + 1)"
        guard let track, !track.isEmpty else { return tag }
        let room = lcdCapacity - tag.count
        guard room > 0 else { return tag }
        let name = shortName(track, limit: room)
        let gap = String(repeating: " ", count: max(0, lcdCapacity - name.count - tag.count))
        return name + gap + tag
    }

    /// 括弧内のカテゴリを除き、LCD幅に収まる名前へ切り詰める。
    /// 2026-08-06: `Phoenix (Analog)` を直接切ると `Phoenix (` が残った。
    /// カテゴリを先に除き、切り口の空白・記号も取り除く。
    static func shortName(_ name: String, limit: Int) -> String {
        let base = name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? name
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let source = trimmed.isEmpty ? name : trimmed
        guard source.count > limit else { return source }
        return String(source.prefix(limit))
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    /// 83色パレットのindexをMAIN LCDへ送るRGBに展開する。
    ///
    /// 文字色は実機側の白固定だが、選択色を勝手に暗くすると設定と表示が
    /// 食い違うため、RGB値はそのまま使う。
    /// 2026-08-06: 白地に白文字で読めなくなることを実測。暗くする案の後に
    /// 「設定で変えたい」と裁定されたため、自動減光へ戻さず選択側で調整する。
    static func mainLcdBackground(paletteIndex: UInt8) -> (UInt8, UInt8, UInt8) {
        let rgb = Roto.Color.palette[Int(paletteIndex) % Roto.Color.palette.count]
        return (
            UInt8((rgb >> 16) & 0xFF),
            UInt8((rgb >> 8) & 0xFF),
            UInt8(rgb & 0xFF)
        )
    }
}
