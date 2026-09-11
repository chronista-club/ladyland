//! ROTO-CONTROL の観測ベンチ（2026-08-02 起工）。
//!
//! **なぜ ladyland 側に持つか**: vp の `roto demo` は投影を送るが LCD もモーターも
//! 反応しなかった。原因を詰めるには「何を送ったか」を完全に握る必要があり、
//! かつ ROTO 対応は最終的に ladyland に入る。切り分けの道具は現場に置く。
//!
//! **握手が要る**: ROTO は握手が済むまでモード通知以外を喋らない
//! （実機確認 — 45 秒待って沈黙）。さらに hello への応答を止めると切断扱いに
//! なるため、このベンチは常に応答ループを回し続ける。
//!
//! 段階を選べる（切り分けの粒度）:
//!   swift run RigBench roto-probe            握手のみ。受信を全部デコードして出す
//!   swift run RigBench roto-probe motor      + モーターを 14bit CC で動かす
//!   swift run RigBench roto-probe track      + トラック名の枠付きバッチ
//!   swift run RigBench roto-probe learn      + parameter learn（コミット無し）
//!   swift run RigBench roto-probe learn+     + parameter learn（コミット `0B 06` 付き）
//!   swift run RigBench roto-probe watch      握手だけして 30 秒、入力（CC）を観察
//!   swift run RigBench roto-probe mainlcd    **MAIN LCD（左の大きい窓）を狙う**:
//!                                            `0C 0A` で据える → `0A 16` 名前 →
//!                                            `0A 17` 色 の順に 1 通ずつ撃つ
//!   swift run RigBench roto-probe meter      **VU メーターの検証**（未確認）:
//!                                            専用の表示器は無いので 8 枚の LCD に
//!                                            描かれるはず、という仮説を目で確かめる。
//!                                            位相をずらした波を 12fps で 15 秒流す
//!   swift run RigBench roto-probe hold       **初期化の合図が来た瞬間**に track+learn を
//!                                            送り、2 秒ごとに送り直して 60 秒保持する
//!                                            （表示が一瞬で消える / 送る時機が早すぎる
//!                                             possibility を潰すための観察用）
//!   swift run RigBench roto-probe recall     **本命の recall フロー**（2026-08-03 発掘）:
//!                                            "Phase Plant" を 0B 05 バッチで告知 →
//!                                            デバイスが保存済み割当を CONTROL_MAPPED で
//!                                            要求してくる → learn で応答 → LCD 点灯 +
//!                                            モーター移動 + knob CC 開通、のはず。
//!                                            実機に Bitwig 名義の Phase Plant 割当
//!                                            （knob 0 ← param#4）が保存されている前提

import CoreMIDI
import Foundation
import Lpd8Kit
import RotoKit

struct RotoProbe: Bench {
    let name = "roto-probe"
    let summary = "ROTO の握手 + 受信デコード（引数で motor / track / learn / learn+ を追加）"

