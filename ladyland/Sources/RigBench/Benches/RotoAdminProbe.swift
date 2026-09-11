//! ROTO アドミンポート（USB CDC シリアル）の観測ベンチ（2026-08-12 起工）。
//!
//! ROTO-SETUP の app.asar 解剖で「設定読み書きは MIDI ではなくシリアル」と
//! 確定した（docs/roto-control/admin-port.md）。フレーミングは RotoKit.RotoAdmin、
//! 線の世話は RotoKit.RotoAdminPort（瞬間芸の掟もそちらのヘッダ参照）。
//!
//! 段階:
//!   swift run RigBench roto-admin              info: FW 版数 + 現在 setup +
//!                                              64 冊の名前（読むだけ）
//!   swift run RigBench roto-admin watch [秒]   ポートを開いたまま観測 —
//!                                              実機発コマンド（SEL 切替等）が届くか。
//!                                              ⚠️ open 中は実機の CC が止まる
//!   swift run RigBench roto-admin sel <n>      MIDI_SET_SETUP — SEL のリモート操作
//!   swift run RigBench roto-admin write-test [setup]
//!                                              席 1 個の書き込み検証（既定 = SETUP 03。
//!                                              LL の 2 冊は実験台にしない）
//!
//! パス指定も可: swift run RigBench roto-admin info /dev/cu.usbmodem11101

import Foundation
import RotoKit

struct RotoAdminProbe: Bench {
    let name = "roto-admin"
    let summary = "アドミンポートの通電確認（info / watch [秒] / sel <n> / write-test）"

