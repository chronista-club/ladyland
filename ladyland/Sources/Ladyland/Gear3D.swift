//! 3D の机のモデル（純関数）— 機材の下書き・Jack の契約・載せ替え・実機の CC の意味。
//!
//! mako 2026-10-04「ジャックの部分をフル 3D できっちりモデリングした機材を画面に
//! 出して、その上に例えばナノコントロール 2 の上にミキサーを置くみたいな感じで
//! コネクトできるようにしたい」（GO「やってみよう」）。
//!
//! - **物理層** = `GearBlueprint`（実寸 mm の下書き）。可動部は 1 本ずつ名前付きの
//!   部品 — Blender で清書した USDZ も同じ名前で掴む（`fader_3` など）
//! - **仮想の部品** = `VirtualComponent`（Mixer / Track ノブ）
//! - **載せられるか = Jack の契約**（spec/09）。Mixer は「フェーダー × 8」を
//!   要求し、満たすセクションにだけ載る。載せた部品が実機の CC の意味を決める
//!
//! 座標: 機材の中心が原点、x = 左右（右 +）、z = 奥行き（奥 −、手前 +）、mm。
//! 机の上の位置も mm（`PlacedGear.origin` = 机座標での機材の中心）

import CoreGraphics
import Foundation

// MARK: - 物理層（機材の下書き）

/// 部品 1 つ（可動部は名前で掴む）
struct GearPart: Equatable {
    enum Kind: Equatable { case fader, knob, button }
    let name: String
    let kind: Kind
    /// 天面上の中心（x, z）mm
    let center: SIMD2<Float>
    /// 大きさ（幅 x, 高さ y, 奥行き z）mm。フェーダーはつまみの大きさ
    let size: SIMD3<Float>
    /// フェーダーの可動幅（z 方向）mm。それ以外は 0
    var travel: Float = 0
}

/// 機材のセクション（Jack の契約の単位 — 同じ種類の操作子の列）
struct GearSection: Equatable {
    enum Kind: Equatable { case faders, knobs, buttons }
    let id: String
    let kind: Kind
    /// 列の部品名（左から）
    let parts: [String]
    /// 実機が送る CC（部品と同じ順）
    let ccs: [UInt8]
}

struct GearBlueprint: Equatable {
    let id: String
    let title: String
    /// 外形（幅 x, 高さ y, 奥行き z）mm
    let size: SIMD3<Float>
    let parts: [GearPart]
    let sections: [GearSection]

    /// セクションの足跡（mm、機材の中心が原点。CGRect の y = z）。
    /// フェーダーは可動幅まで含める — 載せる先の当たりを広く取る
    func footprint(of section: GearSection) -> CGRect {
        let rects = section.parts.compactMap { name in
            parts.first { $0.name == name }.map { part in
                CGRect(
                    x: CGFloat(part.center.x - part.size.x / 2),
                    y: CGFloat(part.center.y - (part.size.z + part.travel) / 2),
                    width: CGFloat(part.size.x),
                    height: CGFloat(part.size.z + part.travel))
            }
        }
        return rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    static let all: [GearBlueprint] = [nanoKontrol2]

    static func section(id: String) -> GearSection? {
        all.lazy.flatMap(\.sections).first { $0.id == id }
    }

    /// KORG nanoKONTROL2。外形は公称 320 × 83 × 29 mm。**配置は KORG 公式の真上からの
    /// 写真（1200 × 800）を画素で測ってトレースした**（2026-10-04、mako「web から画像
    /// 持ってきて、寸分違わない感じで、トレース出来る？」）。筐体の外接（1142 × 290 px）を
    /// 320 × 83 mm に合わせ、横 0.2802 / 縦 0.2862 mm/px で換算。赤く光るボタンは
    /// 色で拾った中心、ノブ・フェーダー・楕円ボタンは 10 px 目盛りで読んだ値。
    /// 横の 3 行は S/M/R の行に揃える（mako「実物は３ラインで揃ってます」）。
    /// CC は実測（2026-10-01、Creo `mem_1CfaNw1FapMJStBsdwsVPA`）
    static let nanoKontrol2: GearBlueprint = {
        var parts: [GearPart] = []
        // 横 3 行（S / M / R の中心、z mm）と、左側の縦 5 列（x mm）
        let row: [Float] = [-4.3, 10.7, 25.9]
        let col: [Float] = [-142.1, -126.7, -111.2, -95.7, -80.3]
        // 左 — Track ◀▶ / CYCLE・Marker（細長い楕円）、◀◀ ▶▶ ■ ▶ ●（大きい角）
        let pill = SIMD3<Float>(10.6, 3, 4.6)
        let square = SIMD3<Float>(11.2, 3, 10.9)
        let transport: [(String, Float, Float, SIMD3<Float>)] = [
            ("track_prev", col[0], row[0], pill), ("track_next", col[1], row[0], pill),
            ("cycle", col[0], row[1], pill), ("marker_set", col[2], row[1], pill),
            ("marker_prev", col[3], row[1], pill), ("marker_next", col[4], row[1], pill),
            ("rew", col[0], row[2], square), ("ff", col[1], row[2], square),
            ("stop", col[2], row[2], square), ("play", col[3], row[2], square),
            ("rec", col[4], row[2], square),
        ]
        for (name, x, z, size) in transport {
            parts.append(GearPart(name: name, kind: .button, center: [x, z], size: size))
        }
        // 右 — チャンネル 8 本。S/M/R の列の x（写真の中心）、フェーダーはその右 12.75 mm、
        // ノブはフェーダーの真上（奥）
        let strip: [Float] = [-60.2, -33.1, -6.2, 21.2, 48.1, 75.2, 102.3, 129.3]
        for (i, sx) in strip.enumerated() {
            let n = i + 1
            parts.append(GearPart(name: "knob_\(n)", kind: .knob, center: [sx + 13.3, -27.3], size: [12, 8, 12]))
            for (name, z) in zip(["s", "m", "r"], row) {
                parts.append(GearPart(name: "\(name)_\(n)", kind: .button, center: [sx, z], size: [8.7, 3, 8.9]))
            }
            parts.append(
                GearPart(
                    name: "fader_\(n)", kind: .fader, center: [sx + 12.75, row[1]], size: [8.4, 6, 22],
                    travel: 30))
        }
        let ccs = { (base: Int) in (base..<(base + 8)).map { UInt8($0) } }
        return GearBlueprint(
            id: "nanokontrol", title: "nanoKONTROL2", size: [320, 29, 83], parts: parts,
            sections: [
                GearSection(
                    id: "nanokontrol.faders", kind: .faders,
                    parts: (1...8).map { "fader_\($0)" }, ccs: ccs(0)),
                GearSection(
                    id: "nanokontrol.knobs", kind: .knobs,
                    parts: (1...8).map { "knob_\($0)" }, ccs: ccs(16)),
                GearSection(
                    id: "nanokontrol.mutes", kind: .buttons,
                    parts: (1...8).map { "m_\($0)" }, ccs: ccs(48)),
            ])
    }()
}

// MARK: - 仮想の部品と Jack の契約

/// 机に載せる仮想の部品（raw 値は window.json に入る — 改名禁止）
enum VirtualComponent: String, Codable, CaseIterable, Identifiable {
    case mixer, trackKnobs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer: return "8ch Mixer"
        case .trackKnobs: return "Track ノブ"
        }
    }

    /// 要求する能力（spec/09 の契約）
    var requires: GearSection.Kind {
        switch self {
        case .mixer: return .faders
        case .trackKnobs: return .knobs
        }
    }

    /// 載せられるか — 能力の種類が合い、8 本そろっている
    func canDock(on section: GearSection) -> Bool {
        section.kind == requires && section.ccs.count >= 8
    }
}

