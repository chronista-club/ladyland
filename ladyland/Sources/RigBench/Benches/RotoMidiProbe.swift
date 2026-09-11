//! ROTO-CONTROL **MIDI モード**の観測ベンチ（2026-08-11 起工 — 方向転換の初日）。
//!
//! DAW セッション機構（握手・モデル宣言・フラッシュ確定）との戦いを捨て、
//! 素の CC で完結する MIDI モードを本線にする（mako 発案 2026-08-11 深夜）。
//! 握手が要らないので、RotoProbe と違って応答ループを持たない —
//! リスナーを張って、送って、目で見る。それだけの一番単純な形。
//!
//! 確認したいこと（方向転換メモの「次回の確認 2 点」）:
//!   ① モーター追従 — 外から CC を送るとノブが動くか。動けば音量の双方向が成立
//!   ② SEL のセットアップ切替 — 切り替えた瞬間に何が届くか。席 CC が変わる
//!      だけなら Keystage の KnobPages と同型で美しい
//!
//! 段階:
//!   swift run RigBench roto-midi                 watch: 受信を全部帳簿化（60 秒）。
//!                                                実機側で SEL 切替 / ノブ回し / タッチ /
//!                                                ボタン押下を試すと、届くものが全部並ぶ
//!   swift run RigBench roto-midi motor [ch] [cc] ① の検証: 指定席へ階段値を送る。
//!                                                既定 ch1 cc0（Export All の実物が
//!                                                knob を "CH:1/CC:0" と名付けていた席）
//!   swift run RigBench roto-midi sweep [ch]      席の発見: CC0-31 へ「値 = CC×4」を
//!                                                送る。追従があればノブの位置が
//!                                                CC 番号の階段になって見える
//!
//! clock も数える — DAW モードでは毎秒 24 発が生存信号だった。MIDI モードで
//! 出るかどうか自体が観測成果（出なければモード判別信号として使える）。

import CoreMIDI
import Foundation
import Lpd8Kit
import RotoKit

struct RotoMidiProbe: Bench {
    let name = "roto-midi"
    let summary = "MIDI モードの観測（watch / motor [ch] [cc] / sweep [ch]）— 握手なし・素の CC"

