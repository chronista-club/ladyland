//! 磁性流体プレースホルダ（design/06 §8 追補、mako 発案 2026-07-31）。
//!
//! Metal/OpenGL 描画のプラグインはサムネが撮れない（cacheDisplay が黒に写る）。
//! 何も出さない代わりに「液体の中の磁性流体が音で緩やかに反応する」生きた顔を
//! 置く。音源 = slot.level（post-fader メーター値 — 攻撃即時・減衰緩やか）。
//!
//! 描画は SwiftUI Canvas + TimelineView 30fps。表面形状は純関数
//! blobRadius(θ) — 低次の波が常時ゆっくり揺れ、音量で磁性流体特有の棘が立つ。

import SwiftUI

struct FerrofluidThumb: View {
    /// 0-1（slot.level。メーターバリスティクス済みなので追加平滑は不要）
    let level: Float
    /// スロットごとに揺らぎ位相を変える（隣のタイルと同期して見えないように）
    let seed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                Self.draw(
                    context: context, size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    level: Double(min(max(level, 0), 1)),
                    seed: seed
                )
            }
        }
    }

    // MARK: - 形状（純関数、テスト対象）

    /// 流体表面の半径。
    /// sway = 低次の波（常時、音と無関係にゆっくり漂う）
    /// spikes = 磁性流体の棘（|sin|³ で先端を尖らせ、音量で立ち上がる）
    static func blobRadius(
        theta: Double, time: Double, level: Double, seed: Double, base: Double
    ) -> Double {
        let sway = 0.06 * sin(3 * theta + time * 0.6 + seed)
            + 0.04 * sin(5 * theta - time * 0.9 + seed * 2)
        let spikes = level * 0.55 * pow(abs(sin(7 * theta + time * 1.4 + seed)), 3.0)
        let swell = 1.0 + 0.35 * level
        return base * swell * (1.0 + sway + spikes)
    }

    // MARK: - 描画

    static func draw(
        context: GraphicsContext, size: CGSize, time: Double, level: Double, seed: Double
    ) {
        // 容器の液体: 深い青黒
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.14),
                    Color(red: 0.01, green: 0.02, blue: 0.05),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )

        // 磁性流体の塊（横長タイルに合わせ水平に楕円化）
        let center = CGPoint(x: size.width / 2, y: size.height * 0.64)
        let base = Double(size.height) * 0.30
        var blob = Path()
        let steps = 72
        for i in 0...steps {
            let theta = Double(i) / Double(steps) * 2 * .pi
            let r = blobRadius(theta: theta, time: time, level: level, seed: seed, base: base)
            let point = CGPoint(
                x: center.x + CGFloat(cos(theta) * r * 1.5),
                y: center.y + CGFloat(sin(theta) * r)
            )
            if i == 0 {
                blob.move(to: point)
            } else {
                blob.addLine(to: point)
            }
        }
        blob.closeSubpath()

        context.fill(
            blob,
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.16, green: 0.18, blue: 0.30),
                    Color(red: 0.02, green: 0.02, blue: 0.06),
                ]),
                center: CGPoint(
                    x: center.x - size.width * 0.12, y: center.y - size.height * 0.18),
                startRadius: 2,
                endRadius: size.height * 0.75
            )
        )

        // 液面のガラス感（上部の淡いハイライト）
        let sheen = Path(ellipseIn: CGRect(
            x: size.width * 0.16, y: size.height * 0.10,
            width: size.width * 0.40, height: size.height * 0.16
        ))
        context.fill(sheen, with: .color(Color.white.opacity(0.05)))
    }
}
