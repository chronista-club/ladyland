//! Field の空間 — v0 は**目の前に lady 一体**（spec/08、mako 裁定
//! 「目の前楽器が一つ見えてて欲しい」）。
//!
//! 球体（原風景も球体）+ トラックカラー + 名前 + **出音レベルで脈動**。
//! 反同期原則の種: これは「音に反応する映像」ではなく「lady が鳴っている」
//! — 音と光は同じ存在の二つの現れ（原典 3）。
//!
//! ⚠️ **RealityView の update クロージャは @Observable の変更では走らない**
//! （実機で「弾いても何もない」2026-08-15 の正体 — 球体が初期状態で置き去り、
//! Attachment の Text だけが観測されて動く）。body で client.entities を
//! 読む `.onChange` で依存を張り、entity は @State の参照へ直接当てる。

import RealityKit
import SwiftUI

struct FieldSpace: View {
    @Environment(FieldClient.self) private var client
    @State private var lady: ModelEntity?
    @State private var label: ViewAttachmentEntity?

    /// lady の定位置 — 目の前 1m（visionOS 座標: -Z が前方。高さは実機で
    /// mako 合わせ 2026-08-15「あと 15cm 下に下げれる」— 1.3 → 1.15）
    private static let ladyPosition: SIMD3<Float> = [0, 1.15, -1.0]
    private static let baseRadius: Float = 0.12

    var body: some View {
        RealityView { content, attachments in
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: Self.baseRadius),
                materials: [Self.material(for: client.focused?.color)])
            sphere.position = Self.ladyPosition
            content.add(sphere)
            lady = sphere

            if let name = attachments.entity(for: "name") {
                name.position = Self.ladyPosition + [0, Self.baseRadius + 0.12, 0]
                content.add(name)
                label = name
            }
        } attachments: {
            Attachment(id: "name") {
                Text(client.focused.map { "T\($0.id) \($0.name)" } ?? "…")
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassBackgroundEffect()
            }
        }
        .onChange(of: client.entities) { _, _ in
            apply()
        }
    }

    /// 鼓動を lady へ当てる（FieldTick 実質 10-30Hz — v0 は素直に追従、
    /// 補間・慣性は Behavior Engine（v2）の領分）
    private func apply() {
        guard let lady else { return }
        let focused = client.focused
        let scale = 1.0 + (focused?.level ?? 0) * 0.4
        lady.scale = SIMD3<Float>(repeating: scale)
        lady.model?.materials = [Self.material(for: focused?.color)]
        label?.position = Self.ladyPosition + [0, Self.baseRadius * scale + 0.12, 0]
    }

    /// トラックカラー（"#RRGGBB"）→ マテリアル。未設定は月白
    private static func material(for hex: String?) -> SimpleMaterial {
        let color = hex.flatMap(Self.parse) ?? SIMD3<Float>(0.85, 0.87, 0.9)
        return SimpleMaterial(
            color: SimpleMaterial.Color(
                red: CGFloat(color.x), green: CGFloat(color.y),
                blue: CGFloat(color.z), alpha: 1),
            roughness: 0.35, isMetallic: false)
    }

    private static func parse(_ hex: String) -> SIMD3<Float>? {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return SIMD3<Float>(
            Float((value >> 16) & 0xFF) / 255,
            Float((value >> 8) & 0xFF) / 255,
            Float(value & 0xFF) / 255)
    }
}
