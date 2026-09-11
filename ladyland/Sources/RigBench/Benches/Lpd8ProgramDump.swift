//! LPD8 mk2 プログラムダンプ（ゴールデン採取ベンチ）。
//!
//! GET (0x03) をプログラム 1-4 に送り、応答 SysEx を hex ダンプする。
//! VP doc 22 §3 の未確定部分（entry 順・Flags bit・on/off 色の並び）を
//! 実機バイトで pin するための道具。出力の hex は Lpd8ProgramTests の
//! ゴールデンとしてそのまま貼れる形式で出す。

import CoreMIDI
import Foundation
import Lpd8Kit

struct Lpd8ProgramDump: Bench {
    let name = "lpd8-program-dump"
    let summary = "LPD8 mk2 のプログラム 1-4 を GET (0x03) して hex ダンプ（ゴールデン採取）"

    func run() throws {
        let client = try MIDISysExSender.makeClient("rigbench-dump")
        let dest = try MIDISysExSender.destination(matching: "LPD8")
        let source = try MIDISysExSender.source(matching: "LPD8")

        let collector = FrameCollector()
        var port = MIDIPortRef()
        var assembler = SysEx7Assembler()
        let status = MIDIInputPortCreateWithProtocol(
            client, "dump-in" as CFString, ._1_0, &port
        ) { eventList, _ in
            // ポートのコールバックは直列 — assembler の状態はここに閉じ込める
            for packet in eventList.unsafeSequence() {
                let wordCount = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuplePtr in
                    tuplePtr.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(wordCount, 64) {
                            if let frame = assembler.feed(words[i]) {
                                collector.add(frame)
                            }
                        }
                    }
                }
            }
        }
        guard status == noErr else {
            print("入力ポート作成に失敗 (\(status))")
            return
        }
        MIDIPortConnectSource(port, source, nil)

        for program in 1...4 {
            let before = collector.count
            print("=== program \(program): GET 送信 ===")
            MIDISysExSender.send(Lpd8SysEx.programGetRequest(program: program), to: dest)

            // 応答待ち（最大 2 秒）
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while collector.count == before,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard collector.count > before else {
                print("  (応答なし)")
                continue
            }
            for frame in collector.drain() {
                dump(frame)
            }
        }
    }

    /// ゴールデンとしてテストに貼れる形式で出す
    private func dump(_ frame: [UInt8]) {
        print("  \(frame.count) bytes:")
        for row in stride(from: 0, to: frame.count, by: 16) {
            let slice = frame[row..<min(row + 16, frame.count)]
            let hex = slice.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            print("    \(hex),")
        }
    }
}

/// 受信フレームの収集箱（CoreMIDI スレッドから書かれる）
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    func add(_ frame: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        frames.append(frame)
    }

    func drain() -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        let out = frames
        frames = []
        return out
    }
}
