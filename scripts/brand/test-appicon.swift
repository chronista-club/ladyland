import AppKit
import Foundation

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ladyland-icon-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
var svg = try String(contentsOf: repo.appendingPathComponent("assets/brand/source.svg"), encoding: .utf8)
let start = svg.range(of: "<metadata id=\"ladyland-logo-model\">")!.upperBound
let end = svg.range(of: "</metadata>", range: start..<svg.endIndex)!.lowerBound
var model = try JSONSerialization.jsonObject(with: Data(svg[start..<end].utf8)) as! [String: Any]
model["color"] = "#e03060"
model["background"] = "#102040"
model["litColumn"] = 0
model["litRow"] = 0
model["gap"] = 0.5
model["inset"] = 0.18
svg.replaceSubrange(start..<end, with: String(data: try JSONSerialization.data(withJSONObject: model), encoding: .utf8)!)
let source = temp.appendingPathComponent("source.svg")
try svg.write(to: source, atomically: true, encoding: .utf8)
let output = temp.appendingPathComponent("Test.iconset")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [repo.appendingPathComponent("scripts/make-appicon.swift").path, output.path, source.path]
try process.run(); process.waitUntilExit()
precondition(process.terminationStatus == 0, "icon generation failed")
let bitmap = NSBitmapImageRep(data: try Data(contentsOf: output.appendingPathComponent("icon_512x512@2x.png")))!
let span = 800.0 * (1 - 2 * 0.18)
let width = span / (4 + 3 * 0.5), height = span / (3 + 2 * 0.5)
let x = Int((100 + 800 * 0.18 + width / 2) * 1.024)
let y = Int((100 + 800 * 0.18 + height / 2) * 1.024)
// NSBitmapImageRep.colorAt returns calibrated NSColor on this OS; converting it again
// changes numeric values. Verify the encoded sRGB samples directly.
var pixel = [Int](repeating: 0, count: 4)
bitmap.getPixel(&pixel, atX: x, y: y)
precondition(pixel == [224, 48, 96, 255], "selected tile must use saved SVG color and position, got \(pixel)")
precondition(bitmap.colorAt(x: 0,y: 0)!.alphaComponent == 0, "outer padding must stay transparent")
let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
precondition(files.count == 10, "all icon variants must be generated")
print("AppIcon: SVG color/position and transparent padding verified; 10 variants")
