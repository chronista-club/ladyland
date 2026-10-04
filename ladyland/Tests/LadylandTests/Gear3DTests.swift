//! 3D の机（mako 2026-10-04「ジャックの部分をフル 3D できっちりモデリングした
//! 機材を画面に出して、その上に例えばナノコントロール 2 の上にミキサーを置く
//! みたいな感じでコネクトできるようにしたい」、GO「やってみよう」）。
//!
//! 守りたい不変条件:
//!   - 機材の下書きは実寸（mm）。可動部は 1 本ずつ名前の付いた部品
//!     （Blender で清書しても同じ名前で掴める）
//!   - **載せられるか = Jack の契約**（Mixer はフェーダー × 8 の上にだけ載る）
//!   - 載せた部品が実機の CC の意味を決める（フェーダー → その Track の音量）

import Foundation
import Testing
import simd

@testable import Ladyland

@Suite("3D の机 — 機材の下書き")
struct GearBlueprintTests {
    let nano = GearBlueprint.nanoKontrol2

    @Test("外形は公称寸法 320 × 83 × 29 mm")
    func size() {
        #expect(nano.size == SIMD3<Float>(320, 29, 83))
    }

    @Test("可動部は名前付き — fader_1…8 / knob_1…8 / s・m・r_1…8")
    func parts() {
        let names = Set(nano.parts.map(\.name))
        for i in 1...8 {
            #expect(names.contains("fader_\(i)"))
            #expect(names.contains("knob_\(i)"))
            #expect(names.contains("s_\(i)"))
            #expect(names.contains("m_\(i)"))
            #expect(names.contains("r_\(i)"))
        }
        #expect(Set(nano.parts.map(\.name)).count == nano.parts.count, "名前は重複しない")
    }

    @Test("部品はすべて筐体の天面の内側")
    func partsInsideBody() {
        for part in nano.parts {
            #expect(abs(part.center.x) + part.size.x / 2 <= nano.size.x / 2, "\(part.name) が左右にはみ出す")
            #expect(abs(part.center.y) + part.size.z / 2 <= nano.size.z / 2, "\(part.name) が奥行きにはみ出す")
        }
    }

    @Test("セクション — フェーダー列は CC0-7、ノブ列は CC16-23（実測の CC 表）")
    func sections() {
        let faders = nano.sections.first { $0.kind == .faders }
        #expect(faders?.id == "nanokontrol.faders")
        #expect(faders?.ccs == Array(0...7).map(UInt8.init))
        #expect(faders?.parts == (1...8).map { "fader_\($0)" })
        let knobs = nano.sections.first { $0.kind == .knobs }
        #expect(knobs?.ccs == Array(16...23).map(UInt8.init))
    }

    @Test("セクションの足跡（mm）は自分の部品を全部含む")
    func footprint() throws {
        let faders = try #require(nano.sections.first { $0.kind == .faders })
        let rect = nano.footprint(of: faders)
        for name in faders.parts {
            let part = try #require(nano.parts.first { $0.name == name })
            #expect(rect.contains(CGPoint(x: CGFloat(part.center.x), y: CGFloat(part.center.y))))
        }
    }
}

@Suite("3D の机 — 載せられるか（Jack の契約）")
struct DockContractTests {
    let nano = GearBlueprint.nanoKontrol2

    @Test("Mixer はフェーダー × 8、Track ノブはノブ × 8 にだけ載る")
    func contract() throws {
        let faders = try #require(nano.sections.first { $0.kind == .faders })
        let knobs = try #require(nano.sections.first { $0.kind == .knobs })
        #expect(VirtualComponent.mixer.canDock(on: faders))
        #expect(!VirtualComponent.mixer.canDock(on: knobs))
        #expect(VirtualComponent.trackKnobs.canDock(on: knobs))
        #expect(!VirtualComponent.trackKnobs.canDock(on: faders))
    }

    @Test("落とした場所 → 載る先（机の座標 mm、機材の置き場所込み）")
    func dropTarget() {
        let placed = [PlacedGear(blueprint: nano, origin: CGPoint(x: 100, y: 50))]
        let faders = nano.sections.first { $0.kind == .faders }!
        let rect = nano.footprint(of: faders).offsetBy(dx: 100, dy: 50)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        #expect(DockModel.section(for: .mixer, at: center, gears: placed)?.id == "nanokontrol.faders")
        #expect(DockModel.section(for: .trackKnobs, at: center, gears: placed) == nil, "契約に合わない")
        #expect(DockModel.section(for: .mixer, at: CGPoint(x: -500, y: -500), gears: placed) == nil)
    }

    @Test("載せ替え — 1 つのセクションに部品は 1 つ、部品も 1 か所")
    func docking() {
        var docks: [String: String] = [:]
        docks = DockModel.docking(.mixer, on: "nanokontrol.faders", in: docks)
        #expect(docks == ["mixer": "nanokontrol.faders"])
        docks = DockModel.docking(.trackKnobs, on: "nanokontrol.knobs", in: docks)
        #expect(docks["trackKnobs"] == "nanokontrol.knobs")
        docks = DockModel.docking(.mixer, on: nil, in: docks)
        #expect(docks["mixer"] == nil, "外す")
        #expect(docks["trackKnobs"] == "nanokontrol.knobs")
    }

