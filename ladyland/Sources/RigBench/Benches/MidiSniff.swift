//! 全 MIDI ソースの生スニファ（ladyland のフィルタを一切通さない）。
//!
//! 切り分け用（2026-08-01 起点: Keystage のペダルが Debug トレースに出ない）:
//!   - ここに出ない        → 機材側が MIDI を送っていない（Keystage 設定 / 結線）
//!   - ここに出るのに
//!     ladyland に出ない   → アプリ側で落としている（MT フィルタ等）
//!
//! UMP word を MessageType 付きでそのまま印字するので、MT2（チャンネルボイス）
//! 以外で届くメッセージ — ladyland の UMP.parseChannelVoice が捨てる類 — も見える。

import CoreMIDI
import Foundation

struct MidiSniff: Bench {
    let name = "midi-sniff"
    let summary = "全ソースの生 MIDI を UMP word 単位でダンプ（既定 45 秒、SNIFF_SECONDS で延長。ペダル切り分け用）"

    func run() throws {
        var client = MIDIClientRef()
        var status = MIDIClientCreateWithBlock("rigbench-sniff" as CFString, &client, nil)
        guard status == noErr else { throw BenchError("MIDIClientCreate: \(status)") }

        // ソース名を先に列挙（コールバックからは refCon の index で引く）
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            names.append(displayName(of: MIDIGetSource(i)) ?? "(unknown \(i))")
        }
        print("sources (\(names.count)):")
        for (i, name) in names.enumerated() {
            print("  [\(i)] \(name)")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["SNIFF_SECONDS"] ?? "") ?? 45
        // リダイレクト先でも行ごとに出す — tail -f でリアルタイムに追える
        setvbuf(stdout, nil, _IOLBF, 0)
        print("--- \(Int(seconds)) 秒間ダンプ中。ペダル・鍵盤・ノブを操作してください ---")

        let start = DispatchTime.now().uptimeNanoseconds
        var port = MIDIPortRef()
        status = MIDIInputPortCreateWithProtocol(client, "sniff" as CFString, ._1_0, &port) {
            eventList, refCon in
            let sourceIndex = refCon.map { Int(bitPattern: $0) - 1 } ?? -1
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            for packet in eventList.unsafeSequence() {
                let wordCount = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuplePtr in
                    tuplePtr.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(wordCount, 64) {
                            let word = words[i]
                            // MIDI Clock (F8) は常時来て洪水になるので黙らせる
                            if word == 0x10F8_0000 { continue }
                            print(String(
                                format: "[%6dms] src%d  %@  %08X", elapsedMs, sourceIndex,
                                Self.describe(word), word))
                        }
                    }
                }
            }
        }
        guard status == noErr else { throw BenchError("MIDIInputPortCreate: \(status)") }

        for i in 0..<MIDIGetNumberOfSources() {
            MIDIPortConnectSource(
                port, MIDIGetSource(i), UnsafeMutableRawPointer(bitPattern: i + 1))
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        print("--- 終了 ---")
    }

    /// UMP 32bit word の 1 行説明（MT2 はチャンネルボイスとして詳細に、
    /// それ以外は MessageType を明示 — ladyland が捨てる類の可視化）
    static func describe(_ word: UInt32) -> String {
        let messageType = UInt8((word >> 28) & 0xF)
        guard messageType == 2 else {
            return "MT\(messageType)（ladyland は MT2 以外を捨てる）"
        }
        let statusByte = UInt8((word >> 16) & 0xFF)
        let d1 = UInt8((word >> 8) & 0x7F)
        let d2 = UInt8(word & 0x7F)
        let channel = (statusByte & 0x0F) + 1
        switch statusByte & 0xF0 {
        case 0x90 where d2 > 0: return "note on  \(d1) vel \(d2) (ch\(channel))"
        case 0x80, 0x90: return "note off \(d1) (ch\(channel))"
        case 0xB0: return "CC\(d1) = \(d2) (ch\(channel))"
        case 0xA0: return "poly AT \(d1) = \(d2) (ch\(channel))"
        case 0xD0: return "ch AT = \(d1) (ch\(channel))"
        case 0xE0: return "pitch bend (ch\(channel))"
        case 0xC0: return "program change \(d1) (ch\(channel))"
        default: return "status 0x\(String(statusByte, radix: 16, uppercase: true))"
        }
    }

    private func displayName(of endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
        else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
