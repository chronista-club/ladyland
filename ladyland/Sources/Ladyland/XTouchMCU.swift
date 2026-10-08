import Foundation

/// MCU byte変換（Ardour MCU / Midistage Rust profileと同じwire形式）。I/Oを持たない。
enum XTouchMCU {
    enum Event: Equatable {
        case fader(Int, Float), pan(Int, Int), mute(Int), solo(Int), select(Int)
        case move(Int), touch(Int, Bool), centerPan(Int)
    }
    static func decode(_ status: UInt8, _ a: UInt8, _ b: UInt8) -> Event? {
        guard a < 128, b < 128 else { return nil }
        if (0xe0...0xe8).contains(status) {
            return .fader(Int(status - 0xe0), Float(Int(b) << 7 | Int(a)) / 16383)
        }
        if status == 0xb0, (0x10...0x17).contains(a) {
            let delta = Int(b & 0x3f) * (b & 0x40 == 0 ? 1 : -1)
            return delta == 0 ? nil : .pan(Int(a - 0x10), delta)
        }
        guard status == 0x90 || status == 0x80 else { return nil }
        let down = status == 0x90 && b != 0
        if (0x68...0x70).contains(a) { return .touch(Int(a - 0x68), down) }
        guard down else { return nil }
        switch a {
        case 0x08...0x0f: return .solo(Int(a - 8))
        case 0x10...0x17: return .mute(Int(a - 0x10))
        case 0x18...0x1f: return .select(Int(a - 0x18))
        case 0x20...0x27: return .centerPan(Int(a - 0x20))
        case 0x2e: return .move(-8)
        case 0x2f: return .move(8)
        case 0x30: return .move(-1)
        case 0x31: return .move(1)
        default: return nil
        }
    }
    static func fader(_ index: Int, _ value: Float) -> [UInt8] {
        guard (0...8).contains(index), value.isFinite else { return [] }
        let n = Int((min(1, max(0, value)) * 16383).rounded())
        return [0xe0 | UInt8(index), UInt8(n & 127), UInt8(n >> 7)]
    }
    static let header: [UInt8] = [0xf0, 0, 0, 0x66, 0x14]
    static func lcd(_ index: Int, line: Int, text: String) -> [UInt8] {
        guard (0..<8).contains(index), (0...1).contains(line) else { return [] }
        let ascii = Array(text.unicodeScalars.prefix(7)).map { UInt8($0.value >= 32 && $0.value < 127 ? $0.value : 63) }
        return header + [0x12, UInt8(line * 56 + index * 7)] + ascii + Array(repeating: 32, count: 7 - ascii.count) + [0xf7]
    }
    static func ring(_ index: Int, pan: Float) -> [UInt8] {
        guard (0..<8).contains(index), pan.isFinite else { return [] }
        let p = min(1, max(-1, pan))
        let position = UInt8(((p + 1) * 5).rounded()) + 1
        return [0xb0, UInt8(0x30 + index), 0x10 | position | (abs(p) < 0.02 ? 0x40 : 0)]
    }
    static func led(_ note: Int, on: Bool) -> [UInt8] { [0x90, UInt8(note), on ? 127 : 0] }
    static func colors(_ colors: [UInt8]) -> [UInt8] {
        guard colors.count == 8 else { return [] }
        return header + [0x72] + colors.map { $0 & 7 } + [0xf7]
    }
    static func stripColor(rgb: UInt32?) -> UInt8 {
        guard let rgb else { return 7 }
        let palette: [UInt32] = [0, 0xff0000, 0x00ff00, 0xffff00, 0x0000ff, 0xff00ff, 0x00ffff, 0xffffff]
        func distance(_ c: UInt32) -> Int {
            [0, 8, 16].reduce(0) { sum, shift in
                let d = Int((rgb >> shift) & 255) - Int((c >> shift) & 255)
                return sum + d * d
            }
        }
        return UInt8(palette.indices.min { distance(palette[$0]) < distance(palette[$1]) } ?? 7)
    }
}

struct XTouchBank {
    private(set) var start = 0
    private(set) var pending = 0
    private(set) var touched: Set<Int> = []
    mutating func move(_ delta: Int, trackCount: Int) {
        let target = min(max(0, trackCount - 8), max(0, start + pending + delta))
        if touched.isEmpty { start = target; pending = 0 } else { pending = target - start }
    }
    mutating func touch(_ index: Int, down: Bool, trackCount: Int) {
        guard (0...8).contains(index) else { return }
        if down { touched.insert(index) } else { touched.remove(index) }
        if touched.isEmpty { move(0, trackCount: trackCount) }
    }
    mutating func releaseTouches() { touched.removeAll(); pending = 0 }
    func indices(trackCount: Int) -> [Int] {
        Array(min(start, max(trackCount, 0))..<min(start + 8, max(trackCount, 0)))
    }
}
