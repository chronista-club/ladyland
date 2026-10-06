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
//! 単位はメートル（下書きの mm ÷ 1000）。Y が高さ、奥が −Z。

import CreoUI
import ImageIO
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

    /// フェーダーのつまみのずれ — 音量 1 で奥へ可動幅の半分、0 で手前へ半分。
    /// `back` は**親の座標での「奥」の向き**（USDZ は外側の入れ物が -90° 回って
    /// いて、部品の中の座標は Blender のまま — z を動かすと上下に動いてしまう。
    /// 実機 2026-10-04 mako「フェーダーが上下逆だね」）
    static func faderOffset(gain: Float, travel: Float, back: SIMD3<Float>) -> SIMD3<Float> {
        back * ((gain - 0.5) * travel)
    }

    /// 帯の 1 枚（中心と大きさ、机の座標 m）
    struct SleeveFrame: Equatable {
        var center: SIMD3<Float>
        var size: SIMD3<Float>
    }

    /// 載せた部品で機材のセクションを**包む**帯（mako 2026-10-04「サンドイッチ
    /// みたいな感じかな。WRAP するというか」）— 上の板・下の板・左右の壁。
    /// 幅はセクションの足跡 + 余白、奥行きは機材の奥行き + 余白（前後に抜けて
    /// 見える）、高さは天面 + 余白
    static func sleeve(
        section: CGRect, gearMinZ: Float, gearMaxZ: Float, top: Float,
        margin: Float = 0.005, thickness: Float = 0.0015
    ) -> [String: SleeveFrame] {
        let minX = Float(section.minX) / 1000 - margin
        let maxX = Float(section.maxX) / 1000 + margin
        let minZ = gearMinZ - margin
        let maxZ = gearMaxZ + margin
        let width = maxX - minX
        let depth = maxZ - minZ
        let height = top + margin
        let cx = (minX + maxX) / 2
        let cz = (minZ + maxZ) / 2
        return [
            "top": SleeveFrame(center: [cx, height, cz], size: [width, thickness, depth]),
            "bottom": SleeveFrame(center: [cx, thickness / 2, cz], size: [width, thickness, depth]),
            "left": SleeveFrame(center: [minX, height / 2, cz], size: [thickness, height, depth]),
            "right": SleeveFrame(center: [maxX, height / 2, cz], size: [thickness, height, depth]),
        ]
    }

    /// 机の座標（m）→ 机の mm（CGPoint の y = z）。mm 単位に丸める
    static func millimeters(_ point: SIMD3<Float>) -> CGPoint {
        CGPoint(x: CGFloat((point.x * 1000).rounded()), y: CGFloat((point.z * 1000).rounded()))
    }

    /// 高さの違う棚へ同じ水平面で投影すると、見えている操作子からドロップがずれる。
    /// 各機材の天面へ投影し、手前の載せ先を選ぶ。
    static func dropTarget(
        for component: VirtualComponent, origin: SIMD3<Float>, direction: SIMD3<Float>, gears: [PlacedGear]
    ) -> (section: GearSection, point: SIMD3<Float>)? {
        gears.compactMap { gear -> (section: GearSection, point: SIMD3<Float>)? in
            guard let hit = intersect(origin: origin, direction: direction, planeY: gear.top),
                  let section = DockModel.section(for: component, at: millimeters(hit), gears: [gear])
            else { return nil }
            return (section, hit)
        }.min { simd_length_squared($0.point - origin) < simd_length_squared($1.point - origin) }
    }
}

