//! ROTO MIDI モードのモーター同期（RotoMidiSync）。
//!
//! 「手と喧嘩しない」が本体 — 実機が喋った席は 0.3 秒黙り、明けても
//! バイト一致なら沈黙、段付きの量子化だけが補正として出る。

import Foundation
import Testing

@testable import Ladyland

@Suite("ROTO MIDI モーター同期")
struct RotoMidiSyncTests {
    private let epoch = Date(timeIntervalSince1970: 1_786_000_000)

    /// 初回はすべての割当席が差分になる（帳簿が空 = 実機の状態を知らない）
    @Test func 初回は全席が出る() {
        var sync = RotoMidiSync()
        let sends = sync.pendingSends(at: epoch) { Double($0) / 127 }
        #expect(sends.count == KnobPages.seatCount)
        #expect(sends.map(\.cc) == KnobPages.all)
        #expect(sends.map(\.byte) == KnobPages.all.map { UInt8($0) })
    }

    /// 値が変わらなければ二度目は沈黙（毎 tick 送っていたら差分送信ではない）
    @Test func 同値は送らない() {
        var sync = RotoMidiSync()
        _ = sync.pendingSends(at: epoch) { Double($0) / 127 }
        let again = sync.pendingSends(at: epoch + 1) { Double($0) / 127 }
        #expect(again.isEmpty)
    }

    /// 割当なし（nil）の席は送らない
    @Test func 割当なしは送らない() {
        var sync = RotoMidiSync()
        let sends = sync.pendingSends(at: epoch) { $0 == 5 ? 0.5 : nil }
        #expect(sends.map(\.cc) == [5])
    }

    /// 実機が喋った席はホールド中は黙る — 回している手にモーターを当てない
    @Test func 喋った席はホールド中黙る() {
        var sync = RotoMidiSync()
        _ = sync.pendingSends(at: epoch) { _ in 0.5 }
        sync.noteReceived(cc: 3, value: 100, at: epoch + 1)
        // パラメータはまだ古い値（64）— だがホールド中なので送らない
        let during = sync.pendingSends(at: epoch + 1.1) { _ in 64.0 / 127 }
        #expect(!during.contains { $0.cc == 3 })
    }

    /// ホールドが明けてバイトが違えば補正が出る（段付きの量子化を実機へ返す）
    @Test func ホールド明けの補正() {
        var sync = RotoMidiSync()
        sync.noteReceived(cc: 3, value: 100, at: epoch)
        // 適用側が 100/127 を段に丸めた（= 90/127 相当）とする
        let after = sync.pendingSends(at: epoch + 0.5) { $0 == 3 ? 90.0 / 127 : nil }
        #expect(after.count == 1)
        #expect(after.first?.cc == 3)
        #expect(after.first?.byte == 90)
    }

    /// 受信値とバイト一致ならホールド明けも沈黙 — 連続パラメータの通常運転
    @Test func 受信と一致なら明けても沈黙() {
        var sync = RotoMidiSync()
        sync.noteReceived(cc: 3, value: 64, at: epoch)
        let after = sync.pendingSends(at: epoch + 0.5) { $0 == 3 ? 64.0 / 127 : nil }
        #expect(after.isEmpty)
    }

    /// 帯の外（CC64 以上 = ペダル帯）は受信記録もしない
    @Test func 帯の外は記録しない() {
        var sync = RotoMidiSync()
        sync.noteReceived(cc: 64, value: 127, at: epoch)
        sync.noteReceived(cc: -1, value: 127, at: epoch)
        let sends = sync.pendingSends(at: epoch) { _ in nil }
        #expect(sends.isEmpty)
    }

    /// レーンは席集合を注入できる（ミキサーレーン = CC0-31）。
    /// レーン外の CC は送信候補にも受信記録にも入らない
    @Test func 席集合の注入() {
        var mixer = RotoMidiSync(seats: Array(0..<32))
        mixer.noteReceived(cc: 40, value: 1, at: epoch)  // レーン外 — 無視
        let sends = mixer.pendingSends(at: epoch) { _ in 0.5 }
        #expect(sends.count == 32)
        #expect(sends.map(\.cc) == Array(0..<32))
    }

    /// forgetSent は送信記憶だけ捨てる — 全席が再送候補に戻るが、
    /// hold（回し中の席）は残って手と喧嘩しない
    @Test func forgetSentはholdを残す() {
        var sync = RotoMidiSync()
        _ = sync.pendingSends(at: epoch) { _ in 0.5 }
        sync.noteReceived(cc: 3, value: 100, at: epoch + 1)
        sync.forgetSent()
        let sends = sync.pendingSends(at: epoch + 1.1) { _ in 0.5 }
        #expect(sends.count == KnobPages.seatCount - 1)  // 全席再送、ただし
        #expect(!sends.contains { $0.cc == 3 })  // 回し中の席は黙ったまま
    }

    /// reset で帳簿が消え、全席がもう一度出る（差し直し = 実機を信用しない）
    @Test func リセットで全席やり直し() {
        var sync = RotoMidiSync()
        _ = sync.pendingSends(at: epoch) { _ in 0.5 }
        sync.reset()
        let again = sync.pendingSends(at: epoch + 1) { _ in 0.5 }
        #expect(again.count == KnobPages.seatCount)
    }

    /// 正規化値は 0-1 に丸めてから 7bit 化（範囲外のパラメータ値で壊れない)
    @Test func 範囲外の値は丸める() {
        var sync = RotoMidiSync()
        let sends = sync.pendingSends(at: epoch) { $0 == 0 ? 1.5 : ($0 == 1 ? -0.5 : nil) }
        #expect(sends.map(\.cc) == [0, 1])
        #expect(sends.map(\.byte) == [127, 0])
    }
}
