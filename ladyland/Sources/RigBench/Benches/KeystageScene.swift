//! Keystage の Scene / Global Dump を吸い出して中身を読む（**読むだけ**）。
//!
//! なぜ要るか: Arp / Chord の設定は Func 2B/41 では触れず（あれは BPM 専用 —
//! 実装チャート TABLE 3 で確認）、**Dump を丸ごと吸って書き換えて戻す**しかない。
//! その前に「表のオフセットが実機と合っているか」を目で確かめる。
//! ROTO で「資料と実機が違う」を何度も踏んだので、書き込む前に読む。
//!
//! ⚠️ **書き戻しは一切しない**。実機を触っている最中に走らせても設定は変わらない。
//!
//!   swift run RigBench keystage-scene         Scene Dump（Arp / Chord 設定）
//!   swift run RigBench keystage-scene global  Global Dump（User Chord Set）
//!   swift run RigBench keystage-scene watch   **変化したバイトを実時間で出す**
//!                                             （本体を操作して在り処を特定する）
//!   swift run RigBench keystage-scene burn    **ボタン / エンコーダーの CC を焼く**
//!                                             （⚠️ ladyland を終了してから）

import CoreMIDI
import Foundation
import KeystageKit
import Lpd8Kit

struct KeystageScene: Bench {
    let name = "keystage-scene"
    let summary = "Scene / Global Dump を吸い出して Arp・Chord 設定を読む（書き込みなし）"

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

    /// 既知の Scene オフセット（実装チャート TABLE 1）。
    /// **ここに無いものが動いたら、それが未知のパラメータ** — ARP / CHORD の
    /// on/off がどこにあるかは表に載っていないので、差分から探す
    private static let sceneNames: [Int: String] = [
        31: "Arp Mode", 32: "Arp Octave", 33: "Arp Latch", 34: "Arp KeySync",
        35: "Arp Rate", 36: "Arp Swing", 37: "Arp Pattern",
        38: "Ratchet Ctrl", 39: "Ratchet Thresh", 40: "Ratchet Speed", 41: "Ratchet Cycle",
        42: "Gate Time", 43: "Gate Ctrl", 44: "Gate Depth",
        45: "Arp Velocity", 46: "Arp Chance",
        47: "Chord Set", 48: "Strum Time", 49: "Strum Dir",
        50: "Kbd MIDI Ch", 51: "Kbd Octave", 52: "Kbd Transpose",
        53: "Wheel MIDI Ch", 54: "Wheel Lower", 55: "Wheel Upper",
    ]

    private func label(_ offset: Int) -> String {
        if let known = Self.sceneNames[offset] { return known }
        if offset < 10 { return "Scene 名" }
        if (10...17).contains(offset) { return "ノブ \(offset - 9) の User Page" }
        if (18...25).contains(offset) { return "Arp User Page ノブ\(offset - 17)" }
        if (26...28).contains(offset) { return "Modulation Mapping" }
        if (62...445).contains(offset) { return "Knob 割当 \((offset - 62) / 3 + 1)" }
        return "★未知★"
    }

