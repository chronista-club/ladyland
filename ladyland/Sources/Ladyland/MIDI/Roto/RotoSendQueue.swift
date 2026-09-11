//! ROTO へ出ていく**唯一の口**。順序とペーシングだけを引き受ける。
//!
//! ⚠️ **送信経路はこの 1 本だけ**（5ms ペーシング）。
//!
//! ⚠️ 応答（learn / hello）を「遅らせないため」に即時送信の第 2 経路を
//! 作ってはいけない。**順序が壊れる** — 告知バッチ（0B 02〜08）がキューに
//! 並んでいる間に learn が追い越すと、デバイスは告知処理中の learn を捨て、
//! LCD は保存名のまま残る（実測 2026-08-03、これで半日溶かした）。
//!
//! 遅延が問題になるなら**キューを軽くする**のが正解で、追い越し車線を
//! 作るのは間違い。投影は方言ガードと面ごとの上限で軽く保つこと。
//!
//! この型を挟んだのは、その規則を**構造として**表すため —
//! `DispatchQueue` に触れる場所がここしか無ければ、第 2 経路は生えない。
//! 公式 Ableton スクリプト準拠で、main をブロックしないよう専用キューで
//! usleep する。

import CoreMIDI
import Foundation
import Lpd8Kit

/// ROTO への送信を直列化する 1 本のキュー。
///
/// 宛先（`MIDIEndpointRef`）は**呼ぶ側が持つ** — 接続状態は RotoService の
/// 領分で、ここは「並んだ順に、決まった間合いで流す」ことだけを知っている。
final class RotoSendQueue {
    /// **これがただ 1 本のキュー**。private のまま外へ出さない
    private let queue = DispatchQueue(label: "ladyland.roto.send")

    /// I/O デバッグの覗き窓（`RotoIOTap`）。送る直前に呼ばれる（送信キュー上）
    var tap: (@Sendable ([UInt8], String) -> Void)?

    /// SysEx を直列送信する（既定経路）。
    ///
    /// - Parameter gap: 1 通ごとの間合い（μs）。既定 5ms は公式 Ableton
    ///   スクリプト準拠だが、⚠️ **track 枠（0A 11）の大きな塗りは 50ms で流す**
    ///   こと — 5ms のバーストは実機を 3 回固まらせた実績があり、50ms は
    ///   一度も固まらせていない（実測 2026-08-11。Creo
    ///   `mem_1CdvSucMFyzZ4BEpFgJVpX`）
    func send(_ messages: [[UInt8]], to destination: MIDIEndpointRef, gap: UInt32 = 5_000) {
        queue.async { [tap] in
            for message in messages {
                tap?(message, "out")
                MIDISysExSender.send(message, to: destination)
                usleep(gap)
            }
        }
    }

    /// 生の短い MIDI（モーターの 14bit CC、面切替の ch7 CC）を流す。
    /// **同じキューに並ぶ** — SysEx を追い越さないことが要点。
    ///
    /// - Parameters:
    ///   - gap: 1 通ごとの間合い（μs）
    ///   - delay: 投入までの待ち（面切替は投影を終えてから届かせる）
    func sendRaw(
        _ messages: [[UInt8]], to destination: MIDIEndpointRef,
        gap: UInt32, after delay: TimeInterval = 0
    ) {
        let flush = { [tap] in
            for message in messages {
                tap?(message, "out")
                MIDISysExSender.sendRaw(message, to: destination)
                usleep(gap)
            }
        }
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay, execute: flush)
        } else {
            queue.async(execute: flush)
        }
    }
}
