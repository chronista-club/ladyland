#!/usr/bin/env swift
//
// ladyland AppIcon 生成（2026-08-02）
//
// 意匠: **billboard**（規則的に並ぶタイルの面）そのもの。ひとつだけが
// brand primary で点灯している = 「選択中の楽器」。アプリを開いたときに
// 目に入る絵と、Dock のアイコンが同じ語彙になる。
//
// 色は creo-ui トークン（Creo エコシステム共通の視覚言語）:
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

let bg = CGColor(red: 0.0275, green: 0.0431, blue: 0.0784, alpha: 1)
let mint = CGColor(red: 0.3804, green: 0.7725, blue: 0.5804, alpha: 1)

/// 1 枚描く（size = 正方形の一辺）
func render(size: CGFloat) -> CGImage? {
    guard
        let context = CGContext(
            data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // macOS のアイコンは正方形いっぱいに描かず、角丸の板を中央に置く作法。
    // 板 = 一辺の 80%、角丸は Apple の squircle 比 (0.2246) に寄せる
    let plate = size * 0.80
    let origin = (size - plate) / 2
    let rect = CGRect(x: origin, y: origin, width: plate, height: plate)
    let plateRadius = plate * 0.2246

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
    let inset = plate * 0.14
    let field = CGRect(
        x: rect.minX + inset, y: rect.minY + inset,
        width: plate - inset * 2, height: plate - inset * 2)
    let gapRatio: CGFloat = 0.26
    let cellWidth = field.width / (CGFloat(columns) + gapRatio * CGFloat(columns - 1))
    let cellHeight = field.height / (CGFloat(rows) + gapRatio * CGFloat(rows - 1))
    let gapX = cellWidth * gapRatio
    let gapY = cellHeight * gapRatio
    let tileRadius = min(cellWidth, cellHeight) * 0.24

    // 点灯させる 1 枚（中央やや上 = 目線が最初に行く位置）
    let litColumn = 1
    let litRow = 1

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
                    offset: .zero, blur: cellWidth * 0.55, color: mint.copy(alpha: 0.85))
                context.addPath(path)
                context.setFillColor(mint)
                context.fillPath()
                context.restoreGState()
            } else {
                context.addPath(path)
                context.setFillColor(mint.copy(alpha: 0.20)!)
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