    func run() throws {
        let arg = CommandLine.arguments.dropFirst(2).first
        let wantsGlobal = arg == "global"
        let wantsWatch = arg == "watch"
        let wantsWrite = arg == "write"
        let wantsBurn = arg == "burn"

        var client = MIDIClientRef()
        guard MIDIClientCreateWithBlock("rigbench-kscene" as CFString, &client, nil) == noErr
        else { throw BenchError("MIDIClientCreate に失敗") }

        let inbox = Inbox()
        var inPort = MIDIPortRef()
        // ⚠️ **アセンブラはコールバックの外**で作る。中で作ると呼ばれるたびに
        // 状態がリセットされ、**複数コールバックに跨る長い SysEx が永久に
        // 組み上がらない**（実測 2026-08-04: 短い Inquiry 応答だけ届き、
        // Dump は 1 本も来なかった）
        var assembler = SysEx7Assembler()
        let status = MIDIInputPortCreateWithProtocol(
            client, "kscene-in" as CFString, ._1_0, &inPort
        ) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let wordCount = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(wordCount, 64) {
                            if let frame = assembler.feed(words[i]) { inbox.add(frame) }
                        }
                    }
                }
            }
        }
        guard status == noErr else { throw BenchError("入力ポート作成に失敗: \(status)") }
        for i in 0..<MIDIGetNumberOfSources() where
            (displayName(of: MIDIGetSource(i)) ?? "").contains("Keystage")
        {
            MIDIPortConnectSource(inPort, MIDIGetSource(i), nil)
        }

        var destinations: [(String, MIDIEndpointRef)] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            if let name = displayName(of: dest), name.contains("Keystage") {
                destinations.append((name, dest))
            }
        }
        guard let target = destinations.first(where: { $0.0.contains("DAW") })
            ?? destinations.first
        else { throw BenchError("Keystage の宛先が見つからない") }
        print("送信先: \(target.0)")

        _ = try MIDISysExSender.makeClient("rigbench-kscene-out")

        // --- Device Inquiry で global ch と機種を判別 ---
        MIDISysExSender.send([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], to: target.1)
        Thread.sleep(forTimeInterval: 1.0)

        var globalCh: UInt8 = 0
        var model = Keystage.Model.keys49
        for frame in inbox.drain() where frame.count >= 10 && frame[1] == 0x7E && frame[5] == 0x42 {
            globalCh = frame[2] & 0x0F
            model = frame[8] == 0x09 ? .keys61 : .keys49
            print("Inquiry: global ch \(globalCh + 1) / \(model == .keys61 ? "61鍵" : "49鍵")")
        }

        // --- Dump 要求 ---
        // ⚠️ **0x6F 接続を先に送る**。Device Inquiry には素で答えるが、
        // Dump は接続後でないと沈黙する疑い（KeystageOled の表示も 0x6F 前提）。
        // どのポートが正解かも実測で決めたいので、宛先を順に試す
        let request: Keystage.Func = wantsGlobal ? .globalDumpRequest : .sceneDumpRequest
        let expected: Keystage.Func = wantsGlobal ? .globalDump : .sceneDump

        var dump: [UInt8]?
        var candidates = destinations
        // DAW ポートを先頭に寄せる（公式スクリプトの実証と同じ優先）
        candidates.sort { $0.0.contains("DAW") && !$1.0.contains("DAW") }

        for (label, endpoint) in candidates {
            print("\n── 宛先: \(label) ──")
            print("→ 0x6F 接続")
            MIDISysExSender.send(
                Keystage.frame(.connect, data: [0x01], globalChannel: globalCh, model: model),
                to: endpoint)
            Thread.sleep(forTimeInterval: 0.3)
            _ = inbox.drain()

            print("→ \(wantsGlobal ? "Global" : "Scene") Dump Request（Func \(String(format: "%02X", request.rawValue))）")
            MIDISysExSender.send(
                Keystage.frame(request, globalChannel: globalCh, model: model), to: endpoint)
            Thread.sleep(forTimeInterval: 1.5)

            for frame in inbox.drain() {
                guard let function = Keystage.function(of: frame) else {
                    print("←（Keystage 以外 / 解読不能）\(frame.count) byte")
                    continue
                }
                if function == expected, let payload = Keystage.payload(of: frame) {
                    print("← \(expected) 受信: SysEx \(frame.count) byte / payload \(payload.count) byte")
                    dump = Keystage.decode7bit(payload)
                } else if function == .nak {
                    print("← NAK — 要求が拒否された")
                } else {
                    print("← Func \(String(format: "%02X", function.rawValue))")
                }
            }
            // 接続は戻しておく（実機の状態を変えたままにしない）
            MIDISysExSender.send(
                Keystage.frame(.connect, data: [0x00], globalChannel: globalCh, model: model),
                to: endpoint)
            if dump != nil { break }
        }

        guard let data = dump else {
            print("\n⚠️ Dump が返ってこなかった。ポート（DAW 側 / KBD 側）と global ch を疑う")
            return
        }
        print("デコード後: \(data.count) byte\n")

        if wantsWatch {
            watchChanges(
                baseline: data, inbox: inbox, target: target.1,
                globalCh: globalCh, model: model)
            return
        }
        if wantsBurn {
            burnControls(
                baseline: data, inbox: inbox, target: target.1,
                globalCh: globalCh, model: model)
            return
        }
        if wantsWrite {
            writeTest(
                baseline: data, inbox: inbox, target: target.1,
                globalCh: globalCh, model: model)
            return
        }
        if wantsGlobal {
            printUserChordSets(data)
        } else {
            printSceneParameters(data)
        }
    }

    /// **ボタンとエンコーダーの CC を ladyland の規約で焼く**（mako 2026-08-05
    /// 「これそちらもできるような IF ないかな？」）。
    ///
    /// ladyland の GUI ボタンと同じことを CLI からやる。エージェントが実行できる
    /// ようにするのが目的 — GUI は人にしか押せない。
    ///
    /// ⚠️ **ladyland を終了してから実行すること**。CoreMIDI に排他制御は無いので
    /// 両方が Keystage に繋がれるが、Scene Dump を同時に書くと壊れる
    private func burnControls(
        baseline: [UInt8], inbox: Inbox, target: MIDIEndpointRef,
        globalCh: UInt8, model: Keystage.Model
    ) {
        let before =
            (Keystage.ButtonOffset.Button.allCases.map {
                "\($0.label)=\(Keystage.buttonCC(baseline, $0).map(String.init) ?? "—")"
            }
            + Keystage.EncoderOffset.Encoder.allCases.map {
                "\($0.label)=\(Keystage.encoderCC(baseline, $0).map(String.init) ?? "—")"
            }).joined(separator: " ")
        print("前: \(before)")

        let dump = Keystage.applyingLadylandButtons(baseline)
        let after =
            (Keystage.ButtonOffset.Button.allCases.map {
                "\($0.label)=\(Keystage.buttonCC(dump, $0).map(String.init) ?? "—")"
            }
            + Keystage.EncoderOffset.Encoder.allCases.map {
                "\($0.label)=\(Keystage.encoderCC(dump, $0).map(String.init) ?? "—")"
            }).joined(separator: " ")
        print("後: \(after)")

        _ = inbox.drain()
        MIDISysExSender.send(
            Keystage.frame(
                .sceneDump, data: Keystage.encode7bit(dump),
                globalChannel: globalCh, model: model),
            to: target)
        Thread.sleep(forTimeInterval: 0.5)
        for received in inbox.drain() where Keystage.function(of: received) == .nak {
            print("⚠️ NAK — 書き込みが拒否された")
            return
        }

        // ⚠️ **Write Request を送らないと current scene にしか載らない**
        // （Dump の二重構造。KONTROL EDITOR が読むのは internal memory）
        print("Scene 0 へ保存する（Write Request）")
        MIDISysExSender.send(
            Keystage.frame(
                .sceneWriteRequest, data: [0], globalChannel: globalCh, model: model),
            to: target)
        Thread.sleep(forTimeInterval: 1.0)
        var saved = false
        for received in inbox.drain() {
            switch Keystage.function(of: received) {
            case .writeComplete: saved = true
            case .writeError:
                print("⚠️ 保存に失敗した（Write Error）")
                return
            default: break
            }
        }
        print(saved ? "✓ 焼き終えた（保存済み）" : "⚠️ 保存の応答が返らなかった")
    }

    /// Dump を繰り返し取って、変化したバイトを出し続ける。
    /// **本体を操作しながら見ると、そのパラメータの在り処が分かる**
    private func watchChanges(
        baseline: [UInt8], inbox: Inbox, target: MIDIEndpointRef,
        globalCh: UInt8, model: Keystage.Model
    ) {
        print("── 監視開始（60 秒）──")
        print("本体で ARP / CHORD ボタンを押したり設定を変えてください。")
        print("変わったバイトをここに出します。★未知★ が出たら、それが表に無いパラメータ。\n")

        var previous = baseline
        let start = Date()
        var round = 0

        while Date().timeIntervalSince(start) < 60 {
            Thread.sleep(forTimeInterval: 1.2)
            round += 1
            _ = inbox.drain()
            MIDISysExSender.send(
                Keystage.frame(.sceneDumpRequest, globalChannel: globalCh, model: model),
                to: target)
            Thread.sleep(forTimeInterval: 0.8)

            var current: [UInt8]?
            for frame in inbox.drain() {
                guard Keystage.function(of: frame) == .sceneDump,
                    let payload = Keystage.payload(of: frame)
                else { continue }
                current = Keystage.decode7bit(payload)
            }
            guard let data = current else { continue }

            let elapsed = Int(Date().timeIntervalSince(start))
            var changes = 0
            for offset in 0..<min(data.count, previous.count)
            where data[offset] != previous[offset] {
                changes += 1
                print(
                    String(
                        format: "[%3ds] offset %3d: %3d → %3d   %@",
                        elapsed, offset, previous[offset], data[offset], label(offset)))
            }
            if data.count != previous.count {
                print("[\(elapsed)s] ⚠️ Dump の長さが変わった: \(previous.count) → \(data.count)")
            }
            if changes > 0 { print("") }
            previous = data
        }
        print("── 監視終了（\(round) 回サンプル）──")
        print("何も出なかったなら、その操作は **Scene Dump に載らない**（揮発 or Global 側）")
    }

    private func displayName(of endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
        else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// **書き込みの実証**（Chord Set Num を 1 バイトだけ変えて、戻す）。
    ///
    /// 手順は ② も ③ も同じ: Dump を取る → decode → 該当バイトを書き換え →
    /// encode → 同じ Func で送り返す → ACK。ここが通れば経路は丸ごと開通する
    private func writeTest(
        baseline: [UInt8], inbox: Inbox, target: MIDIEndpointRef,
        globalCh: UInt8, model: Keystage.Model
    ) {
        // **Transpose を使う** — 画面のどこを見ればいいか探さなくても、
        // 鍵盤を弾けば音程で分かる。1 バイトの書き換えという点は Chord Set と同じ
        let offset = Keystage.SceneOffset.keyboardTranspose
        guard baseline.indices.contains(offset) else {
            print("⚠️ Dump が短すぎて offset \(offset) に届かない")
            return
        }
        let original = baseline[offset]
        // 0-24 = -12…+12（12 = ±0）。1 オクターブずらす
        let probe: UInt8 = original >= 12 ? original - 12 : original + 12

        func describe(_ value: UInt8) -> String {
            let semitones = Int(value) - 12
            return "\(semitones > 0 ? "+" : "")\(semitones) 半音"
        }

        /// Dump を送り返して ACK を待つ
        func write(_ data: [UInt8], label: String) -> Bool {
            _ = inbox.drain()
            let payload = Keystage.encode7bit(data)
            let frame = Keystage.frame(
                .sceneDump, data: payload, globalChannel: globalCh, model: model)
            print("→ \(label): Scene Dump 送信（SysEx \(frame.count) byte）")
            MIDISysExSender.send(frame, to: target)
            Thread.sleep(forTimeInterval: 1.5)
            for received in inbox.drain() {
                switch Keystage.function(of: received) {
                case .ack:
                    print("← ACK")
                    return true
                case .nak:
                    print("← NAK — 拒否された")
                    return false
                case .some(let other):
                    print("← Func \(String(format: "%02X", other.rawValue))")
                default:
                    break
                }
            }
            print("←（応答なし）")
            return false
        }

        /// 読み直して該当バイトを確かめる
        func readBack() -> UInt8? {
            _ = inbox.drain()
            MIDISysExSender.send(
                Keystage.frame(.sceneDumpRequest, globalChannel: globalCh, model: model),
                to: target)
            Thread.sleep(forTimeInterval: 1.2)
            for received in inbox.drain() {
                guard Keystage.function(of: received) == .sceneDump,
                    let payload = Keystage.payload(of: received)
                else { continue }
                let data = Keystage.decode7bit(payload)
                return data.indices.contains(offset) ? data[offset] : nil
            }
            return nil
        }

        print("── 書き込みテスト: Keyboard Transpose（offset \(offset)）──")
        print("現在値: \(original) = \(describe(original))")
        print("試す値: \(probe) = \(describe(probe))\n")

        guard write(Keystage.setting(baseline, at: offset, to: probe), label: "書き込み") else {
            print("\n⚠️ 書き込みが通らなかった。ここで打ち切る（元の値のまま）")
            return
        }

        print("\n🎹 **いま鍵盤を弾いてください（15 秒）** — 音程が 1 オクターブ変わっていれば")
        print("   書き込みは効いている（読み直しで見えなくても）")
        for remaining in stride(from: 15, to: 0, by: -5) {
            Thread.sleep(forTimeInterval: 5)
            print("   … 残り \(remaining - 5) 秒")
        }

        if let after = readBack() {
            let ok = after == probe
            print("読み直し: \(after) = \(describe(after))  \(ok ? "✅ 反映された" : "❌ 変わっていない")")
            if !ok {
                print("  → ACK は返るが値が戻る = current scene data と internal memory の差の可能性")
            }
        } else {
            print("読み直しに失敗")
        }

        print("\n── 元に戻す ──")
        _ = write(Keystage.setting(baseline, at: offset, to: original), label: "復元")
        if let restored = readBack() {
            print("読み直し: \(restored) = \(describe(restored))  \(restored == original ? "✅ 戻った" : "⚠️ 戻っていない")")
        }
        print("\n※ 本体の画面でも Chord Set の表示を見ていると、書き込みの瞬間が分かる")
    }

    /// Scene の Arp / Chord をオフセット表と突き合わせて出す
    private func printSceneParameters(_ data: [UInt8]) {
        func value(_ offset: Int) -> String {
            data.indices.contains(offset) ? "\(data[offset])" : "(範囲外)"
        }
        let arpModes = ["Up", "Down", "Up-Down", "Down-Up", "Play", "Random", "Trigger"]
        let rates = [
            "1/1", "1/2", "1/3", "1/4", "1/6", "1/8", "1/12", "1/16", "1/24", "1/32", "1/48",
            "1/64",
        ]
        let strums = ["Up", "Down", "Up&Down", "Random", "Velocity"]

        func named(_ offset: Int, _ list: [String]) -> String {
            guard data.indices.contains(offset) else { return "(範囲外)" }
            let raw = Int(data[offset])
            return raw < list.count ? "\(list[raw]) (\(raw))" : "\(raw)"
        }

        let name = String(
            decoding: data.prefix(10).prefix(while: { $0 != 0 }), as: UTF8.self)
        print("Scene 名: \"\(name)\"\n")

        print("── Arpeggiator ──")
        print("  Mode      : \(named(Keystage.SceneOffset.arpMode, arpModes))")
        print("  Rate      : \(named(Keystage.SceneOffset.arpRate, rates))")
        print("  Octave    : \(value(Keystage.SceneOffset.arpOctave)) (0-3 = 1-4)")
        print("  Latch     : \(value(Keystage.SceneOffset.arpLatch))")
        print("  Key Sync  : \(value(Keystage.SceneOffset.arpKeySync))")
        print("  Swing     : \(value(Keystage.SceneOffset.arpSwing))%")
        print("  Pattern   : \(value(Keystage.SceneOffset.arpPattern))")
        print("  Gate Time : \(value(Keystage.SceneOffset.arpGateTime)) (0-200 = ±100%)")
        print("  Velocity  : \(value(Keystage.SceneOffset.arpVelocity))")
        print("  Chance    : \(value(Keystage.SceneOffset.arpChance))%")

        print("\n── Chord ──")
        let setNum = data.indices.contains(Keystage.SceneOffset.chordSetNum)
            ? Int(data[Keystage.SceneOffset.chordSetNum]) : -1
        let setLabel = setNum < 0
            ? "(範囲外)"
            : (setNum < 32 ? "Preset\(setNum + 1)" : "User\(setNum - 31)") + " (\(setNum))"
        print("  Chord Set : \(setLabel)")
        print("  Strum Time: \(value(Keystage.SceneOffset.strumTime))")
        print("  Strum Dir : \(named(Keystage.SceneOffset.strumDirection, strums))")

        print("\n── Keyboard ──")
        print("  Octave    : \(value(Keystage.SceneOffset.keyboardOctave)) (0-6 = -3…+3)")
        print("  Transpose : \(value(Keystage.SceneOffset.keyboardTranspose)) (0-24 = -12…+12)")

        print("\n※ 本体で Arp Mode 等を変えてからもう一度走らせると、")
        print("  この表示が追従するかでオフセットの正しさが確かめられる")
    }

    /// User Chord Set の中身（最初の数セット）
    private func printUserChordSets(_ data: [UInt8]) {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        print("── User Chord Set（先頭 3 セット）──")
        for set in 0..<3 {
            print("\nUser\(set + 1):")
            var empty = true
            for key in 0..<Keystage.GlobalOffset.keysPerSet {
                let base = Keystage.GlobalOffset.keyOffset(set: set, key: key)
                guard data.indices.contains(base + Keystage.GlobalOffset.bytesPerKey - 1) else {
                    print("  (範囲外 — Dump が想定より短い)")
                    return
                }
                let size = Int(data[base])
                guard size > 0, size <= Keystage.GlobalOffset.notesPerKey else { continue }
                empty = false
                let notes = (0..<size).map { Int(data[base + 1 + $0]) }
                let pitches = notes.map { "\(names[$0 % 12])\($0 / 12 - 1)" }
                print("  \(names[key])  \(size)音: \(pitches.joined(separator: " "))")
            }
            if empty { print("  (空)") }
        }
    }
}
