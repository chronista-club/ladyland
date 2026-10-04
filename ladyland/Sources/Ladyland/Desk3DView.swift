//! 3D の机（RealityKit）— 実寸の機材の上に仮想の部品を載せて結線する。
//!
//! mako 2026-10-04「ジャックの部分をフル 3D できっちりモデリングした機材を画面に
//! 出して、その上に例えばナノコントロール 2 の上にミキサーを置くみたいな感じで
//! コネクトできるようにしたい」（GO「やってみよう」）。
//!
//! - **物理層** — `GearBlueprint` から組んだ下書き（箱・円柱）。
//!   `~/Library/Application Support/ladyland/gear/<id>.usdz` があれば
//!   そちらを使う（Blender で清書したもの。部品は同じ名前で掴む）
//! - **仮想の部品** — 半透明の板（Mixer / Track ノブ）。掴んで機材の上へ。
//!   **載せられるかは Jack の契約**（`DockModel`）。合わなければ手前の置き場へ戻る
//! - 載せた後は実機の操作子が部品の操作になる（`SurfaceMapping`）。机の上の
//!   フェーダーのつまみは**いまの音量**の位置に立つ（仮想層が物理の姿に重なる）
//!
//! 単位はメートル（下書きの mm ÷ 1000）。机の面が y = 0、奥が −z

import CreoUI
import RealityKit
import SwiftUI

/// 純関数（テスト対象）
enum Desk3DMath {
    /// 光線と水平面 y = planeY の交点（交わらなければ nil）
    static func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>, planeY: Float)
        -> SIMD3<Float>?
    {
        guard abs(direction.y) > 1e-6 else { return nil }
        let t = (planeY - origin.y) / direction.y
        guard t > 0 else { return nil }
        return origin + direction * t
    }

    /// 机の座標（m）→ 机の mm（CGPoint の y = z）。mm 単位に丸める
    static func millimeters(_ point: SIMD3<Float>) -> CGPoint {
        CGPoint(x: CGFloat((point.x * 1000).rounded()), y: CGFloat((point.z * 1000).rounded()))
    }
}

struct Desk3DView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState
    @State private var scene = Desk3DScene()

    var body: some View {
        RealityView { content in
            let root = await scene.build(theme: theme)
            content.add(root)
            scene.subscription = content.subscribe(to: SceneEvents.Update.self) { [weak appState] _ in
                guard let appState else { return }
                scene.tick(appState: appState)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .targetedToAnyEntity()
                .onChanged { value in
                    guard let component = Desk3DScene.component(of: value.entity),
                        let ray = value.ray(through: value.location, in: .local, to: .scene),
                        let hit = Desk3DMath.intersect(
                            origin: ray.origin, direction: ray.direction, planeY: Desk3DScene.hoverY)
                    else { return }
                    scene.drag(component, to: hit)
                }
                .onEnded { value in
                    guard let component = Desk3DScene.component(of: value.entity) else { return }
                    let point = scene.dragPoint(component).map(Desk3DMath.millimeters)
                    let section = point.flatMap {
                        DockModel.section(for: component, at: $0, gears: scene.placedGears)
                    }
                    appState.windowPlacement.setDock(component, on: section?.id)
                    scene.endDrag(component)
                }
        )
        .overlay(alignment: .bottomLeading) {
            Text("部品を掴んで機材の上へ。合う場所にだけ載る（外すときは手前へ）")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .padding(CreoUITokens.spacingS)
        }
    }
}

/// シーンの持ち物（エンティティの参照・ドラッグ中の状態）。View の再評価を
/// またいで同じものを指すよう `@State` で 1 つだけ持つ
@MainActor
final class Desk3DScene {
    /// 部品が浮く高さ（m）— 機材の天面より上
    static let hoverY: Float = 0.045
    /// 机に置いた機材（いまは nanoKONTROL2 だけ。机座標 mm の中心）
    let placedGears = [PlacedGear(blueprint: .nanoKontrol2, origin: CGPoint(x: 0, y: 0))]

    var subscription: EventSubscription?
    private var root = Entity()
    /// 部品名 → エンティティ（フェーダーのつまみ・M ボタン）と、つまみの初期位置
    private var parts: [String: Entity] = [:]
    private var partHome: [String: SIMD3<Float>] = [:]
    private var buttonMaterials: (normal: any RealityKit.Material, lit: any RealityKit.Material)?
    private var components: [VirtualComponent: Entity] = [:]
    /// M ボタンの元の材質（清書した USDZ の材質に戻すため）
    private var muteNormal: [Int: [any RealityKit.Material]] = [:]