struct Desk3DView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState
    @State private var scene = Desk3DScene()

    var body: some View {
        RealityView { [weak appState] content in
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
                        let ray = value.ray(through: value.location, in: .local, to: .scene)
                    else { return }
                    scene.drag(component, origin: ray.origin, direction: ray.direction)
                }
                .onEnded { value in
                    guard let component = Desk3DScene.component(of: value.entity) else { return }
                    let section = scene.dragSection(component)
                    let before = appState.windowPlacement.docks?[component.rawValue]
                    appState.windowPlacement.setDock(component, on: section)
                    // LPD8 のノブ列に Track ノブを載せる = LPD8 のノブを Track ノブへ刺す
                    if component == .trackKnobs,
                        let jack = DockModel.lpd8Jack(before: before, after: section)
                    {
                        appState.lpd8KnobJack = jack
                    }
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
    private let assetDirectory: URL

    init(gearDirectory: URL = Desk3DScene.gearDirectory) {
        assetDirectory = gearDirectory
    }
    /// 机の上の並び（`Gear/desk_layout.json` の写し。無ければ nanoKONTROL2 だけ）
    private(set) var layout = DeskLayout.fallback
    /// 机に置いた機材（机座標 mm での中心）
    private(set) var placedGears: [PlacedGear] = []

    var subscription: EventSubscription?
    private var root = Entity()
    private var theme: CreoTheme?
    /// 「機材 id / 部品名」→ エンティティ（フェーダーのつまみ・M ボタン）と初期位置。
    /// 部品名（knob_1 など）は機材をまたいで重なるので、機材 id を前に付ける
    private var parts: [String: Entity] = [:]
    private var partHome: [String: SIMD3<Float>] = [:]
    private var buttonMaterials: (normal: any RealityKit.Material, lit: any RealityKit.Material)?
    private var components: [VirtualComponent: Entity] = [:]
    /// 部品ごとの 2 つの姿 — 平たい板（置き場・掴み中）と帯（載ったとき。載った先ごとに作る）
    private var flats: [VirtualComponent: Entity] = [:]
    private var wraps: [VirtualComponent: (entity: Entity, section: String)] = [:]
    /// 機材の外形（机の座標 m）— 帯の寸法と浮く高さに使う
    private var gearBounds: [String: BoundingBox] = [:]
    private var gearEntities: [String: Entity] = [:]
    /// M ボタンの元の材質（清書した USDZ の材質に戻すため）
    private var muteNormal: [Int: [any RealityKit.Material]] = [:]
    private var light: Entity?

    /// 名前付き部品の「形」— USDZ では入れ物（Xform）の子に形（Mesh）が付く
    static func model(of entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity { return model }
        for child in entity.children {
            if let found = model(of: child) { return found }
        }
        return nil
    }
    private var dragging: [VirtualComponent: SIMD3<Float>] = [:]
    private var dragTargets: [VirtualComponent: String] = [:]

    // MARK: - 組み立て

    /// 机に置く機材を集める — nanoKONTROL2 は下書き（Swift）、ほかは Blender の配置データ
    static func catalog(at directory: URL = gearDirectory) -> [String: GearBlueprint] {
        var all: [String: GearBlueprint] = ["nanokontrol": .nanoKontrol2]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && url.lastPathComponent != "desk_layout.json" {
            if let data = try? Data(contentsOf: url), let blueprint = try? GearBlueprint.decode(data) {
                all[blueprint.id] = blueprint
            }
        }
        return all
    }

    func build(theme: CreoTheme) async -> Entity {
        self.theme = theme
        root = Entity()
        root.name = "desk3d"
        let lit = SimpleMaterial(color: NSColor(theme.semanticError), roughness: 0.4, isMetallic: false)
        buttonMaterials = (lit, lit)

        if let data = try? Data(contentsOf: assetDirectory.appendingPathComponent("desk_layout.json")),
            let loaded = try? DeskLayout.decode(data)
        {
            layout = loaded
        }
        let catalog = Self.catalog(at: assetDirectory)
        placedGears = layout.gear.compactMap { entry in
            catalog[entry.id].map { entry.placing($0) }
        }

        // 机の面 — Blender で仕上げた机（接地の暗がり入り）があればそれ
        if let desk = try? await Entity(contentsOf: assetDirectory.appendingPathComponent("desk.usdz")) {
            root.addChild(desk)
        } else {
            for surface in layout.supportSurfaces {
                let desk = ModelEntity(
                    mesh: .generateBox(
                        width: Float(surface.size.width) / 1000, height: surface.thickness / 1000,
                        depth: Float(surface.size.height) / 1000, cornerRadius: 0.004),
                    materials: [SimpleMaterial(color: NSColor(theme.surfaceBgSubtle), roughness: 0.9, isMetallic: false)])
                desk.position = [Float(surface.center.x) / 1000, (surface.elevation - surface.thickness / 2) / 1000,
                                 Float(surface.center.y) / 1000]
                root.addChild(desk)
            }
        }

        // 機材
        for gear in placedGears {
            // USDZ 自体の軸変換は内側に保ち、アプリでの配置は外側で一度だけ掛ける。
            let model = await gearEntity(gear.blueprint, theme: theme)
            let entity = Entity()
            entity.name = gear.blueprint.id
            model.name = "model"
            entity.addChild(model)
            entity.position = gear.pose.position
            entity.orientation = simd_quatf(angle: gear.pose.radians, axis: [0, 1, 0])
            root.addChild(entity)
            gearEntities[gear.blueprint.id] = entity
            gearBounds[gear.blueprint.id] = entity.visualBounds(relativeTo: entity)
        }

        // 仮想の部品
        for component in VirtualComponent.allCases {
            let entity = componentEntity(component, theme: theme)
            components[component] = entity
            entity.position = restingPosition(component)
            root.addChild(entity)
        }

        // 光 — **見た目は Blender で決める**（mako 2026-10-04「見た目の雰囲気は、ここで
        // しっかり落とし込む。各クライアントは微調整くらい」）。Blender が書いた
        // 環境マップで照らし、こちらで足すのは明るさの微調整（`exposure`）だけ。
        // 無ければ仮のライト
        if let environment = await Self.loadEnvironment(at: assetDirectory) {
            let light = Entity()
            light.name = "environment"
            light.components.set(
                ImageBasedLightComponent(source: .single(environment), intensityExponent: Self.exposure))
            root.addChild(light)
            self.light = light
            Self.receive(light, in: root)
        } else {
            let sun = DirectionalLight()
            sun.light.intensity = 2500
            sun.look(at: [0, 0, 0], from: [0.3, 0.8, 0.5], relativeTo: nil)
            root.addChild(sun)
        }
        let camera = Entity()
        camera.name = "studio.camera"
        if let scale = layout.orthographicScale {
            var lens = OrthographicCameraComponent()
            lens.scale = scale
            lens.scaleDirection = layout.cameraScaleIsHorizontal ? .horizontal : .vertical
            lens.near = 0.01
            lens.far = 100
            camera.components.set(lens)
        } else {
            camera.components.set(PerspectiveCameraComponent(fieldOfViewInDegrees: layout.fieldOfView))
        }
        camera.look(at: layout.cameraAt, from: layout.cameraFrom, upVector: layout.cameraUp, relativeTo: nil)
        root.addChild(camera)
        return root
    }

    /// Blender から来る資産の置き場（`Gear/*.py` が書く）
    nonisolated static let gearDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ladyland/gear")

    /// 環境マップの明るさの微調整（2 の冪。0 = Blender のまま）
    static let exposure: Float = 0

    /// Blender が撮った全周（`environment.exr`）→ 環境光
    static func loadEnvironment(at directory: URL = gearDirectory) async -> EnvironmentResource? {
        let url = directory.appendingPathComponent("environment.exr")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return try? await EnvironmentResource(equirectangular: image)
    }

    /// 机の上のものすべてを環境光で照らす（後から作る帯も、作ったときに通す）
    static func receive(_ light: Entity, in root: Entity) {
        func walk(_ entity: Entity) {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
            entity.children.forEach(walk)
        }
        walk(root)
    }

    private static func key(_ gear: String, _ part: String) -> String { "\(gear)/\(part)" }

    /// 機材 1 台 — 清書した USDZ があればそれ、無ければ下書きから組む
    private func gearEntity(_ blueprint: GearBlueprint, theme: CreoTheme) async -> Entity {
        let url = assetDirectory.appendingPathComponent("\(blueprint.id).usdz")
        if FileManager.default.fileExists(atPath: url.path),
            let loaded = try? await Entity(contentsOf: url)
        {
            loaded.name = blueprint.id
            for part in blueprint.parts where part.kind == .fader || part.kind == .button {
                if let found = loaded.findEntity(named: part.name) {
                    parts[Self.key(blueprint.id, part.name)] = found
                    partHome[Self.key(blueprint.id, part.name)] = found.position
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
                width: mm(blueprint.size.x), height: mm(blueprint.bodyHeight), depth: mm(blueprint.size.z),
                cornerRadius: 0.002),
            materials: [SimpleMaterial(color: NSColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: true)])
        body.position = [0, mm(blueprint.bodyHeight) / 2, 0]
        gear.addChild(body)

        let top = mm(blueprint.bodyHeight)
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
            case .button, .pad, .key, .other:
                entity = ModelEntity(
                    mesh: .generateBox(
                        width: mm(part.size.x), height: mm(part.size.y), depth: mm(part.size.z),
                        cornerRadius: 0.0008),
                    materials: [part.kind == .key ? cap : button])
                entity.position = center + [0, mm(part.size.y) / 2, 0]
            }
            entity.name = part.name
            gear.addChild(entity)
            parts[Self.key(blueprint.id, part.name)] = entity
            partHome[Self.key(blueprint.id, part.name)] = entity.position
        }
        return gear
    }

    /// 部品の色の材質
    private func glass(_ component: VirtualComponent, opacity: Float, glow: Float = 0.6) -> PhysicallyBasedMaterial {
        let color: NSColor = NSColor(
            component == .mixer ? (theme?.brandPrimary ?? .green) : (theme?.semanticInfo ?? .blue))
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = glow
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    private func label(_ component: VirtualComponent, at: SIMD3<Float>) -> ModelEntity {
        let text = ModelEntity(
            mesh: .generateText(component.title, extrusionDepth: 0.0004, font: .systemFont(ofSize: 0.011)),
            materials: [UnlitMaterial(color: .white)])
        text.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        text.position = at
        return text
    }

    /// 仮想の部品 — 半透明に光る板 + 名前。掴めるように当たりを持たせる。帯は載った先ごとに作る
    private func componentEntity(_ component: VirtualComponent, theme: CreoTheme) -> Entity {
        let root = Entity()
        root.name = "virtual.\(component.rawValue)"
        let size: SIMD3<Float> = component == .mixer ? [0.22, 0.004, 0.05] : [0.22, 0.004, 0.022]
        let plate = ModelEntity(
            mesh: .generateBox(size: size, cornerRadius: 0.002), materials: [glass(component, opacity: 0.45)])
        plate.components.set(CollisionComponent(shapes: [.generateBox(size: size + [0, 0.01, 0])]))
        plate.components.set(InputTargetComponent())
        plate.addChild(label(component, at: [-size.x / 2 + 0.004, size.y / 2 + 0.0005, size.z / 2 - 0.004]))
        root.addChild(plate)
        flats[component] = plate
        return root
    }

    /// 載った先の機材を**機材ごと**包む帯（mako 赤入れ 2026-10-04: 左端まで覆う / 上の面は薄く）
    func wrapEntity(_ component: VirtualComponent, section: String) -> Entity? {
        guard
            let gear = placedGears.first(where: { g in g.blueprint.sections.contains { $0.id == section } }),
            let bounds = gearBounds[gear.blueprint.id]
        else { return nil }
        let rect = CGRect(
            x: CGFloat(bounds.min.x * 1000), y: CGFloat(bounds.min.z * 1000),
            width: CGFloat((bounds.max.x - bounds.min.x) * 1000),
            height: CGFloat((bounds.max.z - bounds.min.z) * 1000))
        let frames = Desk3DMath.sleeve(
            section: rect, gearMinZ: bounds.min.z, gearMaxZ: bounds.max.z, top: bounds.max.y)
        let wrap = Entity()
        wrap.position = gear.pose.position
        wrap.orientation = simd_quatf(angle: gear.pose.radians, axis: [0, 1, 0])
        for (name, frame) in frames {
            let piece = ModelEntity(
                mesh: .generateBox(size: frame.size, cornerRadius: 0.0005),
                materials: [name == "top" ? glass(component, opacity: 0.1, glow: 0.15) : glass(component, opacity: 0.4)])
            piece.position = frame.center
            if name == "top" {
                // 掴むのは上の板（外すときは置き場へ引き出す）
                piece.components.set(CollisionComponent(shapes: [.generateBox(size: frame.size + [0, 0.01, 0])]))
                piece.components.set(InputTargetComponent())
                piece.addChild(label(component, at: [
                    -frame.size.x / 2 + 0.004, frame.size.y / 2 + 0.0005, frame.size.z / 2 - 0.004,
                ]))
            }
            wrap.addChild(piece)
        }
        if let light { Self.receive(light, in: wrap) }
        return wrap
    }

    // MARK: - 毎フレーム

    /// 載せた場所へ部品を置き、フェーダーのつまみを音量の位置へ、M を点ける
    func tick(appState: AppState) {
        let docks = appState.windowPlacement.docks ?? [:]
        for (component, entity) in components {
            let docked = docks[component.rawValue]
            // 載った先が変わったら帯を作り直す
            if wraps[component]?.section != docked {
                wraps[component]?.entity.removeFromParent()
                wraps[component] = nil
                if let docked, let wrap = wrapEntity(component, section: docked) {
                    entity.addChild(wrap)
                    wraps[component] = (wrap, docked)
                }
            }
            let wrapped = dragging[component] == nil && wraps[component] != nil
            wraps[component]?.entity.isEnabled = wrapped
            flats[component]?.isEnabled = !wrapped
            if let point = dragging[component] {
                entity.position = point
            } else if wrapped {
                entity.position = .zero  // 帯は机の座標で組んである
            } else {
                entity.position = restingPosition(component)
            }
        }

        let bank = MixerModel.bankIndices(
            selected: appState.rack.selected, trackCount: appState.rack.slots.count)
        let mixerOnFaders = docks[VirtualComponent.mixer.rawValue] == "nanokontrol.faders"
        let nano = placedGears.first { $0.blueprint.id == "nanokontrol" }?.blueprint
        for (i, n) in (1...8).enumerated() {
            let slot = bank.indices.contains(i) ? appState.rack.slots[bank[i]] : nil
            // フェーダー — Mixer が載っていればその Track の音量の位置（上 = 奥）
            let faderKey = Self.key("nanokontrol", "fader_\(n)")
            if let fader = parts[faderKey], let home = partHome[faderKey] {
                let gain = mixerOnFaders ? (slot?.gain ?? 0) : 0.5
                // 機材の「奥」（ローカル -z）を部品の親へ直す。棚上で回しても方向を保つ。
                let back = gearEntities["nanokontrol"]?.convert(direction: [0, 0, -1], to: fader.parent) ?? [0, 0, -1]
                // 可動幅は下書きの値（写真のトレースで 30 mm）
                let travel = (nano?.parts.first { $0.name == "fader_\(n)" }?.travel ?? 30) / 1000
                fader.position = home + Desk3DMath.faderOffset(gain: gain, travel: travel, back: back)
            }
            // M — ミュート中は赤
            if let mute = parts[Self.key("nanokontrol", "m_\(n)")].flatMap(Self.model(of:)) {
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

    /// 部品の置き場（並びの tray。机の上に平らに置く）
    private func restingPosition(_ component: VirtualComponent) -> SIMD3<Float> {
        layout.trayPosition(component)
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

    func drag(_ component: VirtualComponent, origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let target = Desk3DMath.dropTarget(for: component, origin: origin, direction: direction, gears: placedGears)
        dragTargets[component] = target?.section.id
        if let target {
            dragging[component] = target.point + [0, 0.008, 0]
        } else if let hit = Desk3DMath.intersect(
            origin: origin, direction: direction, planeY: layout.trayElevation / 1000 + 0.12)
        {
            dragging[component] = hit
        }
    }

    func dragSection(_ component: VirtualComponent) -> String? {
        dragTargets[component]
    }

    func endDrag(_ component: VirtualComponent) {
        dragging[component] = nil
        dragTargets[component] = nil
    }
}
