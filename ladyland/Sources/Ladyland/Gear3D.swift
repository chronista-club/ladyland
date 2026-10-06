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
    /// 操作子の種類（Blender の配置データの kind をここへ読み替える）。
    /// knob / encoder → knob、key_white / key_black → key、display などの飾り → other
    enum Kind: Equatable { case fader, knob, button, pad, key, other }
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
    enum Kind: Equatable { case faders, knobs, buttons, pads, keys }
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
    /// 外形（幅 x, 高さ y, 奥行き z）mm。高さはノブ込み
    let size: SIMD3<Float>
    /// 筐体そのものの厚み mm（操作子はこの上に乗る）
    var bodyHeight: Float = 16
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

    /// KORG nanoKONTROL2。外形は**取扱説明書の仕様 325 × 83 × 30 mm**（W × D × H、
    /// 高さはノブ込み。mako「pdf とかの方が参考になるかもね」）。**配置は KORG 公式の
    /// 真上からの写真（1200 × 800）を画素で測ってトレースした**（2026-10-04、mako
    /// 「web から画像持ってきて、寸分違わない感じで、トレース出来る？」）。筐体の外接
    /// （1142 × 290 px）を 325 × 83 mm に合わせ、横 0.2846 / 縦 0.2862 mm/px で換算
    /// （縦横ほぼ同じ比 = 写真のゆがみが小さい裏付け）。赤く光るボタンは
    /// 色で拾った中心、ノブ・フェーダー・楕円ボタンは 10 px 目盛りで読んだ値。
    /// 横の 3 行は S/M/R の行に揃える（mako「実物は３ラインで揃ってます」）。
    /// CC は実測（2026-10-01、Creo `mem_1CfaNw1FapMJStBsdwsVPA`）
    static let nanoKontrol2: GearBlueprint = {
        var parts: [GearPart] = []
        // 横 3 行（S / M / R の中心、z mm）と、左側の縦 5 列（x mm）
        let row: [Float] = [-4.3, 10.7, 25.9]
        let col: [Float] = [-144.3, -128.6, -113.0, -97.2, -81.5]
        // 左 — Track ◀▶ / CYCLE・Marker（細長い楕円）、◀◀ ▶▶ ■ ▶ ●（大きい角）
        let pill = SIMD3<Float>(10.8, 3, 4.6)
        let square = SIMD3<Float>(11.4, 3, 10.9)
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
        // 右 — チャンネル 8 本。S/M/R の列の x（写真の中心）、フェーダーはその右 12.95 mm、
        // ノブはフェーダーの真上（奥）
        let strip: [Float] = [-61.2, -33.6, -6.3, 21.5, 48.8, 76.4, 103.9, 131.3]
        for (i, sx) in strip.enumerated() {
            let n = i + 1
            parts.append(GearPart(name: "knob_\(n)", kind: .knob, center: [sx + 13.5, -27.3], size: [12, 13, 12]))
            for (name, z) in zip(["s", "m", "r"], row) {
                parts.append(GearPart(name: "\(name)_\(n)", kind: .button, center: [sx, z], size: [8.8, 3, 8.9]))
            }
            parts.append(
                GearPart(
                    name: "fader_\(n)", kind: .fader, center: [sx + 12.95, row[1]], size: [8.5, 9, 22],
                    travel: 30))
        }
        let ccs = { (base: Int) in (base..<(base + 8)).map { UInt8($0) } }
        return GearBlueprint(
            id: "nanokontrol", title: "nanoKONTROL2", size: [325, 30, 83], parts: parts,
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

    /// 載せられるか — 能力の種類が合い、8 本そろっている（CC の表は問わない —
    /// MIDI の結線がまだの機材にも、まず載せて形を確かめられるように）
    func canDock(on section: GearSection) -> Bool {
        section.kind == requires && section.parts.count >= 8
    }
}

/// 水平な機材の姿勢。Blender の Z 回転はアプリの Y 回転と同じ符号。
struct GearPose {
    var origin: CGPoint
    var elevation: Float = 0
    var yaw: Float = 0

    var position: SIMD3<Float> { [Float(origin.x) / 1000, elevation / 1000, Float(origin.y) / 1000] }
    var radians: Float { yaw * .pi / 180 }

    func worldPoint(_ local: CGPoint) -> CGPoint {
        let angle = CGFloat(yaw) * .pi / 180
        return CGPoint(x: origin.x + cos(angle) * local.x + sin(angle) * local.y,
                       y: origin.y - sin(angle) * local.x + cos(angle) * local.y)
    }

    func localPoint(_ world: CGPoint) -> CGPoint {
        let angle = CGFloat(yaw) * .pi / 180
        let x = world.x - origin.x, z = world.y - origin.y
        return CGPoint(x: cos(angle) * x - sin(angle) * z, y: sin(angle) * x + cos(angle) * z)
    }

    func footprint(size: CGSize) -> CGRect {
        let points = [-size.width / 2, size.width / 2].flatMap { x in
            [-size.height / 2, size.height / 2].map { worldPoint(CGPoint(x: x, y: $0)) }
        }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minZ = points.map(\.y).min()!, maxZ = points.map(\.y).max()!
        return CGRect(x: minX, y: minZ, width: maxX - minX, height: maxZ - minZ)
    }
}

/// 机に置いた機材（mm）。高さ・回転を省略した既存の机も読める。
struct PlacedGear {
    let blueprint: GearBlueprint
    let origin: CGPoint
    var elevation: Float = 0
    var yaw: Float = 0
    var height: Float? = nil
    var pose: GearPose { GearPose(origin: origin, elevation: elevation, yaw: yaw) }
    var top: Float { (elevation + (height ?? blueprint.size.y)) / 1000 }
}

enum DockModel {
    /// 当たりの余白 mm（足跡ちょうどだと載せにくい）
    static let tolerance: CGFloat = 10

    /// 落とした点（机座標 mm）→ 載る先。契約に合わなければ nil
    static func section(for component: VirtualComponent, at point: CGPoint, gears: [PlacedGear])
        -> GearSection?
    {
        for gear in gears {
            let local = gear.pose.localPoint(point)
            for section in gear.blueprint.sections where component.canDock(on: section) {
                let rect = gear.blueprint.footprint(of: section)
                    .insetBy(dx: -tolerance, dy: -tolerance)
                if rect.contains(local) { return section }
            }
        }
        return nil
    }

    /// LPD8 のノブ列に Track ノブを載せた / 外したときの LPD8 のノブの刺し先
    /// （nil = LPD8 に関係しない載せ替え — 手で選んだ刺し先に触らない）
    static func lpd8Jack(before: String?, after: String?) -> Lpd8KnobJack? {
        let lpd8 = "lpd8.knobs"
        if after == lpd8 { return .face }
        if before == lpd8 { return .drums }
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


// MARK: - Blender の配置データ（`Gear/<id>.json`）

extension GearBlueprint {
    private struct JSONPart: Decodable {
        let name: String
        let kind: String
        let center: [Float]
        let size: [Float]
        let travel: Float?
    }
    private struct JSONSection: Decodable {
        let id: String
        let kind: String
        let parts: [String]
        let ccs: [Int]?
    }
    private struct JSONSpec: Decodable {
        let id: String
        let title: String
        let size: [Float]
        let body_height: Float
        let parts: [JSONPart]
        let sections: [JSONSection]
    }

    /// `gear_build.py` が書き出す配置データ（鍵盤は展開済み）を読む。
    /// JSON は W × D × H / 部品は w × d × h — 内部は x × y(高さ) × z に並べ替える
    static func decode(_ data: Data) throws -> GearBlueprint {
        let spec = try JSONDecoder().decode(JSONSpec.self, from: data)
        func kind(_ k: String) -> GearPart.Kind {
            switch k {
            case "knob", "encoder": return .knob
            case "fader": return .fader
            case "button": return .button
            case "pad": return .pad
            case "key_white", "key_black": return .key
            default: return .other
            }
        }
        func sectionKind(_ k: String) -> GearSection.Kind {
            switch k {
            case "faders": return .faders
            case "knobs": return .knobs
            case "pads": return .pads
            case "keys": return .keys
            default: return .buttons
            }
        }
        let parts = spec.parts.map { p in
            GearPart(
                name: p.name, kind: kind(p.kind), center: [p.center[0], p.center[1]],
                size: [p.size[0], p.size[2], p.size[1]], travel: p.travel ?? 0)
        }
        let sections = spec.sections.map { s in
            GearSection(
                id: s.id, kind: sectionKind(s.kind), parts: s.parts, ccs: (s.ccs ?? []).map { UInt8(clamping: $0) })
        }
        var blueprint = GearBlueprint(
            id: spec.id, title: spec.title, size: [spec.size[0], spec.size[2], spec.size[1]],
            parts: parts, sections: sections)
        blueprint.bodyHeight = spec.body_height
        return blueprint
    }
}

// MARK: - 机の上の並び（`Gear/desk_layout.json` — アプリと Blender が両方読む）

struct DeskLayout {
    struct Entry {
        let id: String
        /// 機材の中心（机の mm）
        let center: CGPoint
        /// 上から見た外形（mm）
        let size: CGSize
        var elevation: Float = 0
        var yaw: Float = 0
        var height: Float? = nil
        var pose: GearPose { GearPose(origin: center, elevation: elevation, yaw: yaw) }
        var footprint: CGRect {
            pose.footprint(size: size)
        }

        func placing(_ blueprint: GearBlueprint) -> PlacedGear {
            PlacedGear(blueprint: blueprint, origin: center, elevation: elevation, yaw: yaw, height: height)
        }
    }
    struct Surface {
        let center: CGPoint
        let size: CGSize
        let elevation: Float
        let thickness: Float
        var footprint: CGRect {
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
    }
    let deskCenter: CGPoint
    let deskSize: CGSize
    let gear: [Entry]
    /// 仮想の部品の置き場（raw 値 → 机の mm）
    let tray: [String: CGPoint]
    let cameraFrom: SIMD3<Float>
    let cameraAt: SIMD3<Float>
    let fieldOfView: Float
    var surfaces: [Surface] = []
    var trayElevation: Float = 0
    var cameraUp: SIMD3<Float> = [0, 1, 0]
    var orthographicScale: Float? = nil
    var cameraScaleIsHorizontal = true
    var cameraAspectRatio: Float? = nil

    var supportSurfaces: [Surface] {
        surfaces.isEmpty ? [Surface(center: deskCenter, size: deskSize, elevation: 0, thickness: 10)] : surfaces
    }

    func trayPosition(_ component: VirtualComponent) -> SIMD3<Float> {
        let point = tray[component.rawValue] ?? CGPoint(x: component == .mixer ? -120 : 120, y: 115)
        return [Float(point.x) / 1000, trayElevation / 1000 + 0.004, Float(point.y) / 1000]
    }

    var deskRect: CGRect {
        CGRect(
            x: deskCenter.x - deskSize.width / 2, y: deskCenter.y - deskSize.height / 2,
            width: deskSize.width, height: deskSize.height)
    }

    private struct JSON: Decodable {
        struct Desk: Decodable { let center: [Double]; let size: [Double] }
        struct Gear: Decodable {
            let id: String; let center: [Double]; let size: [Double]
            let elevation: Float?; let yaw: Float?; let height: Float?
        }
        struct Surface: Decodable {
            let center: [Double]; let size: [Double]; let elevation: Float; let thickness: Float
        }
        struct Camera: Decodable {
            let from: [Float]; let at: [Float]; let fov: Float
            let up: [Float]?; let projection: String?; let orthographicScale: Float?; let scaleDirection: String?; let aspectRatio: Float?
        }
        let desk: Desk
        let gear: [Gear]
        let tray: [String: [Double]]
        let camera: Camera
        let surfaces: [Surface]?
        let trayElevation: Float?
    }

    static func decode(_ data: Data) throws -> DeskLayout {
        let j = try JSONDecoder().decode(JSON.self, from: data)
        let mm: ([Float]) -> SIMD3<Float> = { SIMD3($0[0], $0[1], $0[2]) / 1000 }
        return DeskLayout(
            deskCenter: CGPoint(x: j.desk.center[0], y: j.desk.center[1]),
            deskSize: CGSize(width: j.desk.size[0], height: j.desk.size[1]),
            gear: j.gear.map {
                Entry(id: $0.id, center: CGPoint(x: $0.center[0], y: $0.center[1]),
                      size: CGSize(width: $0.size[0], height: $0.size[1]),
                      elevation: $0.elevation ?? 0, yaw: $0.yaw ?? 0, height: $0.height)
            },
            tray: j.tray.mapValues { CGPoint(x: $0[0], y: $0[1]) },
            cameraFrom: mm(j.camera.from), cameraAt: mm(j.camera.at), fieldOfView: j.camera.fov,
            surfaces: (j.surfaces ?? []).map {
                Surface(center: CGPoint(x: $0.center[0], y: $0.center[1]), size: CGSize(width: $0.size[0], height: $0.size[1]),
                        elevation: $0.elevation, thickness: $0.thickness)
            },
            trayElevation: j.trayElevation ?? 0,
            cameraUp: j.camera.up.map { SIMD3($0[0], $0[1], $0[2]) } ?? [0, 1, 0],
            orthographicScale: j.camera.projection == "orthographic" ? j.camera.orthographicScale.map { $0 / 1000 } : nil,
            cameraScaleIsHorizontal: j.camera.scaleDirection != "vertical", cameraAspectRatio: j.camera.aspectRatio)
    }

    /// 並びが見つからないとき — nanoKONTROL2 だけを机の真ん中に
    static let fallback = DeskLayout(
        deskCenter: CGPoint(x: 0, y: 40), deskSize: CGSize(width: 900, height: 420),
        gear: [Entry(id: "nanokontrol", center: .zero, size: CGSize(width: 325, height: 83))],
        tray: ["mixer": CGPoint(x: -120, y: 115), "trackKnobs": CGPoint(x: 120, y: 115)],
        cameraFrom: [0, 0.33, 0.37], cameraAt: [0, 0.01, 0.045], fieldOfView: 40)
}