    /// 名前付き部品の「形」— USDZ では入れ物（Xform）の子に形（Mesh）が付く
    static func model(of entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity { return model }
        for child in entity.children {
            if let found = model(of: child) { return found }
        }
        return nil
    }
    private var dragging: [VirtualComponent: SIMD3<Float>] = [:]

    // MARK: - 組み立て

    func build(theme: CreoTheme) async -> Entity {
        root = Entity()
        root.name = "desk3d"
        let lit = SimpleMaterial(color: NSColor(theme.semanticError), roughness: 0.4, isMetallic: false)
        buttonMaterials = (lit, lit)

        // 机の面
        let desk = ModelEntity(
            mesh: .generateBox(width: 0.9, height: 0.01, depth: 0.42, cornerRadius: 0.004),
            materials: [SimpleMaterial(color: NSColor(theme.surfaceBgSubtle), roughness: 0.9, isMetallic: false)])
        desk.position = [0, -0.005, 0.04]
        root.addChild(desk)

        // 機材
        for gear in placedGears {
            let entity = await gearEntity(gear.blueprint, theme: theme)
            entity.position = [Float(gear.origin.x) / 1000, 0, Float(gear.origin.y) / 1000]
            root.addChild(entity)
        }

        // 仮想の部品
        for component in VirtualComponent.allCases {
            let entity = componentEntity(component, theme: theme)
            components[component] = entity
            root.addChild(entity)
        }

        // 光とカメラ（斜め上から見下ろす）
        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.look(at: [0, 0, 0], from: [0.3, 0.8, 0.5], relativeTo: nil)
        root.addChild(sun)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 40
        camera.look(at: [0, 0, 0.03], from: [0, 0.42, 0.46], relativeTo: nil)
        root.addChild(camera)
        return root
    }

    /// 機材 1 台 — 清書した USDZ があればそれ、無ければ下書きから組む
    private func gearEntity(_ blueprint: GearBlueprint, theme: CreoTheme) async -> Entity {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ladyland/gear/\(blueprint.id).usdz")
        if FileManager.default.fileExists(atPath: url.path),
            let loaded = try? await Entity(contentsOf: url)
        {
            loaded.name = blueprint.id
            for part in blueprint.parts {
                if let found = loaded.findEntity(named: part.name) {
                    parts[part.name] = found
                    partHome[part.name] = found.position
                }
            }
            return loaded
        }
        return draftEntity(blueprint, theme: theme)
    }

    /// 下書き（実寸の箱・円柱。名前は部品名）
    private func draftEntity(_ blueprint: GearBlueprint, theme: CreoTheme) -> Entity {
        let mm: (Float) -> Float = { $0 / 1000 }
        let gear = Entity()
        gear.name = blueprint.id
        let body = ModelEntity(
            mesh: .generateBox(
                width: mm(blueprint.size.x), height: mm(blueprint.size.y), depth: mm(blueprint.size.z),
                cornerRadius: 0.002),
            materials: [SimpleMaterial(color: NSColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: true)])
        body.position = [0, mm(blueprint.size.y) / 2, 0]
        gear.addChild(body)

        let top = mm(blueprint.size.y)
        let dark = SimpleMaterial(color: NSColor(white: 0.05, alpha: 1), roughness: 0.8, isMetallic: false)
        let cap = SimpleMaterial(color: NSColor(white: 0.85, alpha: 1), roughness: 0.4, isMetallic: false)
        let button = SimpleMaterial(color: NSColor(white: 0.32, alpha: 1), roughness: 0.5, isMetallic: false)
        let lit = SimpleMaterial(color: NSColor(theme.semanticError), roughness: 0.4, isMetallic: false)
        buttonMaterials = (button, lit)

        for part in blueprint.parts {
            let center: SIMD3<Float> = [mm(part.center.x), top, mm(part.center.y)]
            let entity: ModelEntity
            switch part.kind {
            case .fader:
                // 溝（動かない）+ つまみ（名前付き）
                let slot = ModelEntity(
                    mesh: .generateBox(width: 0.003, height: 0.001, depth: mm(part.travel + part.size.z)),
                    materials: [dark])
                slot.position = center + [0, 0.0005, 0]
                gear.addChild(slot)
                entity = ModelEntity(
                    mesh: .generateBox(
                        width: mm(part.size.x), height: mm(part.size.y), depth: mm(part.size.z),
                        cornerRadius: 0.001),
                    materials: [cap])
                entity.position = center + [0, mm(part.size.y) / 2, 0]
            case .knob:
                entity = ModelEntity(
                    mesh: .generateCylinder(height: mm(part.size.y), radius: mm(part.size.x) / 2),
                    materials: [cap])
                entity.position = center + [0, mm(part.size.y) / 2, 0]
            case .button:
                entity = ModelEntity(
                    mesh: .generateBox(
                        width: mm(part.size.x), height: mm(part.size.y), depth: mm(part.size.z),
                        cornerRadius: 0.0008),
                    materials: [button])
                entity.position = center + [0, mm(part.size.y) / 2, 0]
            }
            entity.name = part.name
            gear.addChild(entity)
            parts[part.name] = entity
            partHome[part.name] = entity.position
        }
        return gear
    }

