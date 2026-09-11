//! **PLUGIN 面に「訊く」ベンチ**（2026-08-07 起工）。
//!
//! ## なぜ測定を先にやるか
//!
//! やりたいのは「FUNC → PLUGIN 面の LCD に `#1`〜`#8` → RK1-8 で選ぶ」。
//! これに要るのは **2 つだけ**で、どちらも「不可」ではなく **「未測定」**:
//!
//! | | 分かっていること | 分かっていないこと |
//! |---|---|---|
//! | **① PLUGIN の LCD** | learn で書き換わった実測が 1 度ある（`RotoDialect.swift:45`） | **それは Bitwig 期**。Logic 方言でも書けるか |
//! | **② RK1-8（ROTO-KEY）** | SMART 面では MIDI を出さない（実測 2026-08-07） | **PLUGIN 面では出るか** |
//!
//! ⚠️ **決め打ちで実装すると面の綱引きでまた溶ける。** 先に実機へ訊く。
//!
//! ## ② が「未測定」である根拠
//!
//! このデバイスは**面ごとに入力の意味が変わる**のが常態だ。ノブの触覚ひとつ
//! 取っても MIX 面は ch16 CC52-59、SMART/PLUGIN 面は ch15 CC64-71 と割当が
//! 違う（`docs/roto-control/protocol.md`）。**SMART で黙っていたキーが
//! PLUGIN で喋る可能性は、この機種の設計からすると十分ある。**
//!
//! ## ① の巻き添え仮説
//!
//! `RotoDialect.swift:45` にこの実測が残っている:
//!
//! > 実測 2026-08-03: **まったく同じ learn を送っても、RigBench（投影なし）は
//! > LCD が変わり、ladyland（投影 32 通）は変わらなかった**
//!
//! つまり **PLUGIN の LCD は一度は書き換わった**。ladyland 側の失敗は
//! 自分のノイズが原因だった疑いがある。**このベンチは投影を一切送らない**ので、
//! その条件を再現できる。
//!
//! ## ⚠️ 本命は d（正攻法）— ladyland は Logic で「何も告知していない」
//!
//! `RotoService` の `0B 01` 分岐は **告知を Bitwig 方言のときだけ**行う
//! （`if Self.dialect.announcesPlugins { announcePlugins() }`）。Logic では
//! `announcesPlugins == false` なので、**FUNC で PLUGIN 面へ行った瞬間、
//! ladyland はプラグインを 1 つも教えていない**。デバイスは空のカタログで
//! 面に入るので、**描くものが無い** — mako が見ている「真っ白」の説明が付く。
//!
//! ⚠️ そのコメント（「Logic 方言に PLUGIN 面は無い」）は**実機と矛盾している**。
//! Logic を名乗ったまま FUNC でも SEL でも `0B 01 01` が来ており、
//! **無いはずの面にデバイスは毎回行っている**。
//!
//! さらに 2026-08-03 の「告知と選択宣言を送っても CONTROL_MAPPED は 1 件も
//! 返らない」という否定測定には**条件が付いている** — その時点の ladyland は
//! **全面へ `0A 11` を撒いていた**（「いる面だけ塗る」は 08-04 の修正）。
//! RK1-8 のときと同じ構図で、**条件が変わっている**。
//!
//! だから **d を最初に、本試験として撃つ**。ここが通れば learn で正規に
//! ラベルが付き、mako の望む形がそのまま作れる。a〜c は保険。
//!
//! ## 使い方
//!
//! ```
//! swift run RigBench roto-plugin-probe          # Logic (3) を名乗る（ladyland と同じ）
//! swift run RigBench roto-plugin-probe bitwig   # Bitwig (2) を名乗る（比較用）
//! ```
//!
//! ⚠️ **両方言で回して比べること。** どちらで何が効いたかが分かれば、
//! 方言を替える価値があるかの判断材料になる。
//! ⚠️ ただし**このベンチは方言の変更を勧めない** — Logic を捨てると
//! `0B 13` / `0A 11` / `smartMotor` が全部死に、ここ数日の投影がまるごと落ちる。

