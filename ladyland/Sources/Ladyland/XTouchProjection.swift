import Foundation
struct XTouchStrip {
    var index: Int
    var name: String
    var gain: Float
    var pan: Float
    var mute: Bool
    var solo: Bool
    var selected: Bool
    var color: UInt8
}
struct XTouchFrame {
    var key: String
    var bytes: [UInt8]
}
enum XTouchProjection {
    static func frames(strips: [XTouchStrip], master: Float, touched: Set<Int>, greeting: Bool) -> [XTouchFrame] {
        var frames: [XTouchFrame] = []
        func add(_ key: String, _ bytes: [UInt8]) { frames.append(XTouchFrame(key: key, bytes: bytes)) }
        var colors = [UInt8](repeating: 0, count: 8)
        for channel in 0..<8 {
            let strip = strips.indices.contains(channel) ? strips[channel] : nil
            colors[channel] = greeting ? UInt8(channel % 7 + 1) : (strip?.color ?? 0)
            add("lcd.\(channel).0", XTouchMCU.lcd(channel, line: 0, text: greeting ? ["Lady", "land", "X-Touch", "8 ch", "+", "Master", "", ""][channel] : (strip?.name ?? "")))
            let value = strip.map { String(format: "%3.0f%%", $0.gain * 100) } ?? ""
            add("lcd.\(channel).1", XTouchMCU.lcd(channel, line: 1, text: greeting ? "Ready" : value))
            guard !greeting else { continue }
            if !touched.contains(channel) { add("fader.\(channel)", XTouchMCU.fader(channel, strip?.gain ?? 0)) }
            add("ring.\(channel)", XTouchMCU.ring(channel, pan: strip?.pan ?? 0))
            add("mute.\(channel)", XTouchMCU.led(0x10 + channel, on: strip?.mute ?? false))
            add("solo.\(channel)", XTouchMCU.led(0x08 + channel, on: strip?.solo ?? false))
            add("select.\(channel)", XTouchMCU.led(0x18 + channel, on: strip?.selected ?? false))
        }
        add("colors", XTouchMCU.colors(colors))
        if !greeting, !touched.contains(8) { add("fader.8", XTouchMCU.fader(8, master)) }
        return frames
    }
}
