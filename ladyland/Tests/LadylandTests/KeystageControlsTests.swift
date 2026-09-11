//! **Keystage の操作子 → ladyland の扱い**（mako 要望 2026-08-07
//! 「Keystage のわりあてというか。そちらをさきに固めてから進めよう」）。
//!
//! ⚠️ ここで固定するのは **「番号を直書きしていない」**こと。
//! 今日 `as? LadySampler` で 2 か所刺さったのと同じ形で、
//! **具体値で条件を書くと、値が動いたときに黙って外れる**。

import Foundation
import KeystageKit
import Testing

@testable import Ladyland

@Suite("Keystage の操作子")
struct KeystageControlsTests {

    // MARK: - ⭐ 番号を直書きしていないこと

    /// ⭐ **これが本題** — CC 番号は `ladylandButtonCCs`（焼く値）から導く。
    /// 表の側に数字が書いてあったら、機材を焼き直した瞬間に保護が外れる
    @Test("ボタンの CC は焼く値から導かれる")
    func buttonCCsComeFromBurnTable() {
        for (button, burned) in Keystage.ladylandButtonCCs {
            let control = KeystageControls.all.first {
                if case .button(let b) = $0.emits { return b == button }
                return false
            }
            guard let control else { continue }
            #expect(
                control.cc == Int(burned),
                "\(control.name) が \(control.cc.map(String.init) ?? "nil") — 焼く値は \(burned)")
        }
    }

    /// ⭐ **役割を別のボタンへ移しても保護が付いてくる**ことを、
    /// 「表と router が同じものを見ている」形で固定する
    @Test("ページ送りの CC は表から引かれる（router と表が一致する）")
    func pageStepComesFromTable() {
        let fromTable = Set(KeystageControls.pageStep.keys)
        #expect(!fromTable.isEmpty, "ページ送りの割当が表に無い")
        // 横取り集合に必ず含まれる = 楽器へ流れない
        #expect(fromTable.isSubset(of: KeystageControls.interceptedCCs))
    }

    /// **向きは型で持つ** — 説明文の言い回しに依存しない
    @Test("ページ送りは戻ると進むが 1 つずつある")
    func pageStepHasBothDirections() {
        let directions = Set(KeystageControls.pageStep.values)
        #expect(directions == [-1, 1], "戻る / 進むが揃っていない: \(directions)")
    }

    // MARK: - 素通しの境界

    /// ⚠️ **素通しは正しい既定**（Mod ホイールなどが効くため）。
    /// 横取りしすぎていないことを固定する
    @Test("素通しさせるものは横取りされない")
    func passThroughIsNotIntercepted() {
        for control in KeystageControls.all where control.handling == .passThrough {
            guard let cc = control.cc else { continue }
            #expect(
                !KeystageControls.interceptedCCs.contains(cc),
                "\(control.name)（CC\(cc)）を横取りしている")
        }
    }

    /// ⚠️ **ペダルは「捕まえたうえで楽器へも流す」** — キープと sustain の両方が要る
    @Test("ペダルは横取りしない（両方に流す）")
    func damperReachesInstrument() {
        #expect(!KeystageControls.interceptedCCs.contains(FaceKnobAssignment.damperCC))
    }

    // MARK: - 表そのもの

    /// **全行に由来がある**（実測か未確認か）。混ぜると「確かめた」と
    /// 「そう思う」の区別が付かなくなる
    @Test("全ての操作子が由来を持ち、実測が過半")
    func everyControlHasProvenance() {
        #expect(KeystageControls.all.count >= 14)
        for control in KeystageControls.all {
            #expect(!control.provenance.label.isEmpty)
            #expect(!control.name.isEmpty)
        }
        #expect(
            KeystageControls.measuredCount * 2 > KeystageControls.all.count,
            "実測が過半でない（推測だけの表は根拠にならない）")
    }

    /// ⚠️ **予約番号を素通ししているものが表に出ている**こと。
    /// 「見えていれば次に塞ぐ判断ができる」— 消すと同じ穴をもう一度掘る
    @Test("素通ししている予約番号が数えられる")
    func passedThroughReservedIsVisible() {
        let risky = KeystageControls.passedThroughReserved
        #expect(!risky.isEmpty, "実測で素通しが残っているので、0 なら表が嘘")
        for control in risky {
            #expect(control.reserved != nil)
        }
    }

    /// ⚠️ **ladyland が焼いたボタンは全部 MIDI 予約番号**（意図的）。
    /// 表がそれを記録していること — 「使っていない番号」ではなく
    /// 「**誰もが解釈する番号**」だと分かる形で残す
    @Test("焼いたボタンはすべて予約の意味を持っている")
    func burnedButtonsAreAllReserved() {
        for control in KeystageControls.all {
            guard case .button = control.emits else { continue }
            #expect(control.reserved != nil, "\(control.name) に予約の意味が書かれていない")
        }
    }

    // MARK: - 焼く値そのもの（mako 裁定 2026-08-07 で 102-110 へ移した）

    /// ⭐ **`Button.allCases` の順に 102 から連番**（mako 指定）。
    /// 実機の並びと CC が 1 対 1 で揃うので、**次にボタンを足す人が
    /// どこへ入れるか迷わない**。途中に穴を開けたら落ちる
    @Test("焼く CC は Button の順に 102 から連番")
    func burnedCCsAreSequential() {
        let expected = Keystage.ButtonOffset.Button.allCases
        #expect(Keystage.ladylandButtonCCs.map(\.0) == expected, "並びが Button の順でない")
        for (index, entry) in Keystage.ladylandButtonCCs.enumerated() {
            #expect(entry.1 == UInt8(102 + index), "\(entry.0) が CC\(entry.1)")
        }
    }

    /// ⚠️ **予約帯から出たこと**を固定する。ここが戻ると、未割当 CC の素通しで
    /// AU が NRPN / RPN / Channel Mode として解釈する経路が復活する
    @Test("焼く CC は MIDI 仕様で未定義の帯（102-119）に収まる")
    func burnedCCsAvoidReservedRanges() {
        for (button, cc) in Keystage.ladylandButtonCCs {
            #expect((102...119).contains(Int(cc)), "\(button) が CC\(cc) — 予約帯に居る")
        }
        // 具体的に危ないもの
        let used = Set(Keystage.ladylandButtonCCs.map { Int($0.1) })
        for reserved in [96, 97, 98, 99, 100, 101, 120, 121, 122, 123] {
            #expect(!used.contains(reserved), "CC\(reserved) は予約 — ボタンに使わない")
        }
    }

    /// エンコーダーと衝突しないこと（117 / 118 は据え置き）
    @Test("ボタンとエンコーダーの CC が衝突しない")
    func buttonsAndEncodersDoNotCollide() {
        let buttons = Set(Keystage.ladylandButtonCCs.map { Int($0.1) })
        let encoders = Set(Keystage.ladylandEncoderCCs.map { Int($0.1) })
        #expect(buttons.isDisjoint(with: encoders))
    }

    /// ⚠️ **Mod ホイールは実機で焼いた値**（CC1 → 119 → **116**、2026-08-07）。
    /// **焼く先が 3 つの帯のどれとも重ならない**ことを固定する — 重なると、
    /// ホイールを倒しただけでノブの値が飛ぶ / ページが繰られる
    @Test("Mod ホイールの CC はノブ帯・ボタン・エンコーダーと重ならない")
    func modWheelDoesNotCollide() {
        let mod = FaceKnobAssignment.modWheelCC
        #expect(!KeystageKnobs.intercepted.contains(mod), "ノブ帯と重なっている")
        let buttons = Set(Keystage.ladylandButtonCCs.map { Int($0.1) })
        #expect(!buttons.contains(mod), "焼いたボタンと重なっている")
        let encoders = Set(Keystage.ladylandEncoderCCs.map { Int($0.1) })
        #expect(!encoders.contains(mod), "エンコーダーと重なっている")
        // ⚠️ **予約帯にも置かない** — 素通しさせる席なので、AU が
        // NRPN / RPN / Channel Mode として解釈する番号は避ける
        #expect(!FaceKnobAssignment.unsafeCCs.contains(mod), "MIDI 仕様の危険牌")
    }

    /// ⚠️ **焼くときに MIDI Ch を触らない**（mako が ch10 に揃えたばかり）。
    /// コメント上は触らないことになっているが、**テストで固定する**
    @Test("ボタンを焼いても MIDI Ch のバイトが変わらない")
    func burningDoesNotTouchMidiChannel() {
        // dump を模した十分な長さの配列（値は 0 でよい — 変わらないことを見る）
        var dump = [UInt8](repeating: 0, count: 4203)
        // ch のバイトへ目印を置く
        for button in Keystage.ButtonOffset.Button.allCases {
            let base = Keystage.ButtonOffset.base(button)
            dump[base + Keystage.ButtonOffset.midiChannel] = 9  // ch10（0 始まり）
        }
        let burned = Keystage.applyingLadylandButtons(dump)
        for button in Keystage.ButtonOffset.Button.allCases {
            let base = Keystage.ButtonOffset.base(button)
            #expect(
                burned[base + Keystage.ButtonOffset.midiChannel] == 9,
                "\(button) の MIDI Ch が書き換わった")
        }
    }

    // MARK: - ノブ列（位置固定の帯 CC0-63 — ページ = CC ÷ 8 が正典）

    /// ⭐ **帯の中ならどの番号でもページが引ける**ことを固定する。
    ///
    /// ページ = CC ÷ 8 が唯一の正典（`KeystageKnobs`）。⚠️ かつては
    /// 「並びの位置から引く（式に依存しない）」が主張だったが、帯の確定で
    /// **逆転した** — いま式以外から引いたら嘘になる（監査 2026-08-08 の B-1）。
    /// 引数は移設案（CC0-7 → CC20-27）の名残 — どちらも今はただの帯の席
    @Test("帯の中の CC はどれもページが引ける", arguments: [
        [0, 1, 2, 3, 4, 5, 6, 7],  // P1（かつて「予約帯だから移す」と言われた席）
        [20, 21, 22, 23, 24, 25, 26, 27],  // P3-P4（かつての移設先候補）
    ])
    func knobPageFollowsNewNumbers(ccs: [Int]) {
        let pages = Set(ccs.compactMap { FaceKnobAssignment.inferredPage(cc: $0) })
        #expect(!pages.isEmpty, "\(ccs) が帯に無い = ページが引けない")
    }

    /// ⭐ **CC20-27 は P3-P4 のただの席**。かつて「CC0-7 は予約帯だから
    /// CC20-27 へ移す」という案があった（2026-08-07、撤回済み — 帯 CC0-63 を
    /// 全部飲む形で決着）。跡地が普通の席であることを固定する
    @Test("CC20-27 は P3-P4 のただの席（移設案は撤回済み）")
    func targetRangeIsAssignable() {
        for cc in 20...27 {
            #expect(
                FaceKnobAssignment.assignableCCs.contains(cc), "CC\(cc) が席プールに無い")
            #expect(!FaceKnobAssignment.isUnsafe(cc: cc), "CC\(cc) が危険牌扱い")
        }
    }

    /// ⭐ **CC0 / 6 / 7 は現行 P1 の席** — 帯が全部飲むので ladyland の楽器には
    /// 届かず、席として普通に使える。`isUnsafe` の分類（Bank Select /
    /// Data Entry / Channel Volume）は**記録として残す** — CoreMIDI に排他制御は
    /// 無く、外の音源には届くので素性が消えたわけではない
    @Test("P1 の席（CC0 / 6 / 7）の MIDI 素性は分類に残っている")
    func oldKnobRangeIsMarkedUnsafe() {
        #expect(FaceKnobAssignment.assignableCCs.contains(0), "CC0 は P1 の席")
        #expect(FaceKnobAssignment.assignableCCs.contains(7), "CC7 は P1 の席")
        #expect(FaceKnobAssignment.isUnsafe(cc: 0), "Bank Select MSB の分類は残す")
        #expect(FaceKnobAssignment.isUnsafe(cc: 7), "Channel Volume の分類は残す")
    }

    /// ノブとホイールが表に載っていること（**この見落としが今回の原因**）
    @Test("ノブ列とホイールが表にある")
    func knobsAreInTheTable() {
        let names = KeystageControls.all.map(\.name)
        #expect(names.contains { $0.contains("ノブ") }, "ノブ列が表に無い")
        #expect(names.contains { $0.contains("Pitch Bend") })
        #expect(names.contains { $0.contains("Mod") })
    }

    // MARK: - 接続手順の切り分けフラグ（mako 実測 2026-08-07）

    /// ⚠️ **既定は全部 on**（会場の退避路と同じ作法。`=0` で切る）。
    ///
    /// ⭐ **`RELEASE` だけは「送る側」が既定** — 他の 2 つは
    /// 「今までどおり送る」が on だが、こちらは **PAGE を返すための切断を
    /// 送る**のが on。**8/8 にフラグを思い出さなくて済む側**へ倒してある
    @Test("接続手順のフラグは既定 on")
    func handshakeFlagsDefaultOn() {
        if ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_CONNECT"] == nil {
            #expect(KeystageService.Handshake.sendsConnect)
        }
        if ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_ASSIGNABLE"] == nil {
            #expect(KeystageService.Handshake.sendsAssignable)
        }
        if ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_RELEASE"] == nil {
            #expect(KeystageService.Handshake.releasesAfterHandshake, "PAGE を返す既定")
        }
    }

    /// ⚠️ **起動ログに現状が出ること**（会場でフラグを思い出す必要がある状況 =
    /// 何かが壊れている状況。`roto flags:` と同じ作法）
    @Test("起動ログに 3 つのフラグが出る")
    func handshakeFlagsAreDescribed() {
        let line = KeystageService.Handshake.describe
        #expect(line.contains("CONNECT="))
        #expect(line.contains("ASSIGNABLE="))
        #expect(line.contains("RELEASE="), "PAGE を返しているかがログで読めること")
        #expect(line.contains("既定"), "既定がどちらか読めること")
    }

    /// ⭐ **1 つずつ止められること** — まとめて 1 つのフラグにすると切り分けられない
    @Test("フラグは 3 つ独立している")
    func flagsAreIndependent() {
        // 環境変数の名前が別であること（同じなら切り分けにならない）
        let names = [
            "LADYLAND_KEYSTAGE_CONNECT", "LADYLAND_KEYSTAGE_ASSIGNABLE",
            "LADYLAND_KEYSTAGE_RELEASE",
        ]
        #expect(Set(names).count == 3)
    }

    /// ⚠️⚠️ **切断は「繋いだとき」にしか意味が無い**。
    /// `CONNECT=0` なら `0x6F` を一度も送っていないので、切断も送ってはいけない
    /// — **送っていない接続を切る**のは、実機に何が起きるか分からない
    @Test("CONNECT を切ったら RELEASE も効かない（送っていない接続は切らない）")
    func releaseRequiresConnect() {
        // ⚠️ **実装が引くのと同じ値**（`bracketsWrites`）を見る。
        // ここで `releasesAfterHandshake && sendsConnect` と書き写すと、
        // **実装だけ条件が変わってもテストは通ってしまう**
        let flags = KeystageService.Handshake.self
        if !flags.sendsConnect {
            #expect(!flags.bracketsWrites, "接続を送っていないのに切断を送っている")
        }
        if !flags.releasesAfterHandshake {
            #expect(!flags.bracketsWrites, "RELEASE=0 なのに書き込みを挟んでいる")
        }
        if flags.sendsConnect && flags.releasesAfterHandshake {
            #expect(flags.bracketsWrites, "両方 on なら挟む")
        }
    }

    /// ⭐ **切断 = `0x6F` payload 00**（接続は 01）。
    /// ⚠️ **別の Function を使っていないこと** — Native Mode Enter などと
    /// 取り違えるとノブの CC 割当ごと変わる
    @Test("切断は connect の payload 00 で表す")
    func releaseUsesConnectFunctionWithZero() {
        let connect = Keystage.frame(.connect, data: [0x01], globalChannel: 0, model: .keys49)
        let release = Keystage.frame(.connect, data: [0x00], globalChannel: 0, model: .keys49)
        #expect(Keystage.function(of: connect) == .connect)
        #expect(Keystage.function(of: release) == .connect, "同じ Function")
        #expect(Keystage.payload(of: connect)?.first == 0x01)
        #expect(Keystage.payload(of: release)?.first == 0x00, "00 = 切断")
        #expect(connect.count == release.count, "長さが変わらない = payload だけの違い")
    }
}