import CoreMIDI
import Foundation
import Lpd8Kit
import RotoKit

struct RotoPluginProbe: Bench {
    let name = "roto-plugin-probe"
    let summary = "PLUGIN 面の LCD は書けるか / RK1-8 は MIDI を出すか（対話式・実機測定）"

    func run() throws {
        let dialectArg = CommandLine.arguments.dropFirst(2).first ?? "logic"
        let dawType: UInt8 = dialectArg == "bitwig" ? 2 : 3
        let dialectName = dawType == 3 ? "Logic (3)" : "Bitwig (2)"

        let client = try MIDISysExSender.makeClient("rigbench-roto-plugin")
        let destination = try MIDISysExSender.destination(matching: "Roto")
        let source = try MIDISysExSender.source(matching: "Roto")

        let tape = Tape()
        var assembler = SysEx7Assembler()
        var port = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(
            client, "roto-plugin-in" as CFString, ._1_0, &port
        ) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(count, 64) {
                            if let frame = assembler.feed(words[i]) { tape.sysex(frame) }
                            tape.short(words[i])
                        }
                    }
                }
            }
        }
        guard status == noErr else { throw BenchError("入力ポート作成に失敗: \(status)") }
        MIDIPortConnectSource(port, source, nil)

        banner("ROTO PLUGIN 面の測定 — 名乗り: \(dialectName)")
        print("""
            ⚠️ このベンチは**投影を一切送りません**（`0A 11` も `0B 13` の一括も無し）。
            　 2026-08-03 に「RigBench では LCD が変わり、ladyland では変わらなかった」
            　 という差が出ているので、その条件をわざと再現しています。

            hello には自動で応答し続けます（止めると切断扱いになるため）。
            """)

        // ── 握手 ───────────────────────────────────────────────
        // ⚠️ **応答を止めると切断される**ので、readLine() で待っている間も
        // 応答し続ける必要がある。受信の捌きを別スレッドへ逃がす
        let pump = Pump(tape: tape, destination: destination, dawType: dawType)
        pump.start()
        MIDISysExSender.sendRaw(Roto.dawStart, to: destination)
        print("→ DAW_START（\(dialectName) を名乗ります）\n")
        Thread.sleep(forTimeInterval: 2.0)
        pump.flush()

        var results: [(step: String, answer: String)] = []

        // ── PLUGIN 面へ入る ────────────────────────────────────
        banner("準備 — PLUGIN 面へ入る")
        print("""
            ROTO の **MODE** 表示を見てください。

            ① まずホストから面を指名してみます（ch7 CC101 = PLUGIN）。
            ② それで動かなければ、**実機の FUNC を押して**ください
            　 （FUNC を押すとデバイスが自分で PLUGIN 面へ行きます）。
            """)
        MIDISysExSender.sendRaw(Roto.selectFace(.plugin).flatMap { $0 }, to: destination)
        print("\n→ selectFace(.plugin) を送りました")
        wait("⚠️ **MODE が PLUGIN になったら** Enter")
        pump.flush()
        results.append(
            ("PLUGIN 面へ入れたか", ask("MODE は PLUGIN になっていますか？") ? "はい" : "いいえ"))

        // ── ② 入力の測定（先にやる。①で LCD を触る前の素の状態を見たい） ──
        banner("② PLUGIN 面で、入力は MIDI を出すか")
        print("""
            ⚠️ **測ったことがあるのは SMART 面だけ**です。この機種は面ごとに
            　 入力の割当が変わる（ノブの触覚も MIX は ch16 CC52-59、
            　 SMART/PLUGIN は ch15 CC64-71）ので、PLUGIN では出るかもしれません。

            これから 5 回に分けて、**何を触ったら何が出たか**を記録します。
            各回、指示どおり触ってから Enter を押してください。
            **何も出なくても正しい測定結果**です（それが知りたいことなので）。
            """)

        let inputSteps: [(what: String, how: String)] = [
            ("RK1-8", "**RK1〜RK8（LCD の真下の物理キー）**を、左から順に押す"),
            ("← →", "**← を 1 回、→ を 1 回**押す"),
            ("ノブ回転", "**ノブ 1（左端）を右へ半回転**させる"),
            ("ノブ押し込み", "**ノブ 1 を押し込む**（カチッと）"),
            ("ノブ接触", "**ノブ 1 に触るだけ**（回さない）"),
        ]
        for (index, step) in inputSteps.enumerated() {
            print("\n── ②-\(index + 1) \(step.what) " + String(repeating: "─", count: 34))
            print("　 \(step.how)")
            tape.markInputWindow()
            wait("触り終わったら Enter")
            let captured = tape.drainInputWindow()
            if captured.isEmpty {
                print("　 ⚠️ **1 通も来ませんでした**（= この面でも黙っている）")
                results.append(("②-\(index + 1) \(step.what)", "無反応"))
            } else {
                print("　 受信 \(captured.count) 通:")
                for line in captured { print("　   \(line)") }
                results.append(("②-\(index + 1) \(step.what)", "\(captured.count) 通"))
            }
            pump.flush()
        }

        // ── ① PLUGIN 面の LCD は書けるか ────────────────────────
        banner("① PLUGIN 面の LCD に #1〜#8 を出せるか")
        print("""
            4 通り（**d → a → b → c** の順）を試します。**1 つでも当たれば勝ち**です。

            ⚠️ **d が本命**（正攻法）。ladyland は Logic 方言だとプラグインを
            　 1 つも告知していないので、デバイスは**空のカタログで面に入って
            　 いる**疑いがあります。それが「真っ白」の正体かもしれません。

            ⚠️ 各回のあとに **8 枚の knob LCD** を見て、`#1`〜`#8` が出たかを
            　 答えてください。**一部だけ出た場合も「はい」**にして、
            　 何番が出たかをメモしておいてください（次の委譲で使います）。
            """)

        let labels = (1...8).map { "#\($0)" }

        // ── d. 正攻法 — バッチ + 選択宣言で CONTROL_MAPPED を待つ（⭐ 本命） ──
        print("\n── ①-d pluginBatch + selectPlugin（⭐ 本命・正攻法）"
            + String(repeating: "─", count: 8))
        print("""
            　 「Ladyland」を **8 ページ持つ機器**として告知し、選択を宣言します。
            　 デバイスが保存済み割当を照合して `CONTROL_MAPPED` を返してくれば、
            　 **learn で正規にラベルが付く** — mako の望む形がそのまま作れます。

            　 ⚠️ 2026-08-03 に「1 件も返らない」と測定済みですが、**あのときの
            　 ladyland は全面へ `0A 11` を撒いていました**（「いる面だけ塗る」は
            　 08-04 の修正）。RigBench は投影しないので、その条件は消えています。
            """)
        tape.markMappedWindow()
        // ⚠️ **枠付きで送る**: 0B 02 台数 → 0B 03 先頭 → 0B 05 details → 0B 06 終了。
        // その後の選択宣言（0B 08）が無いと照合が走らない
        for message in Roto.pluginBatch([Roto.PluginInfo(name: "Ladyland", pages: 8)]) {
            MIDISysExSender.sendRaw(message, to: destination)
            Thread.sleep(forTimeInterval: 0.005)
        }
        MIDISysExSender.sendRaw(Roto.selectPlugin(0, pages: 8, force: true), to: destination)
        let mappedWait: TimeInterval = 8
        print("　 → バッチ + 0B 08（pages=8）を送りました。CONTROL_MAPPED を "
            + "\(Int(mappedWait)) 秒待ちます…")

        // ⚠️ **来たら即 learn で応答する義務がある**（応答しないと LCD は付かない）。
        // hash6 は受けたものをそのまま echo する
        let waitStart = Date()
        var mapped: [Roto.ControlMapped] = []
        var firstArrival: TimeInterval?
        while Date().timeIntervalSince(waitStart) < mappedWait {
            for control in tape.drainMappedWindow() {
                if firstArrival == nil { firstArrival = Date().timeIntervalSince(waitStart) }
                mapped.append(control)
                MIDISysExSender.sendRaw(
                    Roto.learn(
                        paramIndex: control.paramIndex,
                        name: "#\(control.controlIndex + 1)",
                        value: Double(control.controlIndex) / 7,
                        hash: control.hash6),
                    to: destination)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        pump.flush()
        if mapped.isEmpty {
            // ⚠️ **何秒待って来なかったのかを必ず出す** — 「来ない」と
            // 「待ち足りなかった」は別の結論になる
            print("　 ⚠️ **CONTROL_MAPPED は \(Int(mappedWait)) 秒待って 1 通も来ませんでした**")
            results.append(("①-d CONTROL_MAPPED", "\(Int(mappedWait))秒 0 通"))
        } else {
            print(String(
                format: "　 CONTROL_MAPPED を %d 通受けて learn で応答しました（初回 %.0fms）:",
                mapped.count, (firstArrival ?? 0) * 1000))
            for control in mapped {
                print("　   param#\(control.paramIndex) → "
                    + "\(control.isSwitch ? "button" : "knob") \(control.controlIndex)")
            }
            results.append(("①-d CONTROL_MAPPED", "\(mapped.count) 通 → learn 応答"))
            results.append(
                ("①-d learn 応答後の LCD", ask("LCD に #1〜#8 は出ましたか？") ? "出た" : "出ない"))
        }

        // ── a. 無応答 learn（保険） ────────────────────────────
        print("\n── ①-a 無応答 learn（0B 0A を 8 通・保険）" + String(repeating: "─", count: 17))
        print("""
            　 doc は「learn は CONTROL_MAPPED への応答でしか送れない」と書いていますが、
            　 **それは Bitwig 期の推測**かもしれません。Logic で撃った記録が無いので撃ちます。
            """)
        for (index, label) in labels.enumerated() {
            MIDISysExSender.sendRaw(
                Roto.learn(paramIndex: index, name: label, value: Double(index) / 7),
                to: destination)
            Thread.sleep(forTimeInterval: 0.005)  // 5ms ペーシング（公式スクリプト準拠）
        }
        print("　 → learn ×8 を送りました")
        pump.flush()
        results.append(("①-a 無応答 learn", ask("LCD に #1〜#8 は出ましたか？") ? "出た" : "出ない"))

        // b. 0B 13（SMART の直接書き込み）を PLUGIN 面で
        print("\n── ①-b 0B 13 SET_PLUGIN_CTL_DETAILS（8 通）" + String(repeating: "─", count: 16))
        print("""
            　 ladyland では効かないと観測済みですが、**あれは投影を撃っていた最中**です。
            　 投影なしの RigBench なら結果が変わるか（巻き添え仮説の検証）。
            """)
        for (index, label) in labels.enumerated() {
            MIDISysExSender.sendRaw(
                Roto.setPluginControlDetails(UInt8(index), name: label), to: destination)
            Thread.sleep(forTimeInterval: 0.005)
        }
        print("　 → 0B 13 ×8 を送りました")
        pump.flush()
        results.append(("①-b 0B 13", ask("LCD に #1〜#8 は出ましたか？") ? "出た" : "出ない"))

        // c. 0B 0F setMappedControlName — 未検証
        print("\n── ①-c 0B 0F SET_MAPPED_CTL_NAME（8 通）" + String(repeating: "─", count: 19))
        print("""
            　 未検証のコマンド（`RotoProtocol.swift` の doc）。hash6 が要るので
            　 `hash6(名前)` を自前生成して撃ちます。⚠️ **本来は CONTROL_MAPPED で
            　 受けた hash を使う**ものなので当たらなくて当然ですが、安いので試します。
            """)
        for (index, label) in labels.enumerated() {
            MIDISysExSender.sendRaw(
                Roto.setMappedControlName(
                    control: index, hash: Roto.hash6(label), name: label),
                to: destination)
            Thread.sleep(forTimeInterval: 0.005)
        }
        print("　 → 0B 0F ×8 を送りました")
        pump.flush()
        results.append(("①-c 0B 0F", ask("LCD に #1〜#8 は出ましたか？") ? "出た" : "出ない"))

        // ── まとめ ─────────────────────────────────────────────
        pump.stop()
        banner("測定結果 — 名乗り: \(dialectName)")
        let width = results.map(\.step.count).max() ?? 20
        for result in results {
            let pad = String(repeating: "　", count: max(0, (width - result.step.count) / 2))
            print("  \(result.step)\(pad)  …  \(result.answer)")
        }
        print("""

            ⚠️ **もう片方の方言でも回してください**:
            　 \(dawType == 3 ? "swift run RigBench roto-plugin-probe bitwig" : "swift run RigBench roto-plugin-probe")

            この表をそのまま報告に貼れば、次に何を実装すべきかが決まります。
            """)
    }

    // MARK: - 対話の小道具

    /// ⚠️ **何を見ればいいかを毎回画面に出す。** 測定は mako が実機でやるので、
    /// 「いま何を確かめているのか」が画面から分からないと結果が濁る
    private func banner(_ title: String) {
        print("\n" + String(repeating: "═", count: 62))
        print("  \(title)")
        print(String(repeating: "═", count: 62))
    }

    private func wait(_ prompt: String) {
        print("\n\(prompt) ", terminator: "")
        _ = readLine()
    }

    /// y/n を訊く。**空 Enter は「いいえ」** — 「出たのに答え損ねた」より
    /// 「出ていないのに出たことにする」方が害が大きい（誤った実装に進む）
    private func ask(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

// MARK: - 受信テープ

/// **受信した生バイトを全部残す**（CoreMIDI スレッドから積まれる）。
///
/// ⚠️ RigBench は投影を送らないので溢れない。ladyland 側のログは値ストリームを
/// 落としているが（1 回転 100 行）、ここでは**落とさないことが目的**
private final class Tape: @unchecked Sendable {
    private let lock = NSLock()
    private var sysexFrames: [[UInt8]] = []
    private var inputWindow: [String] = []
    private var mappedWindow: [Roto.ControlMapped] = []
    private var windowOpen = false
    private var windowStart = Date()

    // MARK: 積む側（CoreMIDI スレッド）

    func sysex(_ frame: [UInt8]) {
        lock.lock()
        sysexFrames.append(frame)
        if let control = Roto.parseControlMapped(frame) { mappedWindow.append(control) }
        if windowOpen {
            inputWindow.append(
                String(format: "[%5.0fms] SysEx  %@", elapsedLocked(), Roto.describe(frame)))
        }
        lock.unlock()
    }

    /// UMP の MIDI 1.0 チャンネルボイス（MT2）。
    ///
    /// ⚠️ **CC だけに絞らない。** RK1-8 が Note や Program Change で来る
    /// 可能性を最初から捨てると、「出なかった」と「見なかった」の区別が付かない
    func short(_ word: UInt32) {
        guard (word >> 28) & 0xF == 2 else { return }
        let status = UInt8((word >> 16) & 0xFF)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        let channel = Int(status & 0x0F) + 1
        let kind: String =
            switch status & 0xF0 {
            case 0x80: "NoteOff"
            case 0x90: "NoteOn "
            case 0xA0: "PolyAT "
            case 0xB0: "CC     "
            case 0xC0: "Program"
            case 0xD0: "ChanAT "
            case 0xE0: "Bend   "
            default: "その他 "
            }
        lock.lock()
        if windowOpen {
            inputWindow.append(
                String(
                    format: "[%5.0fms] %@ ch%-2d  %3d = %3d   %@",
                    elapsedLocked(), kind, channel, data1, data2,
                    Self.label(channel: channel, cc: Int(data1), value: Int(data2),
                        isCC: status & 0xF0 == 0xB0)))
        }
        lock.unlock()
    }

    /// 既知の割当にだけ名前を付ける。**未知は「未知」と出す** —
    /// 黙って捨てると仕様の穴に気づけない（`Roto.describe` と同じ作法）
    private static func label(channel: Int, cc: Int, value: Int, isCC: Bool) -> String {
        guard isCC else { return "" }
        let pressed = value > 0 ? "押" : "離"
        if channel == 16 {
            switch cc {
            case 12...19: return "knob \(cc - 12) 回転 hi"
            case 44...51: return "knob \(cc - 44) 回転 lo"
            case 52...59: return "knob \(cc - 52) MIX touch \(pressed)"
            case 20...27: return "⭐ button \(cc - 20) \(pressed) ← **RK\(cc - 20 + 1)**"
            case 28...35: return "transport \(cc - 28) \(pressed)"
            case 36: return "⭐ ← 左"
            case 37: return "⭐ → 右"
            default: return "ch16 の未知 CC"
            }
        }
        if channel == 15 {
            switch cc {
            case 0...7: return "param \(cc) MSB"
            case 32...39: return "param \(cc - 32) LSB"
            case 64...71: return "knob \(cc - 64) 接触 \(pressed)（静電容量）"
            default: return "ch15 の未知 CC"
            }
        }
        if channel == 7 { return "command ch" }
        return "未知 ch\(channel)"
    }

    private func elapsedLocked() -> Double {
        Date().timeIntervalSince(windowStart) * 1000
    }

    // MARK: 読む側（メインスレッド）

    /// 入力の観測窓を開く（この瞬間からを 0ms とする）
    func markInputWindow() {
        lock.lock()
        inputWindow.removeAll()
        windowStart = Date()
        windowOpen = true
        lock.unlock()
    }

    func drainInputWindow() -> [String] {
        lock.lock(); defer { lock.unlock() }
        windowOpen = false
        let out = inputWindow
        inputWindow.removeAll()
        // ⚠️ hello（1 秒ごとに来る）は測定の邪魔なので窓からは除く。
        // 「触ったら何が出たか」だけを残す
        return out.filter { !$0.contains("hello") }
    }

    func markMappedWindow() {
        lock.lock()
        mappedWindow.removeAll()
        lock.unlock()
    }

    func drainMappedWindow() -> [Roto.ControlMapped] {
        lock.lock(); defer { lock.unlock() }
        let out = mappedWindow
        mappedWindow.removeAll()
        return out
    }

    /// hello への応答が要るフレームを取り出す（Pump が使う）
    func drainSysEx() -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        let out = sysexFrames
        sysexFrames.removeAll()
        return out
    }
}

// MARK: - 応答ループ

/// ⚠️ **hello への応答を止めると切断扱いになる**（実機確認 2026-08-02）。
/// このベンチは `readLine()` で人を待つので、**待っている間も応答し続ける**
/// 必要がある。だから別スレッドに逃がす
private final class Pump: @unchecked Sendable {
    private let tape: Tape
    private let destination: MIDIEndpointRef
    private let dawType: UInt8
    private var running = true
    private let lock = NSLock()
    private var pendingLines: [String] = []

    init(tape: Tape, destination: MIDIEndpointRef, dawType: UInt8) {
        self.tape = tape
        self.destination = destination
        self.dawType = dawType
    }

    func start() {
        Thread.detachNewThread { [self] in
            while isRunning {
                for frame in tape.drainSysEx() {
                    // ⚠️ hello は 1 秒ごとに来る。**印字すると画面が流れて
                    // 測定結果が見えなくなる**ので、面の遷移だけ残す
                    if Roto.isRoto(frame), frame.count >= 7,
                        !(frame[5] == 0x0A && frame[6] == 0x02) {
                        note("← \(Roto.describe(frame))")
                    }
                    for reply in Roto.autoResponse(to: frame, dawType: dawType) {
                        MIDISysExSender.sendRaw(reply, to: destination)
                    }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// ⚠️ **その場で print しない。** 別スレッドから撃つと、人への問いかけの
    /// 途中に割り込んで「何を訊かれているか」が読めなくなる。溜めておいて、
    /// メインスレッドが区切りのいいところで `flush()` する
    private func note(_ line: String) {
        lock.lock()
        pendingLines.append(line)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let lines = pendingLines
        pendingLines.removeAll()
        lock.unlock()
        guard !lines.isEmpty else { return }
        print("　 --- デバイスからの通知 ---")
        for line in lines { print("　 \(line)") }
    }
}
