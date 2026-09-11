//! サンプラーの 3D ビュー（mako 要望 2026-08-06「グリッドの地面があって見下ろし
//! 視点で、各サンプルが Vol 0 の場合は中心が 0 で、Vol が上がると球も上がる見た目」）。
//!
//! ## 配置は LPD8 の物理そのまま
//!
//! 奥の列が pad 1-4、手前の列が pad 5-8。**実機を見下ろしたときと同じ形**なので、
//! 「どのパッドに何が入っているか」を画面と実機の間で読み替えなくて済む
//! （`Lpd8DefaultPadNotes` のコメント: 44-47 が上段 = index 0-3）。
//!
//! ## 高さ = 音量
//!
//! Vol 0 で球の中心が地面（半分沈む）、上げると浮き上がる。**8 本のノブが
//! そのまま地形になる** — どれが大きいかが数字を読まずに分かる。
//!
//! ⚠️ AU は `ObservableObject` ではないので、**毎フレーム AU から読む**
//! （`SCNSceneRendererDelegate`）。MIDI でノブを回しても画面が追従する。

import SceneKit
import SwiftUI

struct SamplerFieldView: NSViewRepresentable {
    let sampler: LadySampler

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.delegate = context.coordinator
        view.rendersContinuously = true  // 音量と再生位置に毎フレーム追従する
        view.isPlaying = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(sampler: sampler) }

    // MARK: - 組み立てと毎フレーム更新

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        private let sampler: LadySampler
        private var balls: [SCNNode] = []
        /// 起動直後だけ状態をログに出す残り回数（実機での切り分け用）
        private var diagnosticsLeft = 3

        /// 音量 1.0 のときの高さ。**地面から浮く量**（0 なら中心が地面）
        private static let maxLift: CGFloat = 1.6
        /// 球の半径 — 列の間隔（1.0）より小さくして、隣と重ならないように
        private static let radius: CGFloat = 0.34

        init(sampler: LadySampler) {
            self.sampler = sampler
            super.init()
            buildFloor()
            buildBalls()
            buildCamera()
            buildLights()
        }

        /// **グリッドの地面** — 細い箱を格子に並べる。
        /// `SCNFloor` の鏡面反射は重いうえ、球の高さが読みにくくなるので使わない
        private func buildFloor() {
            let lines = SCNNode()
            let half = 2.5
            let material = SCNMaterial()
            material.diffuse.contents = NSColor(white: 0.30, alpha: 1)
            material.lightingModel = .constant  // 地面の線は陰影を持たない方が読める

            for step in -2...2 {
                let offset = CGFloat(step)
                for horizontal in [true, false] {
                    let bar = SCNBox(
                        width: horizontal ? CGFloat(half * 2) : 0.01,
                        height: 0.01,
                        length: horizontal ? 0.01 : CGFloat(half * 2),
                        chamferRadius: 0)
                    bar.materials = [material]
                    let node = SCNNode(geometry: bar)
                    node.position = SCNVector3(
                        horizontal ? 0 : offset, -0.005, horizontal ? offset : 0)
                    lines.addChildNode(node)
                }
            }
            scene.rootNode.addChildNode(lines)
        }

        /// 8 球を **2 段 4 列**（LPD8 の物理配置）に並べる
        private func buildBalls() {
            for pad in 0..<LadySampler.padCount {
                let sphere = SCNSphere(radius: Self.radius)
                let material = SCNMaterial()
                // ⚠️ **`.physicallyBased` は使わない** — metalness / roughness が
                // 効いて `diffuse` の変化が埋もれる。ここは「空席か / 鳴っているか」を
                // **色で言い切りたい**ので、素直に光が乗る `.blinn` にする
                material.lightingModel = .blinn
                material.specular.contents = NSColor(white: 0.5, alpha: 1)
                sphere.materials = [material]

                let node = SCNNode(geometry: sphere)
                // 奥（z = -0.6）が pad 1-4、手前（z = +0.6）が pad 5-8
                let column = CGFloat(pad % 4) - 1.5
                let row: CGFloat = pad < 4 ? -0.6 : 0.6
                node.position = SCNVector3(column, 0, row)
                scene.rootNode.addChildNode(node)
                balls.append(node)
            }
        }

        /// **見下ろし視点** — 真上だと手前と奥が潰れるので、斜め上から
        private func buildCamera() {
            let camera = SCNCamera()
            // ⚠️ **画角は縦に効かせる**（実測 2026-08-07: 球が上で見切れていた）。
            //
            // SceneKit の既定は**横長のとき画角を横に当てる**ので、
            // 幅 440 × 高さ 200（≒2.2:1）だと**縦の画角が 40° ÷ 2.2 ≒ 18°** まで
            // 縮み、y = 1.6 まで持ち上がる球が枠から出ていた。
            //
            // `.vertical` にすると**縦の枠が幅に左右されなくなる** — 横に広げた
            // ぶんは横が見えるだけになるので、**アスペクトが変わっても収まる**。
            // 面を縦に伸ばした（`LadySamplerView`）ことと合わせて効く
            camera.projectionDirection = .vertical
            camera.fieldOfView = 40
            camera.zNear = 0.1
            camera.zFar = 100
            let node = SCNNode()
            node.camera = camera
            node.position = SCNVector3(0, 3.4, 4.2)
            node.eulerAngles = SCNVector3(-0.62, 0, 0)  // ≒ -35°
            scene.rootNode.addChildNode(node)
        }

        private func buildLights() {
            let key = SCNLight()
            key.type = .omni
            key.intensity = 900
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.position = SCNVector3(2, 5, 3)
            scene.rootNode.addChildNode(keyNode)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 260
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)
        }

        // MARK: - 毎フレーム

        /// ⚠️ **レンダースレッドから AU を読む**。AU は `ObservableObject` では
        /// ないので、通知を待つ形にすると MIDI のノブ操作に追従できない。
        ///
        /// ⚠️ 読みは `padStates()` の **1 回にまとめる**。席ごとに `gain` /
        /// `hasSample` / `progress` を呼ぶと毎秒 1440 回ロックを取ることになり、
        /// **同じロックを待つオーディオのレンダースレッド**を削ってしまう
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let states = sampler.padStates()

            // 最初の数フレームだけ状態を出す（**回っているか / 何を読めているか**を
            // 実機で確かめる用。毎フレーム出すと重いので数回で止める）。
            //
            // ⚠️ **文字にするのは main で**（180f7d9 と同じ型）。ここは SceneKit の
            // レンダースレッドで、`map` / `joined()` はヒープを踏むし、NSLog の
            // 書き先は `DebugLog` がパイプへ差し替えた stderr —
            // 読み手が遅れれば `write(2)` はそこで待つ。
            //
            // 3 フレームだけとはいえ、**描画コールバックの中で詰まりうる I/O を
            // する**形そのものを残さない。診断は 1 つも減らさず、
            // **値だけ持って出る**（8 席の在否をビットに畳めば確保は起きない）
            if diagnosticsLeft > 0 {
                diagnosticsLeft -= 1
                var loadedBits: UInt8 = 0
                for (pad, state) in states.enumerated() where state.loaded {
                    loadedBits |= UInt8(1 << pad)
                }
                let firstGain = Double(states[0].gain)
                DispatchQueue.main.async {
                    let marks = (0..<LadySampler.padCount)
                        .map { loadedBits & UInt8(1 << $0) != 0 ? "1" : "0" }
                        .joined()
                    NSLog("field: 更新が回っている — 音入り %@ / K1 %.2f", marks, firstGain)
                }
            }

            for (pad, ball) in balls.enumerated() {
                let gain = CGFloat(states[pad].gain)
                let loaded = states[pad].loaded
                let position = states[pad].position
                let isPlaying = states[pad].isPlaying

                // **高さ = 音量**（0 なら中心が地面）
                ball.position.y = gain * Self.maxLift

                guard let material = ball.geometry?.firstMaterial else { continue }
                if isPlaying {
                    // **鳴っている** — 明るい水色が脈打つ
                    let pulse = 0.5 + 0.5 * sin(position * 60)
                    material.diffuse.contents = NSColor(
                        calibratedHue: 0.52, saturation: 0.75, brightness: 1, alpha: 1)
                    material.emission.contents = NSColor(
                        calibratedHue: 0.52, saturation: 0.6,
                        brightness: CGFloat(pulse) * 0.7, alpha: 1)
                } else if loaded, position > 0 {
                    // **一時停止**（mako 要望 2026-08-06 の Play/Pause）。
                    // ⚠️ 頭で止まっている席と**別の顔**にする — 位置を持っている
                    // ことが見えないと、次に叩いたとき途中から鳴る理由が分からない。
                    //
                    // ⚠️ **再生中の親戚に見せる**（mako 裁定 2026-08-06 で LED が
                    // 二値になり、琥珀を揃える動機が消えた）。一時停止は異常ではなく
                    // **再生の途中の状態**なので、警告色を当てると意味が強すぎる。
                    // 同じ色相のまま彩度と明度を落とし、**脈打たせない** —
                    // 「止まっているが位置がある」が色で読める
                    material.diffuse.contents = NSColor(
                        calibratedHue: 0.52, saturation: 0.45, brightness: 0.85, alpha: 1)
                    material.emission.contents = NSColor(
                        calibratedHue: 0.52, saturation: 0.5,
                        brightness: CGFloat(0.15 + position * 0.25), alpha: 1)
                } else if loaded {
                    // **頭で止まっている** — 落ち着いた青
                    material.diffuse.contents = NSColor(
                        calibratedHue: 0.58, saturation: 0.7, brightness: 0.75, alpha: 1)
                    material.emission.contents = NSColor.black
                } else if case .preparing = states[pad].readiness {
                    // **作り直し中** — 空席と同じ顔にしない（mako 要望 2026-08-06）。
                    //
                    // ⚠️ **琥珀（警告色）に戻した**。これは「**鳴らない**」状態なので、
                    // テーマの `semanticWarning` の語彙がそのまま合う。全体バナー
                    // （`エンジン … へ再変換中 3/8`）も警告色なので席の色と揃う。
                    //
                    // 一時停止（水色系）とは**色相で分かれている** — 明滅の有無だけで
                    // 見分けさせない
                    let breath = 0.5 + 0.5 * sin(time * 4)
                    material.diffuse.contents = NSColor(
                        calibratedHue: 0.11, saturation: 0.75, brightness: 0.65, alpha: 1)
                    material.emission.contents = NSColor(
                        calibratedHue: 0.11, saturation: 0.6,
                        brightness: CGFloat(breath) * 0.5, alpha: 1)
                } else {
                    // **空席** — 沈んだ灰色。「置ける場所」だけが分かればいい
                    material.diffuse.contents = NSColor(white: 0.18, alpha: 1)
                    material.emission.contents = NSColor.black
                }
            }
        }
    }
}
