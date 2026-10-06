//! 3D の机に全部載せる（mako 2026-10-05「3D の机に全部載せて」）。
//!
//! 守りたい不変条件:
//!   - 並び（`Gear/desk_layout.json`）は 8 台を重ならずに机の上へ置く
//!   - Blender が書き出す配置データ（JSON）から部品とセクションを読める
//!   - Track ノブは 8 本以上のノブ列ならどの機材にも載る。LPD8 のノブ列に
//!     載せた / 外したときだけ、LPD8 のノブの刺し先も切り替わる

import Foundation
import CreoUI
import RealityKit
import Testing
import simd

@testable import Ladyland

private let repoGear = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Gear")

@Suite("3D の机 — 並び")
struct DeskLayoutModelTests {
    let layout = try! DeskLayout.decode(Data(contentsOf: repoGear.appendingPathComponent("desk_layout.json")))

    @Test("8 台が並ぶ")
    func gears() {
        #expect(Set(layout.gear.map(\.id)) == ["roto", "nanokontrol", "lpd8", "minilab", "fgdp50", "keystage", "ncxse", "xtouch"])
    }

    @Test("どの 2 台も重ならず、全部机の上")
    func noOverlap() {
        let rects = layout.gear.map { ($0.id, $0.footprint) }
        for i in rects.indices {
            #expect(layout.supportSurfaces.contains { abs($0.elevation - layout.gear[i].elevation) < 0.1 && $0.footprint.insetBy(dx: -0.1, dy: -0.1).contains(rects[i].1) }, "\(rects[i].0) が机からはみ出す")
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

@Suite("3D の studio — 棚と向き")
struct StudioLayoutTests {
    static let json = #"""
    {"desk":{"center":[0,0],"size":[2400,1800]},
     "gear":[{"id":"nanokontrol","center":[-1025,20],"size":[325,83],
              "elevation":740,"yaw":90}],
     "tray":{"mixer":[0,-680],"trackKnobs":[250,-680]},"trayElevation":850,
     "camera":{"from":[0,2200,2300],"at":[0,740,0],"fov":40,
               "projection":"orthographic","orthographicScale":2800}}
    """#

    @Test("横向きの機材は幅と奥行きが入れ替わる")
    func rotatedFootprint() throws {
        let entry = try #require(DeskLayout.decode(Data(Self.json.utf8)).gear.first)
        #expect(abs(entry.footprint.width - 83) < 0.001)
        #expect(abs(entry.footprint.height - 325) < 0.001)
        #expect(entry.footprint.midX == -1025)
        #expect(entry.footprint.midY == 20)
    }

    @Test("高さ・カメラ・仮想部品の置き場を読み込む")
    func elevations() throws {
        let layout = try DeskLayout.decode(Data(Self.json.utf8))
        #expect(layout.gear[0].pose.position == SIMD3<Float>(-1.025, 0.74, 0.02))
        #expect(layout.orthographicScale == 2.8)
        #expect(simd_distance(layout.trayPosition(.mixer), [0, 0.854, -0.68]) < 1e-6)
    }

    @Test("旧配置の高さと回転は 0、透視投影のまま")
    func legacy() throws {
        let json = #"""
        {"desk":{"center":[0,0],"size":[900,420]},
         "gear":[{"id":"nanokontrol","center":[0,0],"size":[325,83]}],
         "tray":{"mixer":[0,115]},"camera":{"from":[0,330,370],"at":[0,10,45],"fov":40}}
        """#
        let layout = try DeskLayout.decode(Data(json.utf8))
        #expect(layout.gear[0].pose.position == .zero)
        #expect(layout.gear[0].yaw == 0)
        #expect(layout.orthographicScale == nil)
        #expect(layout.supportSurfaces[0].elevation == 0)
        #expect(layout.trayPosition(.mixer).y == 0.004)
    }

    @Test("回転後のノブ列を狙うと載る。回転前の場所には載らない")
    func rotatedDock() throws {
        let entry = try DeskLayout.decode(Data(Self.json.utf8)).gear[0]
        let gear = entry.placing(.nanoKontrol2)
        let knobs = try #require(gear.blueprint.sections.first { $0.kind == .knobs })
        let local = CGPoint(x: 100, y: -27.3)
        let world = gear.pose.worldPoint(local)
        #expect(DockModel.section(for: .trackKnobs, at: world, gears: [gear]) == knobs)
        let unrotated = CGPoint(x: gear.origin.x + local.x, y: gear.origin.y + local.y)
        #expect(DockModel.section(for: .trackKnobs, at: unrotated, gears: [gear]) == nil)
        let inverse = gear.pose.localPoint(world)
        #expect(abs(inverse.x - local.x) < 0.001 && abs(inverse.y - local.y) < 0.001)
    }

    @Test("高い棚の回転したノブ列へ光線を投影する")
    func raisedDrop() throws {
        let gear = try DeskLayout.decode(Data(Self.json.utf8)).gear[0].placing(.nanoKontrol2)
        let point = gear.pose.worldPoint(CGPoint(x: 100, y: -27.3))
        let origin = SIMD3<Float>(Float(point.x) / 1000, 2, Float(point.y) / 1000)
        let target = try #require(Desk3DMath.dropTarget(for: .trackKnobs, origin: origin, direction: [0, -1, 0], gears: [gear]))
        #expect(target.section.id == "nanokontrol.knobs")
        #expect(abs(target.point.y - gear.top) < 1e-6)
        #expect(Desk3DMath.dropTarget(for: .trackKnobs, origin: [5, 2, 5], direction: [0, -1, 0], gears: [gear]) == nil)
    }

    @MainActor @Test("書き出した studio の実資産が高さ・回転・操作子を保つ")
    func exportedAssets() async throws {
        guard let path = ProcessInfo.processInfo.environment["LADYLAND_STUDIO_ASSETS"] else { return }
        let scene = Desk3DScene(gearDirectory: URL(fileURLWithPath: path))
        let root = await scene.build(theme: .mintDark)
        #expect(root.findEntity(named: "environment") != nil)
        for entry in scene.layout.gear {
            let entity = try #require(root.findEntity(named: entry.id))
            let bounds = entity.visualBounds(relativeTo: root)
            #expect(abs(bounds.min.y - entry.elevation / 1000) < 0.002)
            #expect(abs(bounds.extents.x - Float(entry.footprint.width) / 1000) < 0.003)
            #expect(abs(bounds.extents.z - Float(entry.footprint.height) / 1000) < 0.003)
        }
        let nano = try #require(root.findEntity(named: "nanokontrol"))
        #expect(nano.findEntity(named: "fader_1") != nil)
        #expect(nano.findEntity(named: "m_1") != nil)
    }

    @MainActor @Test("RealityKit の機材・帯・カメラも棚の高さと向きを保つ")
    func scenePose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.json.utf8).write(to: directory.appendingPathComponent("desk_layout.json"))
        let scene = Desk3DScene(gearDirectory: directory)
        let root = await scene.build(theme: .mintDark)
        let gear = try #require(root.findEntity(named: "nanokontrol"))
        #expect(simd_distance(gear.position, [-1.025, 0.74, 0.02]) < 1e-5)
        #expect(simd_distance(gear.orientation.act([0, 0, -1]), [-1, 0, 0]) < 1e-5)
        let camera = try #require(root.children.first { $0.components[OrthographicCameraComponent.self] != nil })
        #expect(camera.components[OrthographicCameraComponent.self]?.scale == 2.8)
        let tray = try #require(root.findEntity(named: "virtual.mixer"))
        #expect(abs(tray.position.y - 0.854) < 1e-5)
        let wrap = try #require(scene.wrapEntity(.mixer, section: "nanokontrol.faders"))
        let bounds = wrap.visualBounds(relativeTo: nil)
        #expect(bounds.min.y >= 0.739 && bounds.max.y < 0.79, "帯は床から伸ばさず、機材だけを包む")
        #expect(bounds.extents.x < 0.1 && bounds.extents.z > 0.32, "帯も機材と一緒に回転する")
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

    @Test("X-TOUCH は 8 チャンネルと独立したマスターフェーダーを持つ")
    func xtouch() throws {
        let b = try GearBlueprint.decode(Data(contentsOf: repoGear.appendingPathComponent("xtouch.json")))
        #expect(b.size == SIMD3<Float>(452, 100, 301))
        #expect(b.parts.filter { $0.kind == .fader }.count == 9)
        #expect(b.parts.filter { $0.kind == .fader }.allSatisfy { $0.travel == 100 })
        #expect(b.sections.first { $0.id == "xtouch.faders" }?.parts.count == 8)
        #expect(b.sections.first { $0.id == "xtouch.encoders" }?.parts.count == 8)
        #expect(b.sections.allSatisfy { $0.ccs.isEmpty }, "MCU の制御を汎用 CC として捏造しない")
    }

    @Test("repo の配置データは全部読める")
    func repoFiles() throws {
        for id in ["lpd8", "keystage", "roto", "fgdp50", "ncxse", "minilab", "xtouch"] {
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