    @Test("raw 値は固定（window.json に入る）")
    func rawValues() {
        #expect(VirtualComponent.mixer.rawValue == "mixer")
        #expect(VirtualComponent.trackKnobs.rawValue == "trackKnobs")
    }
}

@Suite("3D の机 — 実機の CC → 載せた部品の操作")
struct SurfaceMappingTests {
    let bank = Array(8..<16)  // T9-16
    let docked = ["mixer": "nanokontrol.faders", "trackKnobs": "nanokontrol.knobs"]

    private func action(_ cc: UInt8, _ value: UInt8, docks: [String: String]? = nil, page: Int = 2)
        -> SurfaceAction?
    {
        SurfaceMapping.action(cc: cc, value: value, docks: docks ?? docked, bank: bank, page: page)
    }

    @Test("Mixer を載せたフェーダー i → バンクの i 本目の音量")
    func faders() {
        #expect(action(0, 127) == .gain(slot: 8, value: 1))
        #expect(action(7, 0) == .gain(slot: 15, value: 0))
    }

    @Test("Mixer を載せた列の M ボタン → ミュート切替（押したときだけ）")
    func mute() {
        #expect(action(48, 127) == .toggleMute(slot: 8))
        #expect(action(55, 127) == .toggleMute(slot: 15))
        #expect(action(48, 0) == nil, "離しは何もしない")
    }

    @Test("Track ノブを載せたノブ i → 現ページの席 i")
    func knobs() {
        #expect(action(16, 64) == .trackKnob(seat: 16, value: 64), "P3-1")
        #expect(action(23, 10) == .trackKnob(seat: 23, value: 10))
    }

    @Test("何も載っていなければ何もしない（音源へも流さない）")
    func undocked() {
        #expect(action(0, 127, docks: [:]) == nil)
        #expect(action(16, 64, docks: [:]) == nil)
        #expect(action(41, 127) == nil, "トランスポートは未配線")
    }

    @Test("バンクが 8 本に満たないときは在る分だけ")
    func shortBank() {
        let a = SurfaceMapping.action(cc: 5, value: 100, docks: docked, bank: [0, 1, 2], page: 0)
        #expect(a == nil)
    }

    @Test("接続表 — nanoKONTROL2 は専用の面（鍵盤扱いしない）")
    func route() {
        #expect(MIDIInput.route(forSourceName: "nanoKONTROL2 SLIDER/KNOB", hasKeystage: true) == .surface)
        #expect(MIDIInput.route(forSourceName: "nanoKONTROL2 SLIDER/KNOB", hasKeystage: false) == .surface)
    }

    @Test("window.json — docks を往復する（無い旧ファイルも読める）")
    func prefs() throws {
        var prefs = WindowPreferences.default
        prefs.docks = docked
        let back = try JSONDecoder().decode(
            WindowPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.docks == docked)
        let old = try JSONDecoder().decode(
            WindowPreferences.self, from: Data(#"{"mode":"windowed"}"#.utf8))
        #expect(old.docks == nil)
    }
}

@Suite("3D の机 — 指の位置を机の面へ")
struct DeskRayTests {
    @Test("光線と水平面 y = h の交点")
    func intersect() {
        let hit = Desk3DMath.intersect(origin: [0, 1, 1], direction: [0, -1, -1], planeY: 0)
        #expect(hit == SIMD3<Float>(0, 0, 0))
        let hit2 = Desk3DMath.intersect(origin: [0.2, 0.5, 0.5], direction: [0, -1, 0], planeY: 0.1)
        // Float の端数は許す（0.5 - 0.4 = 0.100000024）
        #expect(hit2.map { simd_distance($0, SIMD3<Float>(0.2, 0.1, 0.5)) < 1e-6 } == true)
    }

    @Test("面と平行・面から離れる光線は交わらない")
    func noHit() {
        #expect(Desk3DMath.intersect(origin: [0, 1, 0], direction: [1, 0, 0], planeY: 0) == nil)
        #expect(Desk3DMath.intersect(origin: [0, 1, 0], direction: [0, 1, 0], planeY: 0) == nil)
    }

    @Test("机の座標 m ⇄ mm（x はそのまま、z は CGPoint の y）")
    func millimeters() {
        #expect(Desk3DMath.millimeters([0.1, 0.03, -0.02]) == CGPoint(x: 100, y: -20))
    }
}

@Suite("3D の机 — フェーダーのつまみの位置")
struct FaderOffsetTests {
    @Test("音量 1 = 奥へ可動幅の半分、0 = 手前へ半分、0.5 = 真ん中")
    func offset() {
        let back = SIMD3<Float>(0, 0, -1)
        #expect(Desk3DMath.faderOffset(gain: 1, travel: 0.032, back: back) == SIMD3<Float>(0, 0, -0.016))
        #expect(Desk3DMath.faderOffset(gain: 0, travel: 0.032, back: back) == SIMD3<Float>(0, 0, 0.016))
        #expect(Desk3DMath.faderOffset(gain: 0.5, travel: 0.032, back: back) == .zero)
    }

    @Test("親が回っていても『奥』の向きに沿う（USDZ は外側が -90° 回っている）")
    func rotatedParent() {
        // Blender の座標のまま（y = 奥行き、手前が -y）— 奥は +y
        let back = SIMD3<Float>(0, 1, 0)
        #expect(Desk3DMath.faderOffset(gain: 1, travel: 0.032, back: back) == SIMD3<Float>(0, 0.016, 0))
    }
}