    func run() throws {
        let stage = CommandLine.arguments.dropFirst(2).first ?? "watch"
        guard ["watch", "motor", "sweep", "lcd"].contains(stage) else {
            throw BenchError("'\(stage)' という段階は無い。あるもの: watch, motor, sweep, lcd")
        }
        let client = try MIDISysExSender.makeClient("rigbench-roto-midi")
        // 差し直しの最中に起動しても死なない — 実機が生えるまで待つ
        // （観測時間には数えない。挿さった瞬間から本編が始まる）
        if (try? MIDISysExSender.source(matching: "Roto")) == nil {
            print("Roto が見えない — 挿さるのを待ちます（最大 60 秒）")
            let waitStart = Date()
            while Date().timeIntervalSince(waitStart) < 60,
                (try? MIDISysExSender.source(matching: "Roto")) == nil {
                sleep(1)
            }
        }
        let destination = try MIDISysExSender.destination(matching: "Roto")
        let source = try MIDISysExSender.source(matching: "Roto")

        let log = MidiModeLog()
        var assembler = SysEx7Assembler()
        var port = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(
            client, "roto-midi-in" as CFString, ._1_0, &port
        ) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(count, 64) {
                            if let frame = assembler.feed(words[i]) {
                                log.sysEx(frame)
                            }
                            log.word(words[i])
                        }
                    }
                }
            }
        }
        guard status == noErr else { throw BenchError("入力ポート作成に失敗: \(status)") }
        MIDIPortConnectSource(port, source, nil)

        print("段階: \(stage) — 実機を MIDI モードにしておいてください（MODE ボタン）")
        switch stage {
        case "motor":
            print("ノブを見ていてください — 送った値に動けば追従あり（音量の双方向が成立）\n")
        case "sweep":
            print("追従があれば、ノブ位置が CC 番号の階段状に並びます\n")
        default:
            print("SEL 切替 / ノブ回し / タッチ / ボタン / MODE 切替を試してください\n")
        }

        let steps = script(stage: stage)
        if stage == "sweep" {
            print("→ 3 秒後に CC0-31 へ階段値（値 = CC×4）を撒きます")
        }

        // 差し直し（USB 抜き差し）でエンドポイントが替わるので、定期的に
        // 引き直して張り替える（DAW モードの roto-live と同じ作法）。
        // 古いエンドポイントへの接続は死ぬだけで害はない
        var connectedSource = source
        var lastReconnectCheck = Date()

        let start = Date()
        // watch は秒数を指定できる（roto-midi watch 120）— 差し直しや実機操作を
        // 挟む観測で、60 秒固定だと開始タイミングの行き違いが繰り返し起きた
        let duration: TimeInterval =
            stage == "watch"
            ? TimeInterval(
                CommandLine.arguments.dropFirst(3).first.flatMap(Int.init) ?? 60)
            : 15
        let sysExSteps = stage == "lcd" ? lcdScript() : []
        if stage == "lcd" {
            print("→ MAIN LCD を見ていてください — 3 通のどれで表示が変わるか")
        }
        var nextStep = 0
        var nextSysEx = 0
        while Date().timeIntervalSince(start) < duration {
            let elapsed = Date().timeIntervalSince(start)
            while nextStep < steps.count, steps[nextStep].fireAt <= elapsed {
                let step = steps[nextStep]
                nextStep += 1
                MIDISysExSender.sendRaw(step.bytes, to: destination)
                if !step.label.isEmpty {
                    print("[\(Int(elapsed * 1000))ms] → \(step.label)")
                }
            }
            while nextSysEx < sysExSteps.count, sysExSteps[nextSysEx].fireAt <= elapsed {
                let step = sysExSteps[nextSysEx]
                nextSysEx += 1
                MIDISysExSender.send(step.frame, to: destination)
                print("[\(Int(elapsed * 1000))ms] → \(step.label)")
            }
            for line in log.drainLines() {
                print(line)
            }
            if Date().timeIntervalSince(lastReconnectCheck) > 2 {
                lastReconnectCheck = Date()
                if let fresh = try? MIDISysExSender.source(matching: "Roto"),
                    fresh != connectedSource {
                    connectedSource = fresh
                    MIDIPortConnectSource(port, fresh, nil)
                    print("[\(Int(elapsed * 1000))ms] → 差し直しを検知 — ソースを張り替えた")
                }
            }
            usleep(10_000)
        }

        print("\n--- 終了 ---")
        for line in log.summary() {
            print(line)
        }
    }

    private struct Step {
        let fireAt: TimeInterval
        let label: String
        let bytes: [UInt8]
    }

    private func script(stage: String) -> [Step] {
        let args = CommandLine.arguments.dropFirst(3).compactMap { Int($0) }
        switch stage {
        case "motor":
            let ch = min(max(args.first ?? 1, 1), 16)
            let cc = min(max(args.dropFirst().first ?? 0, 0), 127)
            let status = UInt8(0xB0 | (ch - 1))
            // 端 → 端 → 中間、の順。追従が「一瞬で飛ぶ」のか「滑らかに走る」のかも見る
            return [127, 0, 64, 32, 96].enumerated().map { i, value in
                Step(
                    fireAt: 3 + Double(i) * 2,
                    label: "ch\(ch) CC\(cc)=\(value) を送信 — ノブは動きましたか",
                    bytes: [status, UInt8(cc), UInt8(value)])
            }
        case "sweep":
            let ch = min(max(args.first ?? 1, 1), 16)
            let status = UInt8(0xB0 | (ch - 1))
            return (0..<32).map { cc in
                Step(
                    fireAt: 3 + Double(cc) * 0.15,
                    label: "",  // 32 行は多い — 事前の 1 行告知で足りる
                    bytes: [status, UInt8(cc), UInt8(cc * 4)])
            }
        case "lcd":
            // MAIN LCD の背景色プローブ（2026-08-12）: DAW モードの表示制御
            // SysEx（0A 16 = 名前 / 0A 17 = 地色 RGB / 0C 0A = 名前 + RGB）が
            // **MIDI モードでも効くか**。表示の所有権はモードが握っているはずで
            // 期待薄だが、効けば冊名の地色が塗れる（mako 要望「二行目の背景色」）。
            // 送るのは表示系のみ — セッション状態を持つメッセージは混ぜない
            return []  // SysEx は下（scriptSysEx）で送る — sendRaw は 3 バイト CC 用
        default:
            return []
        }
    }

    /// lcd ステージの SysEx 台本（fireAt 秒, ラベル, フレーム）
    func lcdScript() -> [(fireAt: TimeInterval, label: String, frame: [UInt8])] {
        [
            (2, "0A 16 — MENU 名前だけ「LADYLAND」", Roto.setMenuText("LADYLAND")),
            (5, "0A 17 — MENU 地色だけ（オレンジ）", Roto.setMenuColor(red: 255, green: 120, blue: 0)),
            (8, "0C 0A — 名前 + RGB を据える（シアン）",
             Roto.selectFocusTrack(0, name: "LL MIXER", red: 0, green: 200, blue: 255)),
        ]
    }
}

