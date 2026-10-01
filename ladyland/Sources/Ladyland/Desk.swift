//! 机 — 2.5D の Jack（mako 赤入れ 2026-10-01 `mem_1CfavSouA1wvZ557nwJRrP`、
//! 裁定「2.5D から。操作は機材そのもの + 結線の刺し替え + 配置」）。
//!
//! 画面の机に機材を置き、**その上で弾く・刺し替える・並べ替える**。奥に
//! 8ch Mixer、中段に LPD8、手前に鍵盤 — スタジオの机を斜め上から見た絵。
//!
//! ここは**純関数のモデル**（テスト対象）。描画は `DeskView`。配置は 0-1 の
//! 机座標（x = 左右、depth = 奥 0 → 手前 1）で持ち、画面サイズに依らない。
//! 置き場は window.json（マシン固有 = 会場ごとの配置）。後で RealityKit に
//! 置き換えるときも、この配置はそのまま使う

import Foundation

/// 机に乗る機材（raw 値は window.json に入る — 改名禁止）
enum DeskGear: String, Codable, CaseIterable, Identifiable {
    case mixer, lpd8, nanokontrol, keystage, keyboard
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer: return "8ch Mixer"
        case .lpd8: return "LPD8"
        case .nanokontrol: return "nanoKONTROL2"
        case .keystage: return "Keystage"
        case .keyboard: return "鍵盤"
        }
    }
}

/// 机の上の位置（0-1）。depth 0 = 奥、1 = 手前
struct DeskPlacement: Codable, Equatable {
    var x: Double
    var depth: Double
}

enum DeskModel {
    /// 机に乗せる機材 — 常設（Mixer / 鍵盤）+ 繋がっているもの。
    /// 奥から手前の順（描画順 = 手前が上に重なる）。Keystage が居れば
    /// 汎用鍵盤の板は出さない（鍵盤は 1 枚で足りる）
    static func gears(sources: [MIDIConnectedSource]) -> [DeskGear] {
        let has: (MIDISourceRoute) -> Bool = { route in sources.contains { $0.route == route } }
        let nano = sources.contains { $0.name.contains("nanoKONTROL") }
        var gears: [DeskGear] = [.mixer]
        if nano { gears.append(.nanokontrol) }
        if has(.drums) { gears.append(.lpd8) }
        gears.append(has(.keystage) ? .keystage : .keyboard)
        return gears
    }

    /// 既定の配置（赤入れの並び）
    static func defaultPlacement(_ gear: DeskGear) -> DeskPlacement {
        switch gear {
        case .mixer: return DeskPlacement(x: 0.5, depth: 0.12)
        case .nanokontrol: return DeskPlacement(x: 0.2, depth: 0.45)
        case .lpd8: return DeskPlacement(x: 0.6, depth: 0.5)
        case .keystage, .keyboard: return DeskPlacement(x: 0.5, depth: 0.85)
        }
    }

    static func clamp(_ placement: DeskPlacement) -> DeskPlacement {
        DeskPlacement(
            x: min(max(placement.x, 0), 1),
            depth: min(max(placement.depth, 0), 1))
    }

    /// 机座標 → 板の上の点
    static func point(_ placement: DeskPlacement, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * placement.x, y: size.height * placement.depth)
    }

    /// ドラッグの移動量を机座標に戻す
    static func moved(_ placement: DeskPlacement, by translation: CGSize, in size: CGSize)
        -> DeskPlacement
    {
        guard size.width > 0, size.height > 0 else { return placement }
        return clamp(
            DeskPlacement(
                x: placement.x + Double(translation.width / size.width),
                depth: placement.depth + Double(translation.height / size.height)))
    }

    /// 保存した配置があればそれ、無ければ既定
    static func placement(_ gear: DeskGear, saved: [String: DeskPlacement]?) -> DeskPlacement {
        saved?[gear.rawValue] ?? defaultPlacement(gear)
    }
}

/// 画面の鍵盤の鍵の並び（純関数）
enum DeskKeyboard {
    struct Key: Equatable {
        let note: UInt8
        let isBlack: Bool
        /// 白鍵なら自分の番号、黒鍵なら**直前の白鍵**の番号（その右半分に乗る）
        let whiteIndex: Int
    }

    /// 半音 → 黒鍵か（C C# D D# E F F# G G# A A# B）
    private static let blackSemitones: Set<Int> = [1, 3, 6, 8, 10]

    static func keys(baseNote: UInt8, octaves: Int) -> [Key] {
        var keys: [Key] = []
        var white = -1
        for i in 0..<(octaves * 12) {
            let note = Int(baseNote) + i
            guard note <= 127 else { break }
            let isBlack = blackSemitones.contains(i % 12)
            if !isBlack { white += 1 }
            keys.append(Key(note: UInt8(note), isBlack: isBlack, whiteIndex: white))
        }
        return keys
    }
}