    func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst(2))
        let stages = [
            "info", "watch", "sel", "write-test", "read", "clear", "button-test", "subtext",
            "nstep",
        ]
        let stage = arguments.first.map { stages.contains($0) ? $0 : "info" } ?? "info"
        if arguments.first == stage { arguments.removeFirst() }
        let explicitPath = arguments.first(where: { $0.hasPrefix("/dev/") })

        try RotoAdminPort.withPort(explicitPath: explicitPath) { session in
            print("アドミンポート: \(session.path)")
            print("FW: \(session.version.description)\n")

            switch stage {
            case "watch":
                try watch(session, seconds: arguments.compactMap(Int.init).first ?? 60)
            case "sel":
                guard let index = arguments.compactMap(Int.init).first,
                    (0..<64).contains(index)
                else { throw BenchError("sel には 0-63 の setup 番号を渡す") }
                print("→ MIDI_SET_SETUP \(index) — 実機の表示が切り替わりましたか")
                let reply = try session.transact(RotoAdmin.setSetup(index), expecting: 0)
                print("← rc=\(String(format: "%02X", reply.code))\(reply.isOK ? "（OK）" : "")")
            case "write-test":
                try writeTest(session, setup: arguments.compactMap(Int.init).first ?? 2)
            case "button-test":
                // ボタン挙動のプローブ（冊切替ボタン設計の前提 2026-08-12）:
                // 実験台の冊に PUSH と TOGGLE を 1 個ずつ焼き、①何を送るか
                // ②LED の振る舞い ③外から CC を送って LED が追従するか、を
                // 実機で見る。③ は roto-midi motor 3 <cc> で撃つ
                let setup = arguments.compactMap(Int.init).first ?? 3  // 既定 = SETUP 04
                try session.configUpdate(
                    RotoAdmin.setSetupName(index: setup, name: "L04 BTNTEST"))
                try session.configUpdate(
                    RotoAdmin.setSwitchConfig(
                        setup: setup, control: 0, channel: 3, cc: 0, name: "PUSH",
                        colorScheme: 29, ledOn: 13, ledOff: 70, toggle: false))
                try session.configUpdate(
                    RotoAdmin.setSwitchConfig(
                        setup: setup, control: 1, channel: 3, cc: 1, name: "TOGGLE",
                        colorScheme: 33, ledOn: 72, ledOff: 77, toggle: true))
                print("SETUP \(String(format: "%02d", setup + 1)) にボタン 2 個を焼いた:")
                print("  ボタン 1 = PUSH（ch3 CC0、LED: 白 ⇄ 黒）")
                print("  ボタン 2 = TOGGLE（ch3 CC1、LED: 緑 ⇄ 暗赤）")
                print("→ SEL で L04 BTNTEST を選んで押してみてください。")
                print("  受信の観測: swift run RigBench roto-midi watch 60")
                print("  LED 追従の実験: swift run RigBench roto-midi motor 3 1")
            case "clear":
                // 席のクリア: clear <setup> <control>（write-test の残骸掃除用）
                let numbers = arguments.compactMap(Int.init)
                guard numbers.count >= 2 else {
                    throw BenchError("clear には <setup 0-63> <control 0-31> を渡す")
                }
                try session.configUpdate(
                    RotoAdmin.clearControl(
                        setup: numbers[0], button: false, control: numbers[1]))
                print("SETUP \(String(format: "%02d", numbers[0] + 1)) "
                    + "ノブ位置 \(numbers[1]) をクリアした")
            case "subtext":
                // **下段テキストのプローブ**（mako 要望 2026-08-13「上段 inst名+
                // page / 下段 パラメータ名」）: SN:16×13（N_STEP のステップ名）の
                // SN[0] にテキストを入れて、**通常モード（KNOB_360）でも下段に
                // 出るか**を見る。SETUP 02 ノブ 0 に UP/DOWN を焼く
                var data: [UInt8] = []
                data.append(1)  // SETUP 02
                data.append(0)  // ノブ位置 0
                data.append(0)  // controlMode: CC 7bit
                data.append(1)  // ch1
                data.append(0)  // CC0
                data.append(contentsOf: [0, 0])  // nrpnAddress
                data.append(contentsOf: [0, 0])  // min
                data.append(contentsOf: [0, 127])  // max
                data.append(contentsOf: RotoAdmin.paddedName("UP TEXT"))
                data.append(28)  // 淡色
                data.append(0)  // hapticMode: KNOB_360（通常ノブのまま）
                data.append(contentsOf: [0xFF, 0xFF])
                data.append(0)  // hapticSteps
                data.append(contentsOf: RotoAdmin.paddedName("DOWN TEXT"))  // SN[0]
                for _ in 1..<16 {
                    data.append(contentsOf: RotoAdmin.paddedName(""))
                }
                try session.configUpdate(
                    RotoAdmin.request(
                        family: RotoAdmin.Midi.family,
                        sub: RotoAdmin.Midi.setKnobConfig, data: data))
                print("SETUP 02 ノブ 1 に UP TEXT / SN[0]=DOWN TEXT を焼いた —")
                print("L02 のノブ 1 の LCD 下段に「DOWN TEXT」が出ていますか？")

            case "nstep":
                // **N_STEP モードのプローブ**（下段の本来の想定用途の確定 —
                // mako 問い 2026-08-13「ここは本来どういう想定で使うんだろう」）:
                // hapticMode 4（N_STEP）+ hapticSteps 4 + SN[0-3] にステップ名。
                // 回すと下段にステップ名が出るか / CC がどう飛ぶかを見る
                var data: [UInt8] = []
                data.append(1)  // SETUP 02
                data.append(1)  // ノブ位置 1（subtext の隣）
                data.append(0)  // controlMode: CC 7bit
                data.append(1)  // ch1
                data.append(1)  // CC1
                data.append(contentsOf: [0, 0])  // nrpnAddress
                data.append(contentsOf: [0, 0])  // min
                data.append(contentsOf: [0, 127])  // max
                data.append(contentsOf: RotoAdmin.paddedName("NSTEP TEST"))
                data.append(29)  // 淡色
                data.append(4)  // hapticMode: N_STEP
                data.append(contentsOf: [0xFF, 0xFF])
                data.append(4)  // hapticSteps: 4 段
                for step in ["STEP A", "STEP B", "STEP C", "STEP D"] {
                    data.append(contentsOf: RotoAdmin.paddedName(step))
                }
                for _ in 4..<16 {
                    data.append(contentsOf: RotoAdmin.paddedName(""))
                }
                try session.configUpdate(
                    RotoAdmin.request(
                        family: RotoAdmin.Midi.family,
                        sub: RotoAdmin.Midi.setKnobConfig, data: data))
                print("SETUP 02 ノブ 2 を N_STEP（4 段、STEP A-D）で焼いた —")
                print("L02 のノブ 2 を回して: 下段にステップ名が出ますか？")
                print("（CC1 の値の飛び方も MIDI モニタで見えると完璧）")

            case "read":
                // 席 1 個の読み出し（焼き込みの検証用）: read <setup> <control> [sw]
                // 3 つ目に "sw" を渡すとボタン席（switch）を読む
                let numbers = arguments.compactMap(Int.init)
                guard numbers.count >= 2 else {
                    throw BenchError("read には <setup 0-63> <control 0-31> [sw] を渡す")
                }
                let isSwitch = arguments.contains("sw")
                let reply = try session.transact(
                    isSwitch
                        ? RotoAdmin.getSwitchConfig(setup: numbers[0], control: numbers[1])
                        : RotoAdmin.getKnobConfig(setup: numbers[0], control: numbers[1]),
                    expecting: RotoAdmin.knobConfigBytes)
                if reply.isOK, reply.data.count >= 29 {
                    let name = String(
                        decoding: reply.data[11..<24].prefix { $0 != 0 }, as: UTF8.self)
                    // ⚠️ channel の格納値は 1 始まりのまま（1 = ch1。書き込みと
                    // 同じ掟 — +1 して表示すると 1 つ大きく読めてしまう）
                    print("SETUP \(String(format: "%02d", numbers[0] + 1)) "
                        + "\(isSwitch ? "ボタン" : "ノブ")位置 \(numbers[1]): "
                        + "name=「\(name)」 ch=\(reply.data[3]) "
                        + "cc=\(reply.data[4]) mode=\(reply.data[2]) color=\(reply.data[24])")
                } else {
                    print("rc=\(String(format: "%02X", reply.code))"
                        + (reply.code == RotoAdmin.unconfiguredCode ? "（未設定）" : ""))
                }
            default:
                try info(session)
            }
        }
        print("\n--- 終了 ---")
    }

    private func info(_ session: RotoAdminSession) throws {
        let current = try session.transact(
            RotoAdmin.getCurrentSetup(), expecting: 1 + RotoAdmin.nameLength)
        if let info = RotoAdmin.SetupInfo(current.data) {
            print("現在の setup: #\(info.index + 1)「\(info.name)」")
        }
        print("\n64 冊の名前（GET_SETUP 総なめ）:")
        for index in 0..<64 {
            let reply = try session.transact(
                RotoAdmin.getSetup(index), expecting: 1 + RotoAdmin.nameLength)
            guard reply.isOK, let info = RotoAdmin.SetupInfo(reply.data), !info.name.isEmpty
            else { continue }
            print("  #\(String(format: "%02d", index + 1)) \(info.name)")
        }
    }

    private func watch(_ session: RotoAdminSession, seconds: Int) throws {
        print("--- \(seconds) 秒観測（SEL 切替 / LEARN 操作を実機側で） ---")
        print("⚠️ open 中は実機の CC が止まる — これは仕様（瞬間芸の掟）\n")
        let start = Date()
        while Date().timeIntervalSince(start) < TimeInterval(seconds) {
            // 応答を待たない受信だけの窓 — ダミーの GET を低頻度で打って
            // 実機発コマンドを拾う（transact が通知を流してくれる）
            _ = try? session.transact(
                RotoAdmin.getCurrentSetup(), expecting: 1 + RotoAdmin.nameLength,
                timeout: 1.0
            ) { family, sub, data in
                let stamp = "[\(Int(Date().timeIntervalSince(start) * 1000))ms]"
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                let label: String =
                    switch (family, sub) {
                    case (RotoAdmin.Midi.family, RotoAdmin.Midi.setSetup):
                        "SEL 切替 → setup #\(data.first.map { Int($0) + 1 } ?? 0)"
                    case (RotoAdmin.Midi.family, RotoAdmin.Midi.controlLearned):
                        "LEARN 完了"
                    default:
                        "実機発コマンド"
                    }
                print("\(stamp) ← \(label)  [\(String(format: "%02X %02X", family, sub)) \(hex)]")
            }
            sleep(2)
        }
    }

    /// 書き込み系の検証: 席 1 個を括弧つきで書き、読み戻しで照合。
    /// ①LCD に名前が即出るか ②CC への後遺症、は実機側で目視
    private func writeTest(_ session: RotoAdminSession, setup: Int) throws {
        print("→ SETUP \(String(format: "%02d", setup + 1)) のノブ 1 へ書き込みます")
        let before = try session.transact(
            RotoAdmin.getKnobConfig(setup: setup, control: 0),
            expecting: RotoAdmin.knobConfigBytes)
        print("← 書き込み前: rc=\(String(format: "%02X", before.code))"
            + (before.code == RotoAdmin.unconfiguredCode ? "（未設定）" : ""))

        let knob = RotoMidiSetup.Knob(
            controlIndex: 0, channel: 1, cc: 0, name: "LL WRITE", colorScheme: 29)
        try session.configUpdate(RotoAdmin.setKnobConfig(setup: setup, control: 0, knob: knob))
        print("→ START / SET_KNOB / END — 送った")

        let after = try session.transact(
            RotoAdmin.getKnobConfig(setup: setup, control: 0),
            expecting: RotoAdmin.knobConfigBytes)
        if after.isOK, after.data.count >= 29 {
            let name = String(decoding: after.data[11..<24].prefix { $0 != 0 }, as: UTF8.self)
            print("← 読み戻し: name=「\(name)」 cc=\(after.data[4]) color=\(after.data[24])")
            print(name == "LL WRITE"
                ? "✅ 書き込み成立 — LCD に「LL WRITE」が出ていれば即時反映も成立"
                : "⚠️ 読み戻しが不一致")
        } else {
            print("⚠️ 読み戻し失敗 rc=\(String(format: "%02X", after.code))")
        }
    }
}
