//! PluginThumbnailStore の純粋部のテスト — キー生成・単色検出・PNG 変換。

import AVFoundation
import AppKit
import Testing

@testable import Ladyland

@Suite("PluginThumbnails")
@MainActor
struct PluginThumbnailTests {
    @Test("キーは AU 識別 3 要素から安定生成される")
    func keyFormat() {
        var desc = AudioComponentDescription()
        desc.componentType = 0x6175_6D75  // 'aumu'
        desc.componentSubType = 0x4B47_3338
        desc.componentManufacturer = 0x4B4F_5247  // 'KORG'
        #expect(PluginThumbnailStore.key(for: desc) == "61756d75-4b473338-4b4f5247")
    }

    @Test("単色画像は blank、グラデーションは blank でない")
    func blankDetection() throws {
        func makeRep(gradient: Bool) throws -> NSBitmapImageRep {
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if gradient {
                NSGradient(starting: .red, ending: .blue)?
                    .draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), angle: 45)
            } else {
                NSColor.black.setFill()
                NSRect(x: 0, y: 0, width: 64, height: 64).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        #expect(PluginThumbnailStore.isBlank(try makeRep(gradient: false)),
                "真っ黒（Metal 未描画相当）は破棄対象")
        #expect(!PluginThumbnailStore.isBlank(try makeRep(gradient: true)),
                "実描画（グラデーション）は保存対象")
    }

    @Test("縮小 → PNG 変換が往復する")
    func downscaleAndPNG() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let thumbnail = PluginThumbnailStore.downscale(rep, to: PluginThumbnailStore.targetSize)
        #expect(thumbnail.size == PluginThumbnailStore.targetSize)

        let png = try #require(PluginThumbnailStore.pngData(from: thumbnail))
        #expect(!png.isEmpty)
        #expect(NSImage(data: png) != nil)
    }
}

@Suite("FerrofluidThumb 形状")
struct FerrofluidThumbTests {
    @Test("半径は常に正で、同入力なら決定的")
    func radiusIsPositiveAndDeterministic() {
        for i in 0..<72 {
            let theta = Double(i) / 72 * 2 * .pi
            let r1 = FerrofluidThumb.blobRadius(
                theta: theta, time: 12.3, level: 1.0, seed: 1.7, base: 15)
            let r2 = FerrofluidThumb.blobRadius(
                theta: theta, time: 12.3, level: 1.0, seed: 1.7, base: 15)
            #expect(r1 > 0)
            #expect(r1 == r2)
        }
    }

    @Test("音量が上がると棘（最大半径）が立つ")
    func levelRaisesSpikes() {
        func maxRadius(level: Double) -> Double {
            (0..<144).map { i in
                FerrofluidThumb.blobRadius(
                    theta: Double(i) / 144 * 2 * .pi, time: 5.0,
                    level: level, seed: 0, base: 15)
            }.max() ?? 0
        }
        #expect(maxRadius(level: 1.0) > maxRadius(level: 0.0) * 1.2,
                "無音の漂いより有音の棘がはっきり大きいこと")
    }
}
