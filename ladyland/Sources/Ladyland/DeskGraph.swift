//! 机の結線 — 結線図（ノードグラフ）の情報を机に畳むモデル（純関数）。
//!
//! mako 2026-10-04「画面上のノードグラフを下の新しいビューにマッピング。
//! 統一させて一つのビューに情報まとめよう」。机は**物理層の上に仮想層を
//! 重ねる場所**（同日「動かせないもの(MIDIコン)を、仮想的に配置して、
//! そこにヴァーチャルなコンポーネントを重ねる」）:
//!
//! - **物理層** = 機材の板（実機の形。セクションごとに**ソケット**を持つ）
//! - **仮想層** = ケーブル、プラグの札、ノブに重ねるパラメータ名
//! - **仮想機材** = 奥の Mixer。engine 側の顔で、**Jack の箱は無い** —
//!   ケーブルは直接その Track のストリップ（ドラムは DRUMS）へ届く
//!
//! 結線図の行（`JackBoardView.gearRows`）は 1 つ残らずどこかのソケットに
//! 写る。机に板が無い機材（MiniLab / NCXse / Keystage 在席時の汎用鍵盤）は
//! 左の**棚**に並ぶ — 挿さっていれば線が出て、抜けていれば薄い。

import CoreGraphics
import Foundation

/// 機材のセクションの差込口（ケーブルの始点）
struct DeskSocket: Identifiable, Equatable {
    /// アンカーのキー（板のソケットは `<gear>.<kind>`、棚は結線図の行 id）
    let id: String
    /// どの板に付くか（nil = 棚）
    let home: DeskGear?
    let gear: String
    let section: String
    let jack: JackBoardView.JackID
    let connected: Bool
    /// プラグを掴んで刺し替えられるか（鍵盤と LPD8 のノブだけ）
    let repluggable: Bool
}

/// ケーブルの行き先（Mixer の上）
enum CableTarget: Equatable {
    /// その席のストリップ。follows = 「選択に追従」で選択中に繋がっている
    case strip(Int, follows: Bool)
    case drums
}

/// プラグを落とした場所
enum DeskDropTarget: Equatable {
    case strip(Int)
    case drums
    /// Mixer の外 — 鍵盤なら「選択に追従」へ戻す
    case outside
    /// Mixer の中だがストリップの隙間 — 何もしない
    case none
}

/// 刺し替えの結果（AppState への書き込み 1 つに対応）
enum DeskRebind: Equatable {
    case synth1(Int?)
    case synth2(Int?)
    case lpd8Knobs(Lpd8KnobJack)
    case none
}

enum DeskGraph {
    /// ケーブルの行き先を決める束縛（AppState の写し）
    struct Bindings: Equatable {
        var synth1: Int?
        var synth2: Int?
        var selected: Int
        /// Track ノブの現ページ（0 始まり）
        var page: Int
    }

    // MARK: - ソケット

    /// 結線図の行 → ソケット。同じ板・同じセクションの行は 1 つに畳む
    /// （PC キーボードと汎用鍵盤は、鍵盤の板の「鍵盤 1」に合流する）
    static func sockets(rows: [JackBoardView.GearRow], gears: [DeskGear]) -> [DeskSocket] {
        let keyboardCard: DeskGear? =
            gears.contains(.keystage) ? .keystage : (gears.contains(.keyboard) ? .keyboard : nil)
        var result: [DeskSocket] = []
        var index: [String: Int] = [:]

        func put(_ socket: DeskSocket) {
            if let i = index[socket.id] {
                let old = result[i]
                result[i] = DeskSocket(
                    id: old.id, home: old.home, gear: old.gear, section: old.section,
                    jack: old.jack, connected: old.connected || socket.connected,
                    repluggable: old.repluggable)
            } else {
                index[socket.id] = result.count
                result.append(socket)
            }
        }

        for row in rows {
            let home: DeskGear?
            let kind: String
            switch row.id {
            case "keystage.keys":
                home = gears.contains(.keystage) ? .keystage : nil
                kind = "keys"
            case "keystage.knobs":
                home = gears.contains(.keystage) ? .keystage : nil
                kind = "knobs"
            case "lpd8.pads":
                home = gears.contains(.lpd8) ? .lpd8 : nil
                kind = "pads"
            case "lpd8.knobs":
                home = gears.contains(.lpd8) ? .lpd8 : nil
                kind = "knobs"
            default:
                // PC キーボードと「鍵盤 1」の汎用鍵盤は、鍵盤の板に畳む
                if row.jack == .synth1, let card = keyboardCard {
                    home = card
                    kind = "keys"
                } else {
                    home = nil
                    kind = ""
                }
            }
            let repluggable = row.jack == .synth1 || row.jack == .synth2 || row.id == "lpd8.knobs"
            if let home {
                put(
                    DeskSocket(
                        id: "\(home.rawValue).\(kind)", home: home, gear: home.title,
                        section: row.section, jack: row.jack, connected: row.connected,
                        repluggable: repluggable))
            } else {
                put(
                    DeskSocket(
                        id: row.id, home: nil, gear: row.gear, section: row.section,
                        jack: row.jack, connected: row.connected, repluggable: repluggable))
            }
        }
        return result
    }