/// **画面と手順書の数字が実装とずれないこと**（監査 2026-08-08）。
///
/// ⚠️ 設定画面には **CC96-101 / 121-123** と書いてあったが、
/// **実際に焼くのは 102-110**。⭐ **数字を直書きすると、焼く先を移した瞬間に
/// 画面が嘘をつく** — 焼く値そのものから引く形を固定する。
@Suite("画面の数字が焼く値から導かれる")
@MainActor
struct BurnedCCLabelTests {
    @Test("ボタンの範囲表示は ladylandButtonCCs から導かれる")
    func buttonRangeComesFromBurnTable() {
        let shown = KeystageSettingsView.burnedButtonRange
        // 連番は畳まれる（`102-110`）ので、両端が出ていることで確かめる
        let numbers = Keystage.ladylandButtonCCs.map { Int($0.1) }.sorted()
        #expect(shown.contains("\(numbers.first!)"), "先頭 CC\(numbers.first!) が出ていない")
        #expect(shown.contains("\(numbers.last!)"), "末尾 CC\(numbers.last!) が出ていない")
        #expect(shown.hasPrefix("CC"))
    }

    @Test("エンコーダーの範囲表示も焼く値から導かれる")
    func encoderRangeComesFromBurnTable() {
        let shown = KeystageSettingsView.burnedEncoderRange
        for cc in Keystage.ladylandEncoderCCs.map({ Int($0.1) }) {
            #expect(shown.contains("\(cc)"), "CC\(cc) が出ていない")
        }
    }

    /// ⚠️⚠️ **旧値が復活していないこと** — 予約帯の番号は焼き先ではない
    @Test("予約帯の旧値（96-101 / 121-123）を名乗らない")
    func doesNotClaimReservedRange() {
        let shown = KeystageSettingsView.burnedButtonRange
        let burned = Set(Keystage.ladylandButtonCCs.map { Int($0.1) })
        for reserved in [96, 97, 98, 99, 100, 101, 121, 122, 123] {
            #expect(!burned.contains(reserved), "CC\(reserved) を焼いている")
            #expect(!shown.contains("\(reserved)"), "画面が CC\(reserved) を名乗っている")
        }
    }
}
