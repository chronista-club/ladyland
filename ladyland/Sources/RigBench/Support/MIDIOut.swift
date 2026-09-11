//! ベンチ用の送信ラッパ — Lpd8Kit.MIDISysExSender に Stats 計測を被せる。
//!
//! 送信実体とエンドポイント解決は Lpd8Kit（本体と共用）。ここはベンチ固有の
//! 統計（滞留 = バックプレッシャ、完了遅延）を積むだけの薄い層。

import CoreMIDI
import Foundation
import Lpd8Kit

enum MIDIOut {
    static func makeClient(_ name: String) throws -> MIDIClientRef {
        try MIDISysExSender.makeClient(name)
    }

    static func destination(matching fragment: String) throws -> MIDIEndpointRef {
        try MIDISysExSender.destination(matching: fragment)
    }

    /// SysEx を非同期送信し、送信直後の滞留数を返す。完了遅延は stats に記録される
    @discardableResult
    static func sendSysex(_ bytes: [UInt8], to dest: MIDIEndpointRef, stats: Stats) -> Int {
        let outstanding = stats.onSend()
        MIDISysExSender.send(bytes, to: dest) { ms in
            stats.onComplete(latencyMs: ms)
        }
        return outstanding
    }
}