    func run() throws {
        let stage = CommandLine.arguments.dropFirst(2).first ?? "probe"
        let client = try MIDISysExSender.makeClient("rigbench-roto")
        let destination = try MIDISysExSender.destination(matching: "Roto")
        let source = try MIDISysExSender.source(matching: "Roto")

        let log = Log()
        var assembler = SysEx7Assembler()
        var port = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(
            client, "roto-in" as CFString, ._1_0, &port
        ) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(count, 64) {
                            if let frame = assembler.feed(words[i]) {
                                log.received(frame)
                            }
                            // 生 CC（MT2）も見る — **ノブ・ボタンはここに来る**。
                            // 握手後に入力が返るかどうかが、統合が成立しているかの
                            // 決定的な分かれ目（doc §7 の ccInsBlocked ガード）
                            log.receivedShort(words[i])
                        }
                    }
                }
            }
        }
        guard status == noErr else { throw BenchError("入力ポート作成に失敗: \(status)") }
        MIDIPortConnectSource(port, source, nil)

        print("段階: \(stage)")
        print("ROTO の画面とノブを見ていてください。hello には自動応答し続けます。\n")

        // 握手の口火。以後 hello が約 1 秒間隔で来るので応答し続ける
        MIDISysExSender.send(Roto.dawStart, to: destination)
        print("→ DAW_START")

        let start = Date()
        var didProject = false
        var lastDrain = 0
        var lastHold = Date.distantPast
        var lastMeter = Date.distantPast

        let duration: TimeInterval =
            switch stage {
                case "watch": 30
            case "hold", "logic": 60
            case "meter": 60
            case "recall", "plugin": 45
            case "mainlcd": 45
            case "daw": 40
            default: 20
            }
        while Date().timeIntervalSince(start) < duration {
            // 受信を捌く（応答が要るものは即返す）
            let pending = log.drain(from: lastDrain)
            lastDrain += pending.count
            for frame in pending {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                print("[\(elapsed)ms] ← \(Roto.describe(frame))")
                // logic ステージは Logic Pro (3) を名乗る — 方言が変わるかの検証
                // logic / meter は Logic Pro (3) を名乗る（メーターは MIXER 系で、
                // 直接 setter と同じ方言側にある可能性が高い）
                // `daw <n>` ステージ: **名乗る種別を引数で指定**して、MODE に
                // 何の面が出るか観察する。公式は 1=Ableton / 2=Bitwig / 3=Logic の
                // 3 つだけで、**4 以降は未定義**（ROTO-SETUP のリソースにも無い）。
                // 未知の種別でデバイスが全部の面を開けるなら、SMART と PLUGIN が
                // 両立するかもしれない
                let dawType: UInt8 = {
                    if stage == "daw",
                        let n = CommandLine.arguments.dropFirst(3).first.flatMap(UInt8.init) {
                        return n
                    }
                    return (stage == "logic" || stage == "meter") ? 3 : 2
                }()
                for reply in Roto.autoResponse(to: frame, dawType: dawType) {
                    MIDISysExSender.send(reply, to: destination)
                }
                // Logic 方言: デバイスは表示を保持しない前提で、モード切替の
                // 通知を受けるたびに DAW がラベルを再投影する（Logic の CSLabel 相当）
                if stage == "logic", frame.count >= 7 {
                    switch (frame[5], frame[6]) {
                    case (0x0C, 0x02):
                        print("→ MIX 面へ切替を検知 — track ラベルを再投影")
                        for i in 0..<8 {
                            MIDISysExSender.send(
                                Roto.setTrackDetails(UInt8(i), name: "LL Track \(i + 1)"),
                                to: destination)
                            usleep(5_000)
                        }
                    case (0x0B, 0x01):
                        print("→ PLUGIN 面へ切替を検知 — knob ラベルを再投影")
                        for i in 0..<8 {
                            MIDISysExSender.send(
                                Roto.setPluginControlDetails(
                                    UInt8(i), name: "LL Knob \(i + 1)"),
                                to: destination)
                            usleep(5_000)
                        }
                    default:
                        break
                    }
                }
                // recall の心臓部: デバイスが保存済み割当を要求してきたら
                // learn で応答する（paramIndex と hash は必ず echo）。
                // 表示名と値は DAW の自由 — knob ごとに変えて階段状に見せる
                if stage == "recall", let mapped = Roto.parseControlMapped(frame) {
                    let name = "LL Knob \(mapped.controlIndex + 1)"
                    let value = Double(mapped.controlIndex) / 7
                    let reply = Roto.learn(
                        paramIndex: mapped.paramIndex,
                        name: name,
                        value: value,
                        hash: mapped.hash6,
                        isMacro: mapped.isMacro)
                    MIDISysExSender.send(reply, to: destination)
                    print("→ LEARN_PARAM 応答: param#\(mapped.paramIndex) "
                        + "→ \(mapped.isSwitch ? "button" : "knob") \(mapped.controlIndex) "
                        + "name=\(name) value=\(String(format: "%.2f", value))")
                }
            }

            for line in log.drainShorts() {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                print("[\(elapsed)ms] ← \(line)")
            }

            if stage == "hold" {
                // **初期化の合図（02 0C 01）が来た瞬間**に投影する。
                // 「送る時機が早すぎた / 表示がすぐ消えた」を潰すため、
                // 以後 2 秒ごとに送り直して保持する
                if log.initialized, Date().timeIntervalSince(lastHold) > 2 {
                    lastHold = Date()
                    project(stage: "track", to: destination)
                    project(stage: "learn+", to: destination)
                }
            } else if !didProject, log.helloSeen, Date().timeIntervalSince(start) > 3 {
                didProject = true
                project(stage: stage, to: destination)
            }

            // メーターは**受信ループを止めずに**流し続ける（hello への応答を
            // 切らさないため）。位相をずらしてあるので 8 枚が順に振れるはず
            if stage == "meter", didProject,
               Date().timeIntervalSince(lastMeter) > 0.083  // ≈12fps
            {
                lastMeter = Date()
                let phase = Date().timeIntervalSince(start)
                for track in 0..<8 {
                    let value = (sin(phase * 2 + Double(track) * 0.8) + 1) / 2
                    for message in Roto.meter(track: track, left: value, right: value * 0.7) {
                        MIDISysExSender.sendRaw(message, to: destination)
                    }
                }
            }
            usleep(20_000)
        }

        print("\n--- 終了 ---")
        print("受信 SysEx: \(log.count) 件（うち hello \(log.helloCount) 件）")
        if !log.helloSeen {
            print("⚠️ hello が来ていない = 握手が始まっていない。ポート / モードを疑う")
        }
    }

    /// 段階ごとの投影。**何を送ったかを必ず印字する** — 反応しなかったときに
    /// 「送っていないのか、無視されたのか」を後から切り分けられるように
    private func project(stage: String, to destination: MIDIEndpointRef) {
        func send(_ label: String, _ messages: [[UInt8]]) {
            print("→ \(label)（\(messages.count) 通）")
            for message in messages {
                MIDISysExSender.send(message, to: destination)
                usleep(3_000)
            }
        }

        switch stage {
        case "motor":
            // SysEx ではなく 14bit CC。learn が効かなくてもここは動きうる
            print("→ モーター: 8 本を階段状に（14bit CC ch16）")
            for knob in 0..<8 {
                for message in Roto.motor(knob: knob, value: Double(knob) / 7) {
                    MIDISysExSender.sendRaw(message, to: destination)
                    usleep(3_000)
                }
            }
        case "track":
            send("トラック枠付きバッチ", Roto.trackBatch((1...8).map { "Track \($0)" }))
            send("選択中トラック", [Roto.selectedTrack(0, name: "Track 1")])
        case "learn", "learn+":
            // 旧実験の名残（announce 無し learn は無視される、が 2026-08-03 に判明済み）。
            // index の意味を param 番号に正して残す — 「やはり単発では効かない」の再確認用
            var messages: [[UInt8]] = (0..<8).map {
                Roto.learn(paramIndex: $0, name: "Param \($0 + 1)", value: Double($0) / 7)
            }
            if stage == "learn+" {
                messages.append(Roto.pluginCommit)
            }
            send("parameter learn\(stage == "learn+" ? " + コミット 0B 06" : "")", messages)
        case "recall":
            // 引数 2 でプラグイン名を差し替えられる（既定は実機に Bitwig 名義で
            // 保存済みの "Phase Plant"。自作 setup を import したら "Ladyland" 等で）。
            // デバイス側から CONTROL_MAPPED が来たら受信ループが応答する
            let plugin = CommandLine.arguments.dropFirst(3).first ?? "Phase Plant"
            send(
                "プラグイン告知バッチ（\(plugin)）",
                Roto.pluginBatch([Roto.PluginInfo(name: plugin)]))
            // バッチだけでは沈黙する（実測）— フォーカス宣言が引き金
            send("DAW_SELECT_PLUGIN（index 0）", [Roto.selectPlugin(0)])
        case "logic":
            // Logic 方言の検証: hash も learn も無しで、直接 setter だけで
            // track セルと knob LCD が書けるか（ping は Logic Pro (3) を名乗り済み）。
            // モード切替の再投影は受信ループ側。モーターも同一セッションで試す
            send("Logic init シーケンス", Roto.logicInit())
            send(
                "SET_TRACK_DETAILS ×8",
                (0..<8).map { Roto.setTrackDetails(UInt8($0), name: "LL Track \($0 + 1)") })
            send(
                "SET_PLUGIN_CTL_DETAILS ×8",
                (0..<8).map {
                    Roto.setPluginControlDetails(UInt8($0), name: "LL Knob \($0 + 1)")
                })
            print("→ モーター: SMART 面の 8 本を階段状に（ch15 CC0-7 の 14bit echo）")
            for knob in 0..<8 {
                for message in Roto.smartMotor(param: knob, value: Double(knob) / 7) {
                    MIDISysExSender.sendRaw(message, to: destination)
                    usleep(3_000)
                }
            }
            print("※ 60 秒間セッションを保ちます — MODE ボタンで MIX ⇄ PLUGIN を"
                + "切り替えてみてください（切替のたびに再投影します）。knob も回してみて")
        case "mainlcd":
            // **MAIN LCD（左の大きい窓）を狙う**（`config.lua` L1508-1540 の読み解き、
            // 2026-08-05）。
            //
            // 8/4 に `0A 16` を撃って面を殴ったときは **`<0> <0>` を 2 バイト余計に
            // 付けていた** — 公式は名前 13 バイトだけを積む。さらに公式の順序は
            // 「**`0C 0A` で名前と色を据える** → 以降は差分を送る」で、据える前の
            // 差分は `filter_track_name` に止められて 1 通も出ない。
            //
            // 4 通を間隔を空けて撃つので、**どれで MAIN LCD が動くか**が目で分かる
            send("Logic init シーケンス", Roto.logicInit())
            send("SMART 面へ", Roto.selectFace(.smart))
            usleep(800_000)
            send(
                "① 0C 0A FOCUS TRACK — 名前 + RGB を据える（本命）",
                [Roto.selectFocusTrack(0, name: "LADYLAND", red: 0, green: 200, blue: 255)])
            usleep(2_000_000)
            send(
                "② 0A 16 — 名前だけ更新（13 byte、前置き無し）",
                [Roto.setMenuText("P1 BERLIN")])
            usleep(2_000_000)
            send(
                "③ 0A 17 — 色だけ更新（RGB 6 byte）",
                [Roto.setMenuColor(red: 255, green: 80, blue: 0)])
            usleep(2_000_000)
            send(
                "④ 0C 0A もう一度 — 別の名前と色に差し替わるか",
                [Roto.selectFocusTrack(1, name: "MARSEILLE", red: 255, green: 0, blue: 180)])
            print("→ **MAIN LCD を見てください**。①〜④のどれで変わりましたか")
            print("  ⚠️ knob LCD（8 枚）が消えたら、その通が面を殴っています")
        case "meter":
            // VU メーターは**専用の表示器が無い** — 8 枚の LCD に描かれるはず、
            // という仮説の検証。トラック名を出してから波を流し、
            // どこに何が出るか（or 出ないか）を目で見る
            send("Logic init", Roto.logicInit())
            send(
                "トラック名 ×8",
                (0..<8).map { Roto.setTrackDetails(UInt8($0), name: "M\($0 + 1)") })
            send("メーター閾値（黄 87 / 赤 113）", [Roto.meterPoints()])
            send("メーター有効化 ×8", [Roto.meterStates(Array(repeating: true, count: 8))])
            // ⚠️ レベルの送出は**受信ループ側**でやる。ここで待つと
            // その間 hello に応答できず、デバイスに切断扱いされる
            // （最初の実装がこれで、無反応の原因になった 2026-08-03）
            print("→ 以後レベルを流し続けます（12fps）。MODE で MIX / PLUGIN / SMART を"
                + "切り替えて、どの面で出るか見てください")
        case "plugin":
            // **PLUGIN 面を押し込みで作れるか**（2026-08-03 の本命実験）。
            // 以前 learn 単発が無反応だったのは告知をしていなかったから、
            // という仮説の検証: 告知 → フォーカス宣言 → learn を N 個押し込む。
            //
            // 通れば PLUGIN 面が push 型で使える = SMART の 16 の壁を越えて
            // 最大 256 セルに手が届く（bootstrap の JSON import も要らない）
            send("プラグイン告知（Ladyland）", Roto.pluginBatch([Roto.PluginInfo(name: "Ladyland")]))
            send("DAW_SELECT_PLUGIN", [Roto.selectPlugin(0)])
            send(
                "learn 押し込み ×24（CONTROL_MAPPED を待たない）",
                (0..<24).map {
                    Roto.learn(
                        paramIndex: $0, name: "LL P\($0 + 1)",
                        value: Double($0) / 23)
                })
            send("plugin detail 終了", [Roto.pluginCommit])
            // ついでに MAIN LCD も撃つ — ⚠️ **据える前の差分**なので、
            // 公式の順序（`0C 0A` で名前と色を据えてから差分）とは違う。
            // MAIN LCD を本気で狙うなら `mainlcd` ステージを使うこと
            send(
                "MAIN LCD へ書き込み（据えずに差分だけ）",
                [Roto.setMenuText("LL PLUGIN"), Roto.setMenuColor(paletteIndex: 21)])
        case "watch":
            print("（投影なし）ノブを回す / 触る / ボタンを押してください — 入力が返るか見ます")
        default:
            print("（投影なし — 受信の観察のみ）")
        }
    }
}