    /// 仮想の部品 — 半透明に光る板 + 名前。掴めるように当たりを持たせる
    private func componentEntity(_ component: VirtualComponent, theme: CreoTheme) -> Entity {
        let color: NSColor = NSColor(component == .mixer ? theme.brandPrimary : theme.semanticInfo)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = 0.6
        material.blending = .transparent(opacity: .init(floatLiteral: 0.45))

        let size: SIMD3<Float> = component == .mixer ? [0.22, 0.004, 0.05] : [0.22, 0.004, 0.022]
        let plate = ModelEntity(
            mesh: .generateBox(size: size, cornerRadius: 0.002), materials: [material])
        plate.name = "virtual.\(component.rawValue)"
        plate.components.set(CollisionComponent(shapes: [.generateBox(size: size + [0, 0.01, 0])]))
        plate.components.set(InputTargetComponent())

        let label = ModelEntity(
            mesh: .generateText(
                component.title, extrusionDepth: 0.0004, font: .systemFont(ofSize: 0.011)),
            materials: [UnlitMaterial(color: .white)])
        label.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        label.position = [-size.x / 2 + 0.004, size.y / 2 + 0.0005, size.z / 2 - 0.004]
        plate.addChild(label)
        return plate
    }

    // MARK: - 毎フレーム

    /// 載せた場所へ部品を置き、フェーダーのつまみを音量の位置へ、M を点ける
    func tick(appState: AppState) {
        let docks = appState.windowPlacement.docks ?? [:]
        for (component, entity) in components {
            if let point = dragging[component] {
                entity.position = point
                continue
            }
            entity.position = restingPosition(component, docks: docks)
        }

        let bank = MixerModel.bankIndices(
            selected: appState.rack.selected, trackCount: appState.rack.slots.count)
        let mixerOnFaders = docks[VirtualComponent.mixer.rawValue] == "nanokontrol.faders"
        for (i, n) in (1...8).enumerated() {
            let slot = bank.indices.contains(i) ? appState.rack.slots[bank[i]] : nil
            // フェーダー — Mixer が載っていればその Track の音量の位置（上 = 奥）
            if let fader = parts["fader_\(n)"], let home = partHome["fader_\(n)"] {
                let travel = Float(0.032)
                let gain = mixerOnFaders ? (slot?.gain ?? 0) : 0.5
                fader.position = home + [0, 0, (0.5 - gain) * travel]
            }
            // M — ミュート中は赤
            if let mute = parts["m_\(n)"].flatMap(Self.model(of:)) {
                let lit = mixerOnFaders && (slot?.mute ?? false)
                if muteNormal[n] == nil { muteNormal[n] = mute.model?.materials }
                if lit, let red = buttonMaterials?.lit {
                    mute.model?.materials = [red]
                } else if let normal = muteNormal[n] {
                    mute.model?.materials = normal
                }
            }
        }
    }

    /// 部品の置き場 — 載っていればそのセクションの真上、無ければ手前の置き場
    private func restingPosition(_ component: VirtualComponent, docks: [String: String]) -> SIMD3<Float> {
        if let id = docks[component.rawValue],
            let gear = placedGears.first(where: { g in g.blueprint.sections.contains { $0.id == id } }),
            let section = gear.blueprint.sections.first(where: { $0.id == id })
        {
            let rect = gear.blueprint.footprint(of: section)
                .offsetBy(dx: gear.origin.x, dy: gear.origin.y)
            return [Float(rect.midX) / 1000, Self.hoverY, Float(rect.midY) / 1000]
        }
        let tray: Float = component == .mixer ? -0.13 : 0.13
        return [tray, 0.004, 0.17]
    }

    // MARK: - ドラッグ

    static func component(of entity: Entity) -> VirtualComponent? {
        var current: Entity? = entity
        while let e = current {
            if e.name.hasPrefix("virtual."),
                let c = VirtualComponent(rawValue: String(e.name.dropFirst("virtual.".count)))
            {
                return c
            }
            current = e.parent
        }
        return nil
    }

    func drag(_ component: VirtualComponent, to point: SIMD3<Float>) {
        dragging[component] = point
    }

    func dragPoint(_ component: VirtualComponent) -> SIMD3<Float>? {
        dragging[component]
    }

    func endDrag(_ component: VirtualComponent) {
        dragging[component] = nil
    }
}