/// 机に置いた機材（机座標 mm での中心）
struct PlacedGear {
    let blueprint: GearBlueprint
    let origin: CGPoint
}

enum DockModel {
    /// 当たりの余白 mm（足跡ちょうどだと載せにくい）
    static let tolerance: CGFloat = 10

    /// 落とした点（机座標 mm）→ 載る先。契約に合わなければ nil
    static func section(for component: VirtualComponent, at point: CGPoint, gears: [PlacedGear])
        -> GearSection?
    {
        for gear in gears {
            for section in gear.blueprint.sections where component.canDock(on: section) {
                let rect = gear.blueprint.footprint(of: section)
                    .offsetBy(dx: gear.origin.x, dy: gear.origin.y)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                if rect.contains(point) { return section }
            }
        }
        return nil
    }

    /// 載せ替え（nil = 外す）。1 つのセクションに部品は 1 つ — 先客は外れる
    static func docking(_ component: VirtualComponent, on section: String?, in docks: [String: String])
        -> [String: String]
    {
        var next = docks.filter { $0.key != component.rawValue }
        if let section {
            next = next.filter { $0.value != section }
            next[component.rawValue] = section
        }
        return next
    }
}

// MARK: - 実機の CC → 載せた部品の操作

enum SurfaceAction: Equatable {
    case gain(slot: Int, value: Float)
    case toggleMute(slot: Int)
    case trackKnob(seat: Int, value: UInt8)
}

enum SurfaceMapping {
    /// 実機の CC 1 つを、いま載っている部品の操作に読み替える（nil = 何もしない —
    /// 載っていない操作子は音源へも流さない）。
    /// Mixer はフェーダー列に載り、同じ機材の M ボタン列も連れていく
    static func action(
        cc: UInt8, value: UInt8, docks: [String: String], bank: [Int], page: Int
    ) -> SurfaceAction? {
        if let id = docks[VirtualComponent.mixer.rawValue], let faders = GearBlueprint.section(id: id) {
            if let i = faders.ccs.firstIndex(of: cc) {
                guard bank.indices.contains(i) else { return nil }
                return .gain(slot: bank[i], value: Float(value) / 127)
            }
            let gear = id.split(separator: ".").first.map(String.init) ?? ""
            if let mutes = GearBlueprint.section(id: "\(gear).mutes"),
                let i = mutes.ccs.firstIndex(of: cc)
            {
                guard value > 0, bank.indices.contains(i) else { return nil }
                return .toggleMute(slot: bank[i])
            }
        }
        if let id = docks[VirtualComponent.trackKnobs.rawValue],
            let knobs = GearBlueprint.section(id: id),
            let i = knobs.ccs.firstIndex(of: cc)
        {
            let seats = KnobPages.page(page)
            guard seats.indices.contains(i) else { return nil }
            return .trackKnob(seat: seats[i], value: value)
        }
        return nil
    }
}
