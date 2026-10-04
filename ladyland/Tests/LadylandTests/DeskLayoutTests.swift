//! 3D の机に全部載せる（mako 2026-10-05「3D の机に全部載せて」）。
//!
//! 守りたい不変条件:
//!   - 並び（`Gear/desk_layout.json`）は 7 台を重ならずに机の上へ置く
//!   - Blender が書き出す配置データ（JSON）から部品とセクションを読める
//!   - Track ノブは 8 本以上のノブ列ならどの機材にも載る。LPD8 のノブ列に
//!     載せた / 外したときだけ、LPD8 のノブの刺し先も切り替わる

import Foundation
import Testing

@testable import Ladyland

private let repoGear = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Gear")

@Suite("3D の机 — 並び")
struct DeskLayoutModelTests {
    let layout = try! DeskLayout.decode(Data(contentsOf: repoGear.appendingPathComponent("desk_layout.json")))

    @Test("7 台が並ぶ")
    func gears() {
        #expect(Set(layout.gear.map(\.id)) == ["roto", "nanokontrol", "lpd8", "minilab", "fgdp50", "keystage", "ncxse"])
    }

    @Test("どの 2 台も重ならず、全部机の上")
    func noOverlap() {
        let rects = layout.gear.map { ($0.id, $0.footprint) }
        for i in rects.indices {
            #expect(layout.deskRect.contains(rects[i].1), "\(rects[i].0) が机からはみ出す")
            for j in rects.indices where j > i {
                #expect(!rects[i].1.intersects(rects[j].1), "\(rects[i].0) と \(rects[j].0) が重なる")
            }
        }
    }

    @Test("部品の置き場は機材と重ならない")
    func trayIsFree() {
        for (_, point) in layout.tray {
            let spot = CGRect(x: point.x - 110, y: point.y - 25, width: 220, height: 50)
            #expect(!layout.gear.contains { $0.footprint.intersects(spot) })
        }
    }
}

@Suite("3D の机 — Blender の配置データを読む")
struct GearBlueprintJSONTests {
    @Test("部品の種類とセクションを読み替える")
    func decode() throws {
        let json = #"""
        {"id": "x", "title": "X", "size": [300, 100, 40], "body_height": 18,
         "parts": [{"name": "knob_1", "kind": "knob", "center": [1, 2], "size": [12, 12, 10]},
                   {"name": "enc_1", "kind": "encoder", "center": [3, 4], "size": [16, 16, 14]},
                   {"name": "pad_1", "kind": "pad", "center": [5, 6], "size": [25, 25, 3]},
                   {"name": "key_60", "kind": "key_white", "center": [7, 8], "size": [22, 140, 12]},
                   {"name": "drawbar_1", "kind": "fader", "center": [9, 10], "size": [14, 8, 10], "travel": 34},
                   {"name": "lcd", "kind": "display", "center": [0, 0], "size": [30, 10, 1]}],
         "sections": [{"id": "x.knobs", "kind": "knobs", "parts": ["knob_1"], "ccs": [16]},
                      {"id": "x.pads", "kind": "pads", "parts": ["pad_1"]}]}
        """#
        let b = try GearBlueprint.decode(Data(json.utf8))
        #expect(b.id == "x")
        #expect(b.size == SIMD3<Float>(300, 40, 100), "JSON は W D H、内部は x y(高さ) z")
        #expect(b.bodyHeight == 18)
        #expect(b.parts.first { $0.name == "knob_1" }?.kind == .knob)
        #expect(b.parts.first { $0.name == "enc_1" }?.kind == .knob)
        #expect(b.parts.first { $0.name == "pad_1" }?.kind == .pad)
        #expect(b.parts.first { $0.name == "key_60" }?.kind == .key)
        #expect(b.parts.first { $0.name == "drawbar_1" }?.travel == 34)
        #expect(b.parts.first { $0.name == "lcd" }?.kind == .other)
        #expect(b.parts.first { $0.name == "knob_1" }?.size == SIMD3<Float>(12, 10, 12), "w d h → x y z")
        #expect(b.sections.first { $0.id == "x.knobs" }?.ccs == [16])
        #expect(b.sections.first { $0.id == "x.pads" }?.kind == .pads)
    }

    @Test("repo の配置データは全部読める")
    func repoFiles() throws {
        for id in ["lpd8", "keystage", "roto", "fgdp50", "ncxse", "minilab"] {
            let b = try GearBlueprint.decode(Data(contentsOf: repoGear.appendingPathComponent("\(id).json")))
            #expect(b.id == id)
            #expect(!b.sections.isEmpty)
        }
    }
}

@Suite("3D の机 — どの機材にも載る")
struct DockAnyGearTests {
    private func knobs(_ id: String, count: Int) -> GearSection {
        GearSection(id: id, kind: .knobs, parts: (1...count).map { "knob_\($0)" }, ccs: [])
    }

    @Test("Track ノブは 8 本以上のノブ列に載る（CC の表が無くても）")
    func trackKnobs() {
        #expect(VirtualComponent.trackKnobs.canDock(on: knobs("keystage.knobs", count: 8)))
        #expect(VirtualComponent.trackKnobs.canDock(on: knobs("minilab.encoders", count: 16)))
        #expect(!VirtualComponent.trackKnobs.canDock(on: knobs("tiny.knobs", count: 4)))
    }

    @Test("LPD8 のノブ列に載せた / 外したときだけ刺し先が変わる")
    func lpd8Jack() {
        #expect(DockModel.lpd8Jack(before: nil, after: "lpd8.knobs") == .face)
        #expect(DockModel.lpd8Jack(before: "lpd8.knobs", after: nil) == .drums)
        #expect(DockModel.lpd8Jack(before: "lpd8.knobs", after: "keystage.knobs") == .drums)
        #expect(DockModel.lpd8Jack(before: nil, after: "keystage.knobs") == nil, "LPD8 に関係なければ触らない")
    }
}
