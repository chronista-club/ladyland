#!/usr/bin/env swift
//
// ladyland AppIcon 生成（2026-08-02）
//
// 意匠: **billboard**（規則的に並ぶタイルの面）そのもの。ひとつだけが
// brand primary で点灯している = 「選択中の楽器」。アプリを開いたときに
// 目に入る絵と、Dock のアイコンが同じ語彙になる。
//
// 初期色は creo-ui トークン。現在値は assets/brand/source.svg から読む:
//   背景  colorSurfaceBgBase   #070B14
//   点灯  colorBrandPrimary    #61C594
//
// fleetstage は Three.js + headless Chrome で発光キューブを焼いているが、
// ladyland の意匠は平面グリッドなので CoreGraphics で足りる
// （ブラウザ不要 = 再生成が確実。scripts/build-app.sh から呼ばれる）。
//
// 使い方: swift scripts/make-appicon.swift <出力する .iconset ディレクトリ>

import AppKit
import CoreGraphics
import Foundation

// 形・色の正本は Generator が保存した SVG の metadata（design/12）。
// 3D の厚み・照明はプレビュー用。Dock は同じモデルの正面図を使う。
struct LogoModel: Decodable {
    let version: Int
    let gap, radius, inset, plateRadius, dim, glow: Double
    let litColumn, litRow: Int
    let color, background: String
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2)
}
let args = CommandLine.arguments
if args.count < 2 { fail("usage: make-appicon.swift <out.iconset> [source.svg]") }
let sourceURL = args.count > 2 ? URL(fileURLWithPath: args[2]) :
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/brand/source.svg")
let svg = try String(contentsOf: sourceURL, encoding: .utf8)
guard let start = svg.range(of: "<metadata id=\"ladyland-logo-model\">"),
      let end = svg.range(of: "</metadata>", range: start.upperBound..<svg.endIndex) else {
    fail("Ladyland の編集用SVGではありません")
}
let model = try JSONDecoder().decode(LogoModel.self, from: Data(svg[start.upperBound..<end.lowerBound].utf8))
guard model.version == 1,
      (0...0.8).contains(model.gap), (0...0.5).contains(model.radius),
      (0.05...0.3).contains(model.inset), (0...0.5).contains(model.plateRadius),
      (0...0.6).contains(model.dim), (0...1.5).contains(model.glow),
      (0...3).contains(model.litColumn), (0...2).contains(model.litRow) else { fail("SVGの設定値が範囲外です") }
func rgb(_ hex: String) -> CGColor {
    guard hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
          let value = UInt32(hex.dropFirst(), radix: 16) else { fail("SVGの色が不正です") }
    return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
let bg = rgb(model.background)
let mint = rgb(model.color)

/// 1 枚描く（size = 正方形の一辺）
func render(size: CGFloat) -> CGImage? {
    guard
        let context = CGContext(
            data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS のアイコンは正方形いっぱいに描かず、角丸の板を中央に置く作法。
    // 板 = 一辺の 80%、角丸は Apple の squircle 比 (0.2246) に寄せる
    let plate = size * 0.80
    let origin = (size - plate) / 2
    let rect = CGRect(x: origin, y: origin, width: plate, height: plate)
    let plateRadius = plate * model.plateRadius

    // 板（暗い盤面）+ ごく薄い縁 = 画面の縁取りに見せる
    let platePath = CGPath(
        roundedRect: rect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)
    context.addPath(platePath)
    context.setFillColor(bg)
    context.fillPath()

    context.addPath(platePath)
    context.setStrokeColor(mint.copy(alpha: 0.18)!)
    context.setLineWidth(max(1, size * 0.006))
    context.strokePath()

    // タイル格子（4 列 × 3 行 = billboard の縮図）。
    // 小さいサイズでも「並び」が読めるよう、間隔は広めに取る
    let columns = 4
    let rows = 3
    let inset = plate * model.inset
    let field = CGRect(
        x: rect.minX + inset, y: rect.minY + inset,
        width: plate - inset * 2, height: plate - inset * 2)
    let gapRatio: CGFloat = model.gap
    let cellWidth = field.width / (CGFloat(columns) + gapRatio * CGFloat(columns - 1))
    let cellHeight = field.height / (CGFloat(rows) + gapRatio * CGFloat(rows - 1))
    let gapX = cellWidth * gapRatio
    let gapY = cellHeight * gapRatio
    let tileRadius = min(cellWidth, cellHeight) * model.radius

    // 点灯させる 1 枚（中央やや上 = 目線が最初に行く位置）
    let litColumn = model.litColumn
    let litRow = model.litRow

    for row in 0..<rows {
        for column in 0..<columns {
            let x = field.minX + CGFloat(column) * (cellWidth + gapX)
            // 行は上から数える（CoreGraphics は下原点なので反転）
            let y = field.maxY - CGFloat(row + 1) * cellHeight - CGFloat(row) * gapY
            let tile = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
            let path = CGPath(
                roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius,
                transform: nil)

            let isLit = (row == litRow && column == litColumn)
            if isLit {
                // 発光: 影を光として使う（Creo の視覚言語 = 暗所で光る）
                context.saveGState()
                context.setShadow(
                    offset: .zero, blur: cellWidth * 0.55, color: mint.copy(alpha: min(model.glow, 1)))
                context.addPath(path)
                context.setFillColor(mint)
                context.fillPath()
                context.restoreGState()
            } else {
                context.addPath(path)
                context.setFillColor(mint.copy(alpha: model.dim)!)
                context.fillPath()
            }
        }
    }

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "appicon", code: 1)
    }
    try data.write(to: url)
}

// iconutil が要求する名前と実サイズの対応
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: make-appicon.swift <out.iconset>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    guard let image = render(size: variant.size) else {
        FileHandle.standardError.write(Data("render failed: \(variant.name)\n".utf8))
        exit(1)
    }
    try write(image, to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("appicon: \(variants.count) 枚を \(outputDirectory.path) に書き出しました")