    // MARK: - ケーブル

    static func target(_ jack: JackBoardView.JackID, _ b: Bindings) -> CableTarget {
        switch jack {
        case .synth1: return .strip(b.synth1 ?? b.selected, follows: b.synth1 == nil)
        case .synth2: return .strip(b.synth2 ?? b.selected, follows: b.synth2 == nil)
        case .trackKnobs: return .strip(b.selected, follows: true)
        case .drums: return .drums
        }
    }

    /// プラグの札 — Jack 名。追従なら「· 追従」、Track ノブはページ、
    /// 行き先がバンク外なら席番号（ケーブルは Mixer の端に着く）
    static func plugLabel(_ jack: JackBoardView.JackID, _ b: Bindings, bank: [Int]) -> String {
        let name: String
        switch jack {
        case .synth1: name = "鍵盤 1"
        case .synth2: name = "鍵盤 2"
        case .trackKnobs: return "Track ノブ P\(b.page + 1)"
        case .drums: return "ドラム"
        }
        guard case .strip(let slot, let follows) = target(jack, b) else { return name }
        if follows { return "\(name) · 追従" }
        return bank.contains(slot) ? name : "\(name) → T\(slot + 1)"
    }

    // MARK: - 刺し替え

    static func dropTarget(
        at point: CGPoint, strips: [Int: CGRect], drums: CGRect?, mixer: CGRect?
    ) -> DeskDropTarget {
        if let drums, drums.contains(point) { return .drums }
        if let hit = strips.first(where: { $0.value.contains(point) }) { return .strip(hit.key) }
        if let mixer, mixer.contains(point) { return .none }
        return .outside
    }

    static func rebind(_ socket: DeskSocket, drop: DeskDropTarget) -> DeskRebind {
        guard socket.repluggable else { return .none }
        if socket.id == "lpd8.knobs" {
            switch drop {
            case .strip: return .lpd8Knobs(.face)
            case .drums: return .lpd8Knobs(.drums)
            case .outside, .none: return .none
            }
        }
        let slot: Int??
        switch drop {
        case .strip(let i): slot = .some(i)
        case .outside: slot = .some(nil)
        case .drums, .none: slot = nil
        }
        guard let slot else { return .none }
        switch socket.jack {
        case .synth1: return .synth1(slot)
        case .synth2: return .synth2(slot)
        case .trackKnobs, .drums: return .none
        }
    }

    // MARK: - 仮想層（ノブに重ねる名前）

    /// LPD8 のノブ i にいま割り当たっているパラメータ名（nil = 空き）。
    /// Track ノブなら現ページの席、ドラムならドラム席の CC そのまま
    static func lpd8KnobLabel(
        index: Int, jack: Lpd8KnobJack, knobCCs: [UInt8], page: Int,
        selected: [FaceKnobMapping], drums: [FaceKnobMapping]
    ) -> String? {
        guard knobCCs.indices.contains(index) else { return nil }
        let cc = knobCCs[index]
        switch jack {
        case .face:
            guard let seat = Lpd8FaceKnobs.seat(forCC: cc, current: knobCCs, page: page) else {
                return nil
            }
            return selected.first { $0.knob == seat }?.name
        case .drums:
            return drums.first { $0.knob == Int(cc) }?.name
        }
    }
}
