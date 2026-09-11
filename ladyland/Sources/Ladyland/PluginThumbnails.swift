//! プラグイン画面のサムネイル（design/06 §8 追補）。
//!
//! プラグイン UI はそれ自体が「顔」— スロットに小さく見えていれば一目で
//! 見分けられる（mako 発案 2026-07-31）。エディタウィンドウを開いた時に
//! 自動でスナップショットを撮り、AU の識別 3 要素をキーにディスクへキャッシュ
//! する。**再起動後もサムネは残る**（開き直し不要）。
//!
//! 注意: Metal / OpenGL 描画のプラグイン（Serum 等）は cacheDisplay で
//! 真っ黒に写ることがある → 単色検出で破棄し、既存サムネを上書きしない。

import AppKit
import AVFoundation
import CoreAudioKit
import SwiftUI

@MainActor
final class PluginThumbnailStore: ObservableObject {
    /// 保存サイズ（表示 88×50 の @2x）
    static let targetSize = NSSize(width: 176, height: 100)

    private let directory: URL
    private var cache: [String: NSImage] = [:]
    /// ディスクに無いことが確定したキー（毎フレームのディスク照会を避ける）
    private var missing: Set<String> = []

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ladyland/thumbnails")
    }

    /// スロットのロード済みプラグインのサムネ（メモリ → ディスクの順で解決）
    func image(for slot: InstrumentSlot) -> NSImage? {
        guard let unit = slot.audioUnit else { return nil }
        return image(for: unit.audioComponentDescription)
    }

    func image(for desc: AudioComponentDescription) -> NSImage? {
        let key = Self.key(for: desc)
        if let cached = cache[key] { return cached }
        guard !missing.contains(key) else { return nil }
        if let image = NSImage(contentsOf: fileURL(for: key)) {
            cache[key] = image
            return image
        }
        missing.insert(key)
        return nil
    }

    /// エディタウィンドウの中身からサムネを撮る（開いた直後 + 閉じる直前 +
    /// 差し替え refresh。呼び出しは PluginEditorWindows に一本化 —
    /// requestViewController の二重要求を防ぐため、VC の所有者はあちらだけ）
    func capture(view: NSView, for desc: AudioComponentDescription) {
        let bounds = view.bounds
        guard bounds.width > 32, bounds.height > 32,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        else { return }
        view.cacheDisplay(in: bounds, to: rep)

        // Metal 系 UI の黒画面・未描画を保存しない（既存サムネを守る）
        guard !Self.isBlank(rep) else {
            NSLog("thumbnail: %@ は単色（未描画/Metal）— 破棄", Self.key(for: desc))
            return
        }

        let thumbnail = Self.downscale(rep, to: Self.targetSize)
        let key = Self.key(for: desc)
        cache[key] = thumbnail
        missing.remove(key)
        objectWillChange.send()

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if let data = Self.pngData(from: thumbnail) {
                try data.write(to: fileURL(for: key), options: .atomic)
            }
        } catch {
            NSLog("thumbnail: 保存失敗 %@", String(describing: error))
        }
    }

    // MARK: - 純粋部（テスト対象）

    /// AU 識別 3 要素 → ファイルキー
    static func key(for desc: AudioComponentDescription) -> String {
        String(
            format: "%08x-%08x-%08x",
            desc.componentType, desc.componentSubType, desc.componentManufacturer
        )
    }

    /// 5×5 グリッドのサンプル画素がほぼ単色なら true（黒画面・未描画の検出）
    static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 4, h > 4 else { return true }
        var first: NSColor?
        for gx in 0..<5 {
            for gy in 0..<5 {
                let x = w * (gx * 2 + 1) / 10
                let y = h * (gy * 2 + 1) / 10
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if let first {
                    if abs(color.redComponent - first.redComponent) > 0.02
                        || abs(color.greenComponent - first.greenComponent) > 0.02
                        || abs(color.blueComponent - first.blueComponent) > 0.02 {
                        return false
                    }
                } else {
                    first = color
                }
            }
        }
        return true
    }

    static func downscale(_ rep: NSBitmapImageRep, to size: NSSize) -> NSImage {
        let source = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        source.addRepresentation(rep)

        // aspect-fill（プラグイン UI は横長が多い — 幅を合わせ上部を残す）
        let scale = max(
            size.width / source.size.width,
            size.height / source.size.height
        )
        let drawSize = NSSize(
            width: source.size.width * scale, height: source.size.height * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(
                x: (size.width - drawSize.width) / 2,
                y: size.height - drawSize.height,  // 上端合わせ（ヘッダに顔がある UI が多い）
                width: drawSize.width, height: drawSize.height
            ),
            from: .zero, operation: .copy, fraction: 1.0
        )
        image.unlockFocus()
        return image
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }
}
