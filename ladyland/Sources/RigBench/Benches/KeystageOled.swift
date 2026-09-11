//! Keystage ノブ OLED への Display Message 実機確認（docs/keystage §9 の未検証 2 点）。
//!
//! 検証すること:
//!   1. **0x6F 接続（Ableton 方式）だけで Func 0x28 Display Message が効くか**
//!      — Native Mode Enter（GigPerformer 方式）はノブを CC0-7/ch16 に固定して
//!      16 ページと排他になる。0x6F で効くなら「ページ活用 + LCD 表示」が両立する
//!   2. ACK (0x23) / NAK (0x24) が返るか、どのポート宛で効くか
//!
//! 手順: Device Inquiry で global ch / 機種 (49/61) を自動判別 → 0x6F 接続 →
//! メイン + ノブ 1-8 の OLED に試験文字列 → 20 秒目視タイム → 0x6F 00 切断で復元。
//! 実行中に本体のページボタンとノブを触り、midi-sniff で CC が従来どおりかも見ると
//! 両立の完全確認になる。

import CoreMIDI
import Foundation
import Lpd8Kit

struct KeystageOled: Bench {
    let name = "keystage-oled"
    let summary = "ノブ OLED に文字を書く（0x6F 接続・Native Mode 非使用の実機確認）"

    /// 受信箱（Inquiry 応答と ACK/NAK。コールバックは CoreMIDI 直列）
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[UInt8]] = []
        func add(_ frame: [UInt8]) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }
        func drain() -> [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            let out = frames
            frames = []
            return out
        }
    }

    func run() throws {
        // --- 受信（全 Keystage ソースから SysEx を拾う）---
        var client = MIDIClientRef()
        var status = MIDIClientCreateWithBlock("rigbench-oled" as CFString, &client, nil)
        guard status == noErr else { throw BenchError("MIDIClientCreate: \(status)") }

        let inbox = Inbox()
        var inPort = MIDIPortRef()
        status = MIDIInputPortCreateWithProtocol(client, "oled-in" as CFString, ._1_0, &inPort) {
            eventList, _ in
            var assembler = SysEx7Assembler()
            for packet in eventList.unsafeSequence() {
                let wordCount = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuplePtr in
                    tuplePtr.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(wordCount, 64) {
                            if let frame = assembler.feed(words[i]) {
                                inbox.add(frame)
                            }
                        }
                    }
                }
            }
        }
        guard status == noErr else { throw BenchError("MIDIInputPortCreate: \(status)") }
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if (displayName(of: source) ?? "").contains("Keystage") {
                MIDIPortConnectSource(inPort, source, nil)
            }
        }

        // --- 宛先（DAW ポート優先 — Ableton 公式スクリプトの実証と同じ）---
        var destinations: [(String, MIDIEndpointRef)] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            if let name = displayName(of: dest), name.contains("Keystage") {
                destinations.append((name, dest))
            }
        }
        print("Keystage 宛先: \(destinations.map(\.0).joined(separator: ", "))")
        guard let target = destinations.first(where: { $0.0.contains("DAW") })
            ?? destinations.first
        else { throw BenchError("Keystage の宛先が見つからない") }
        print("送信先: \(target.0)")

        let sendClient = try MIDISysExSender.makeClient("rigbench-oled-out")
        _ = sendClient

        // --- 1. Device Inquiry（global ch と機種を自動判別）---
        MIDISysExSender.send([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], to: target.1)
        Thread.sleep(forTimeInterval: 1.0)

        var globalCh: UInt8 = 0
        var member: UInt8 = 0x01  // 既定 49 鍵
        for frame in inbox.drain() {
            // F0 7E 0g 06 02 42 69 01 mm 00 <ver×4> F7
            if frame.count >= 10, frame[1] == 0x7E, frame[3] == 0x06, frame[4] == 0x02,
                frame[5] == 0x42 {
                globalCh = frame[2] & 0x0F
                member = frame[8]
                print(String(
                    format: "Inquiry 応答: global ch %d, member %02X (%@)",
                    globalCh + 1, member, member == 0x09 ? "61鍵" : "49鍵"))
            }
        }

        let header: [UInt8] = [0xF0, 0x42, 0x40 | globalCh, 0x00, 0x01, 0x69, member]

        func frame(_ function: UInt8, _ payload: [UInt8]) -> [UInt8] {
            let length = 1 + payload.count
            let lengthBytes: [UInt8] = [
                UInt8(length & 0x7F), UInt8((length >> 7) & 0x7F), UInt8((length >> 14) & 0x7F),
            ]
            return header + lengthBytes + [function] + payload + [0xF7]
        }

        func display(_ address: UInt8, _ line: UInt8, _ text: String) -> [UInt8] {
            frame(0x28, [address, line] + Array(text.utf8).filter { (0x20...0x7F).contains($0) })
        }

        // --- 2. 0x6F 接続（Native Mode Enter は使わない — ここが検証の核心）---
        print("0x6F 接続を送信（Ableton 方式・Native Mode 非使用）…")
        MIDISysExSender.send(frame(0x6F, [0x01]), to: target.1)
        Thread.sleep(forTimeInterval: 0.3)

        // --- 3. 表示（メイン + ノブ 1-8）---
        MIDISysExSender.send(display(0, 0, "LL"), to: target.1)
        MIDISysExSender.send(display(0, 1, "ladyland ok?"), to: target.1)
        for knob: UInt8 in 1...8 {
            MIDISysExSender.send(display(knob, 0, "PARAM \(knob)"), to: target.1)
            MIDISysExSender.send(display(knob, 1, "test"), to: target.1)
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.5)

        var ack = 0
        var nak = 0
        for frame in inbox.drain() where frame.count > 10 && frame[1] == 0x42 {
            if frame[10] == 0x23 { ack += 1 }
            if frame[10] == 0x24 { nak += 1 }
        }
        print("応答: ACK \(ack) / NAK \(nak)（表示 18 通に対して）")
        print("--- 20 秒目視タイム: ノブ OLED に PARAM 1-8 が出ているか、")
        print("    ページボタンとノブが従来どおり動くか確認してください ---")
        Thread.sleep(forTimeInterval: 20)

        // --- 4. 切断（表示を通常に戻す）---
        MIDISysExSender.send(frame(0x6F, [0x00]), to: target.1)
        Thread.sleep(forTimeInterval: 0.3)
        print("切断済み（表示は通常に戻ったはず）")
    }

    private func displayName(of endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
        else { return nil }
        return name?.takeRetainedValue() as String?
    }
}