/// 受信の帳簿（CoreMIDI スレッドから積まれる）。
/// 行の生成と集計を両方持つ — SEL 切替の観測では「切替の瞬間に何が来たか」
/// （リアルタイム行）と「結局どの席から何が届いたか」（終了時サマリ）の
/// 両方が要るため
private final class MidiModeLog: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var lines: [String] = []

    private struct TallyKey: Hashable {
        let channel: Int
        let kind: String
        let number: Int
    }
    private var tally: [TallyKey: (count: Int, last: UInt8)] = [:]
    private var clockCount = 0
    private var firstClock: Date?
    private var lastClock: Date?
    private var sysExCount = 0

    private func push(_ text: String) {
        let stamp = "[\(Int(Date().timeIntervalSince(start) * 1000))ms]"
        lock.lock()
        lines.append("\(stamp) \(text)")
        lock.unlock()
    }

    func word(_ word: UInt32) {
        let messageType = (word >> 28) & 0xF
        // MT1 = System Real Time / Common — clock (F8) はここに来る
        if messageType == 1 {
            let status = UInt8((word >> 16) & 0xFF)
            if status == 0xF8 {
                clock()
            } else if status != 0xFE {  // Active Sensing は帳簿を埋めるだけなので捨てる
                push("← system \(String(format: "%02X", status))")
            }
            return
        }
        guard messageType == 2 else { return }
        let status = UInt8((word >> 16) & 0xFF)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0:
            count(TallyKey(channel: channel, kind: "CC", number: Int(data1)), value: data2)
            push("← ch\(channel) CC\(data1)=\(data2)")
        case 0xC0:
            // SEL のセットアップ切替が Program Change を撒く可能性が本命
            count(TallyKey(channel: channel, kind: "PC", number: -1), value: data1)
            push("← ch\(channel) ProgramChange \(data1)")
        case 0x90:
            push("← ch\(channel) noteOn \(data1) vel\(data2)")
        case 0x80:
            push("← ch\(channel) noteOff \(data1)")
        case 0xE0:
            push("← ch\(channel) bend \((Int(data2) << 7) | Int(data1))")
        default:
            push("← ch\(channel) \(String(format: "%02X %02X %02X", status, data1, data2))")
        }
    }

    func sysEx(_ frame: [UInt8]) {
        lock.lock()
        sysExCount += 1
        lock.unlock()
        // MIDI モードで SysEx は稀（モード通知くらいのはず）なので、
        // 後の盗聴に備えて hex を必ず添える
        let hex = frame.map { String(format: "%02X", $0) }.joined(separator: " ")
        if Roto.isRoto(frame) {
            push("← SysEx \(Roto.describe(frame))  [\(hex)]")
        } else {
            push("← SysEx(\(frame.count)B) [\(hex)]")
        }
    }

    private func clock() {
        let now = Date()
        lock.lock()
        clockCount += 1
        let first = firstClock == nil
        let gap = lastClock.map { now.timeIntervalSince($0) }
        if firstClock == nil { firstClock = now }
        lastClock = now
        lock.unlock()
        if first {
            push("← MIDI clock 開始（DAW モードと同じ生存信号）")
        } else if let gap, gap > 2 {
            push("← MIDI clock 再開（\(String(format: "%.1f", gap)) 秒途絶していた）")
        }
    }

    private func count(_ key: TallyKey, value: UInt8) {
        lock.lock()
        tally[key] = ((tally[key]?.count ?? 0) + 1, value)
        lock.unlock()
    }

    func drainLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = lines
        lines.removeAll()
        return out
    }

    func summary() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String] = []
        if clockCount > 0, let first = firstClock, let last = lastClock {
            let span = last.timeIntervalSince(first)
            let rate = span > 0 ? Double(clockCount - 1) / span : 0
            out.append("clock: \(clockCount) 発（≈\(String(format: "%.1f", rate))/秒）")
        } else {
            out.append("clock: 0 発 — MIDI モードは clock を出さない、が観測結果")
        }
        out.append("SysEx: \(sysExCount) 件")
        if !tally.isEmpty {
            out.append("届いた席の内訳:")
            let sorted = tally.sorted {
                ($0.key.channel, $0.key.kind, $0.key.number)
                    < ($1.key.channel, $1.key.kind, $1.key.number)
            }
            for (key, entry) in sorted {
                let name = key.kind == "PC" ? "PC" : "CC\(key.number)"
                out.append("  ch\(key.channel) \(name): \(entry.count) 回（最終値 \(entry.last)）")
            }
        }
        return out
    }
}
