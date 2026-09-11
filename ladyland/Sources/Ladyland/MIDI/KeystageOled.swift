//! Keystage のノブ OLED へ「いま何を握っているか」を書く（Func 0x28）。
//!
//! ## 実機で確定していること（2026-08-07、`RigBench keystage-oled` + mako 目視）
//!
//! - **`0x6F` 接続（Ableton 方式）だけで Display Message が効く** — Native Mode
//!   Enter（ノブを CC0-7/ch16 に固定して 8 ページと排他になる）は不要
//! - **ノブ 1-8 を個別に指定できる**（Display Address 1-8。0 = メイン、
//!   Line 0 = 上段 / 1 = 下段）。テキストは ASCII 0x20-0x7F、最大 124 byte
//!   （`docs/keystage/Keystage_MIDIimp.txt` L548-563）
//!
//! ## ⚠️⚠️ 恒久表示は不可能（実測 2026-08-10 で確定。既定 off の理由）
//!
//! 3 つの実測が揃って、ファームウェア制約と確定した:
//!
//! | 実測 | 帰結 |
//! |---|---|
//! | 接続なしの 0x28 は**無反応**（0x6F を送らず直接送って確認） | 表示には接続状態が必須 |
//! | **切断の約 1 秒後に実機自身が CCn 表示へ描き直す** | 切断すると消える |
//! | 接続しっぱなしは **PAGE / VALUE が死ぬ**（実測 2026-08-07） | 常時接続は不可 |
//!
//! つまり**「恒久表示」と「PAGE が生きる」は両立しない**。追いかけて書き直す
//! 案（デバウンス 2 発撃ち）も試したが、**書くたびに 1 秒で戻る**ので
//! チラつきが増えるだけだった（mako「２回表示されて、再度戻る」）。
//!
//! ⚠️ 2026-08-09 の「切断後も表示が残る」という観測は**誤りだった** —
//! 翌日の再観測で毎回約 1 秒で戻ることを確認。
//!
//! **mako 裁定 2026-08-10: 既定 off。** `LADYLAND_KEYSTAGE_OLED=1` で
//! 「切替時 1 回のフラッシュ表示（約 1 秒だけ名前が見える）」として試せる。
//! ファームウェア更新で制約が変わったら、ここから復活させる。
//!
//! ## 文字の制約
//!
//! OLED は ASCII のみ。**日本語などで全滅したら座標名（P2-3）へ倒す** —
//! 空文字を送ると LCD が消えず前の表示が残る（ROTO の実測 2026-08-06 と同じ罠）。
//! 幅はノブ 12 字（コミュニティ情報。KORG チャートは Max 124 としか言わない —
//! 溢れたら実機が切るだけなので、こちらは 12 で切って送る）

import Foundation
import KeystageKit

enum KeystageOled {
    /// ノブ 1 本ぶんの表示（上段 = 名前 / 下段 = 値）
    struct KnobFace: Equatable {
        let name: String
        let value: String
    }

    /// ノブ OLED の幅（コミュニティ実測 12 字。実機の切り詰めに任せず揃える）
    static let knobWidth = 12

    /// ASCII 0x20-0x7F へ落として `knobWidth` で切る。
    /// ⚠️ **全滅したら fallback**（空文字は「前の表示が残る」ので送らない）
    static func text(_ source: String, fallback: String) -> String {
        let ascii = source.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }
        let cut = String(String.UnicodeScalarView(ascii)).trimmingCharacters(in: .whitespaces)
        let chosen = cut.isEmpty ? fallback : cut
        return String(chosen.prefix(knobWidth))
    }

    /// 1 行ぶんの Display Message（address 0 = メイン / 1-8 = ノブ、line 0 = 上段）
    static func frame(
        address: Int, line: Int, text: String, channel: UInt8, model: Keystage.Model
    ) -> [UInt8] {
        Keystage.frame(
            .displayMessage,
            data: [UInt8(address & 0x7F), UInt8(line & 0x7F)] + Array(text.utf8),
            globalChannel: channel, model: model)
    }

    /// ページ 1 枚ぶんの表示内容（メイン上段 = ページ名 + ノブ 8 本 × 2 行）。
    /// ⚠️ **キーは「address:line」** — 影（前回送った内容）との差分はこの単位
    static func lines(page: Int, faces: [KnobFace]) -> [(key: String, address: Int, line: Int, text: String)] {
        var out: [(String, Int, Int, String)] = [("a0l0", 0, 0, "P\(page + 1)")]
        for (index, face) in faces.prefix(8).enumerated() {
            let seat = KnobPages.page(page).dropFirst(index).first ?? 0
            let fallback = FaceKnobAssignment.ctrlLabel(seat)
            out.append(("a\(index + 1)l0", index + 1, 0, text(face.name, fallback: fallback)))
            out.append(("a\(index + 1)l1", index + 1, 1, text(face.value, fallback: "-")))
        }
        return out
    }
}
