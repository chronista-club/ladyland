//! LPD8 のノブ 8 を刺す Jack（spec/09、mako 裁定 2026-09-26「Keystage の
//! つまみで出来ていたことを LPD8 で代用したい」— スタジオの鍵盤 + PC + 小さな
//! 機材で動けるように）。
//!
//! 刺し先は 2 つ:
//!   - `drums`（従来）: ドラム席の顔つまみ（`drumFaceKnobs`）
//!   - `face`: 選択 Track の顔つまみ（Keystage のノブ帯と同じ席）。
//!     **位置 i → 現ページの席 i**。ページの正典は `KnobPages`、いまのページは
//!     `activeKnobPage ?? rotoPage`（Keystage の OLED と同じ読み）
//!
//! ⚠️ face のときは **4 プログラム分のノブ CC を全部飲む** — 本体の PROG を
//! 切り替えてもノブ CC がドラム音源へ漏れない（PROG はパッド用のまま）。
//! ページを PROG 番号で分ける案は不採用（mako 裁定 2026-09-26 — ページは
//! ROTO / GUI の activeKnobPage に追従する）

import Foundation

/// LPD8 ノブ 8 の刺し先。raw 値は snapshot / DB に入るので改名禁止
enum Lpd8KnobJack: String, CaseIterable {
    case drums
    case face
}

enum Lpd8FaceKnobs {
    /// 顔つまみに刺さっているときに飲む CC — 既定 4 プログラム分 + エディタで
    /// 焼き替えた現在の 8 本
    static func interceptedCCs(current: [UInt8]) -> Set<UInt8> {
        Set(Lpd8DefaultKnobCCs.byProgram.flatMap { $0 }).union(current)
    }

    /// 受けた CC を席（CC0-63）に読み替える。現在の 8 本を先に見て、
    /// 無ければ既定の 4 プログラムから位置を引く。ノブでなければ nil
    static func seat(forCC cc: UInt8, current: [UInt8], page: Int) -> Int? {
        let index = current.firstIndex(of: cc) ?? Lpd8DefaultKnobCCs.index(of: cc)
        guard let index else { return nil }
        let seats = KnobPages.page(page)
        guard seats.indices.contains(index) else { return nil }
        return seats[index]
    }
}