/// 受信フレームの受け皿（CoreMIDI スレッドから積まれる）
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[UInt8]] = []
    private(set) var helloCount = 0
    /// 02 0C 01（MIXER 更新）= doc §6 の initialized の引き金を見たか
    private(set) var initializedFlag = false

    var initialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return initializedFlag
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    var helloSeen: Bool {
        lock.lock(); defer { lock.unlock() }
        return helloCount > 0
    }

    /// UMP の MIDI 1.0 チャンネルボイス（MT2）を人が読める形で積む。
    /// Clock (F8) 等の Realtime は MT2 に来ないので自然に落ちる。
    /// ⚠️ Logic 方言は多チャンネル（ch7 = command / ch8-15 = plugin / ch16 = 主）
    /// なので **チャンネルを必ず表示する** — 捨てると別系統の CC が混線して見える
    func receivedShort(_ word: UInt32) {
        guard (word >> 28) & 0xF == 2 else { return }
        let status = UInt8((word >> 16) & 0xFF)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        guard status & 0xF0 == 0xB0 else { return }
        let channel = Int(status & 0x0F) + 1
        // ch16 の既知配置だけラベルを付ける。他チャンネルは生で見せる
        let label: String
        if channel == 16 {
            switch Int(data1) {
            case 12...19: label = "knob \(Int(data1) - 12) 回転 hi"
            case 44...51: label = "knob \(Int(data1) - 44) 回転 lo"
            case 52...59: label = "knob \(Int(data1) - 52) MIX touch \(data2 > 0 ? "押" : "離")"
            case 64...71: label = "knob \(Int(data1) - 64) PLUGIN touch \(data2 > 0 ? "押" : "離")"
            case 20...27: label = "button \(Int(data1) - 20) \(data2 > 0 ? "押" : "離")"
            case 28...35: label = "transport btn \(Int(data1) - 28) \(data2 > 0 ? "押" : "離")"
            case 36: label = "← 左"
            case 37: label = "→ 右"
            default: label = "未知"
            }
        } else if channel == 7 {
            label = "command ch"
        } else if (8...15).contains(channel) {
            label = "plugin ch（slot \(channel - 8)）"
        } else {
            label = "未知 ch"
        }
        lock.lock()
        shorts.append("ch\(channel) CC\(data1)=\(data2)  \(label)")
        lock.unlock()
    }

    private var shorts: [String] = []

    func drainShorts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = shorts
        shorts.removeAll()
        return out
    }

    func received(_ frame: [UInt8]) {
        lock.lock()
        frames.append(frame)
        if Roto.isRoto(frame), frame.count >= 7 {
            if frame[5] == 0x0A, frame[6] == 0x02 { helloCount += 1 }
            if frame[5] == 0x0C, frame[6] == 0x01 { initializedFlag = true }
        }
        lock.unlock()
    }

    /// 未処理ぶんだけ取り出す（hello を印字で埋めないよう、呼び手が間引く）
    func drain(from index: Int) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        guard index < frames.count else { return [] }
        return Array(frames[index...])
    }
}
