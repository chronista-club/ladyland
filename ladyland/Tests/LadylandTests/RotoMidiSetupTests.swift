//! ROTO MIDI モード setup 書き出し（2026-08-11 方向転換）。
//!
//! フォーマットの正解は **ROTO-SETUP の Export All が吐いた実物**
//! （docs/roto-control/backups/ROTO-CONTROL 2026-08-11 16.33.35/MIDI/SETUP 01.json）。
//! スナップショットはそこから転記した — 生成器がこの形とバイト単位で一致する限り、
//! Import All に読めない文書を作る事故は起きない。

import Foundation
import RotoKit
import Testing

@testable import Ladyland

@Suite("ROTO MIDI setup 文書")
struct RotoMidiSetupDocumentTests {
    /// Export All 実物の再現（knob 1 本、未編集の既定値）。
    /// フィールド順・インデント・末尾改行なし、まで実物と同じ
    @Test func 実物のExportと同形() {
        let document = RotoMidiSetup.document(
            name: "SETUP 01", index: 0,
            knobs: [
                RotoMidiSetup.Knob(
                    controlIndex: 7, channel: 1, cc: 0,
                    name: "CH:1/CC:0", colorScheme: 70)
            ])
        let expected = """
            {
                "version": 1,
                "type": "MIDI",
                "name": "SETUP 01",
                "index": 0,
                "knobs": [
                    {
                        "controlIndex": 7,
                        "controlMode": 0,
                        "controlChannel": 1,
                        "controlParam": 0,
                        "nrpnAddress": 0,
                        "minValue": 0,
                        "maxValue": 127,
                        "controlName": "CH:1/CC:0",
                        "colorScheme": 70,
                        "hapticMode": 0,
                        "hapticIndent1": 255,
                        "hapticIndent2": 255,
                        "hapticSteps": 0,
                        "stepNames": [
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            ""
                        ]
                    }
                ],
                "buttons": []
            }
            """
        #expect(document == expected)
    }

    /// 名前に JSON を壊す文字が来ても文書は壊れない
    @Test func 名前のエスケープ() throws {
        let document = RotoMidiSetup.document(
            name: #"A"B\C"#, index: 3,
            knobs: [
                RotoMidiSetup.Knob(controlIndex: 0, channel: 1, cc: 1, name: "\"", colorScheme: 0)
            ])
        let parsed = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any]
        #expect(parsed?["name"] as? String == #"A"B\C"#)
    }
}

@Suite("ROTO MIDI setup — 64 席正典の転写")
struct RotoMidiSetupExportTests {
    /// 冊 s のノブ位置 p = 席 CC (s×32 + p)。ズレたら ROTO のノブが
    private let names = (0..<32).map { "T\($0 + 1)" }

    /// 別の席のパラメータを回す — ここが生成器の心臓。
    /// 正典は `KnobPages`（ページ = CC ÷ 8）— Keystage と同じ CC 地図。
    /// 冊の並びは MIXER ×2 が先頭、INST ×2 が SETUP 03/04（mako 裁定
    /// 2026-08-13「SELECT の並び、MIXER / MIXER+ / INST / INST+」）
    @Test func 席のCCが正典どおり() throws {
        let setups = RotoMidiSetupExport.setups(slotNames: names)
        #expect(setups.count == 4)
        for (half, setup) in setups.suffix(2).enumerated() {
            let parsed =
                try JSONSerialization.jsonObject(with: Data(setup.contents.utf8)) as? [String: Any]
            let knobs = try #require(parsed?["knobs"] as? [[String: Any]])
            #expect(knobs.count == 32)  // 4 ページ × 8 ノブ
            #expect(parsed?["index"] as? Int == RotoMidiSetupExport.instSetup1 + half)
            for (position, knob) in knobs.enumerated() {
                let cc = try #require(knob["controlParam"] as? Int)
                #expect(cc == KnobPages.all[half * 32 + position])
                #expect(knob["controlIndex"] as? Int == position)
                #expect(knob["controlChannel"] as? Int == 1)
                // 名前は正典の席名（P1-1 …）+ CC 番号
                #expect(knob["controlName"] as? String == "\(KnobPages.label(forCC: cc)!) CC\(cc)")
            }
        }
    }

    /// MIXER 冊（SETUP 01/02 の 2 冊 = Track 64。後半は「+」）: ch2、CC =
    /// **通し**のスロット番号、名前はスロット名のスナップショット（名簿の外は
    /// T 番号）、色はバンクごとに淡色帯の 36-39（席冊と被らない。両冊で繰り返す）
    @Test func ミキサー冊の中身() throws {
        let setups = RotoMidiSetupExport.setups(slotNames: names)
        for (half, mixer) in setups.prefix(2).enumerated() {
            let bookName = half == 0 ? "MIXER-" : "MIXER+"
            #expect(mixer.fileName == "\(bookName).json")
            let parsed =
                try JSONSerialization.jsonObject(with: Data(mixer.contents.utf8)) as? [String: Any]
            #expect(parsed?["name"] as? String == bookName)
            #expect(
                parsed?["index"] as? Int
                    == (half == 0
                        ? RotoMidiSetupExport.mixerSetup1 : RotoMidiSetupExport.mixerSetup2))
            let knobs = try #require(parsed?["knobs"] as? [[String: Any]])
            #expect(knobs.count == 32)
            for (position, knob) in knobs.enumerated() {
                let slot = half * 32 + position
                #expect(knob["controlChannel"] as? Int == 2)
                #expect(knob["controlIndex"] as? Int == position)  // 冊内位置
                #expect(knob["controlParam"] as? Int == slot)  // CC は通し
                #expect(knob["controlName"] as? String == "T\(slot + 1)")
                #expect(knob["colorScheme"] as? Int == 36 + position / 8)
            }
        }
    }

    /// MIXER 冊のボタン 1-8 = 真上のノブのスロットを直接選択（ch2 CC 64+、
    /// PUSH — 押下で選択、離しは無視。mako 裁定 2026-08-13。
    /// RK 冊切替と ch3 コマンドレーンは同日オミット — SEL で冊を移る）
    @Test func 選択ボタンが真上のノブと対応する() {
        let books = RotoMidiSetupExport.books(slotNames: names)
        #expect(books.count == 4)
        // 並びは MIXER ×2 → INST ×2（mako 裁定 2026-08-13）— ボタンは MIXER だけ
        #expect(books[0].setupIndex == RotoMidiSetupExport.mixerSetup1)
        #expect(books[1].setupIndex == RotoMidiSetupExport.mixerSetup2)
        for (half, book) in books.prefix(2).enumerated() {
            let selects = book.buttons
            #expect(selects.count == 32)  // 全席（冊切替オミットでボタン 8 も空いた）
            for button in selects {
                let slot = half * 32 + button.controlIndex
                #expect(button.channel == RotoMidiSetupExport.mixerChannel)
                #expect(button.cc == RotoMidiSetupExport.mixerButtonCCBase + slot)  // CC は通し
                #expect(button.toggle == false)  // PUSH（押下 127 で発火）
                // 最小表現 — 名前は真上のノブに出ているのでボタンは番号だけ
                #expect(button.name == "T\(slot + 1)")
                #expect(button.name.utf8.count <= 13)
            }
        }
        // 席冊（INST）にボタンは居ない
        #expect(books.suffix(2).allSatisfy { $0.buttons.isEmpty })
    }

    /// ⚠️ **実経路（handleShort）を通す** — 受信側が呼んでいなければ純関数が
    /// 正しくても意味が無い（席 CC 適用欠落 #130 の教訓）。
    /// 押下（127）で選択、離し（0）では選択しない
    @Test @MainActor func 選択ボタンの押下だけが選択を発火する() {
        let rack = InstrumentRack()
        let roto = RotoService()
        roto.attach(rack: rack)
        var selected: [Int] = []
        roto.onSelectTrack = { selected.append($0) }
        roto.receiveShortForTesting(0xB1, 64 + 2, 127)  // T3 押下
        roto.receiveShortForTesting(0xB1, 64 + 2, 0)  // 離し
        #expect(selected == [2], "押下で 1 回だけ（離しで 2 度目が来ない）")
    }

    /// JSON にもボタンが載る（Import 互換は Export 実物との突合が済むまで暫定）
    @Test func ボタンのJSON() throws {
        let setups = RotoMidiSetupExport.setups(slotNames: names)
        let mixer1 = try JSONSerialization.jsonObject(
            with: Data(setups[0].contents.utf8)) as? [String: Any]
        let buttons = try #require(mixer1?["buttons"] as? [[String: Any]])
        #expect(buttons.count == 32)  // 全席が選択ボタン
        #expect(buttons[0]["controlIndex"] as? Int == 0)
        #expect(buttons[0]["controlChannel"] as? Int == 2)
        #expect(buttons[0]["controlParam"] as? Int == 64)
        #expect(buttons[0]["controlName"] as? String == "T1")
        #expect(buttons[0]["hapticMode"] as? Int == 0)  // PUSH
        // +MIXER の先頭 = T33（CC 96 = 64 + 32 — 通しの上半分後半）
        let mixer2 = try JSONSerialization.jsonObject(
            with: Data(setups[1].contents.utf8)) as? [String: Any]
        let buttons2 = try #require(mixer2?["buttons"] as? [[String: Any]])
        #expect(buttons2[0]["controlIndex"] as? Int == 0)
        #expect(buttons2[0]["controlParam"] as? Int == 96)
        #expect(buttons2[0]["controlName"] as? String == "T33")
    }

    /// スロット名が 13 byte を超えても切り詰めて壊れない
    @Test func ミキサー席名の切り詰め() {
        let long = ["Phase Plant Ultra Edition"] + Array(repeating: "x", count: 31)
        let knobs = RotoMidiSetupExport.mixerKnobs(names: long)
        #expect(knobs[0].name.utf8.count <= 13)
        #expect(knobs[0].name == "Phase Plant U")
    }

    /// MIXER 冊の選択席は**名前の頭に「>」**、地色はトラックカラーのまま
    /// （mako 経緯 2026-08-13: 地色ハイライトは「色がありすぎて判別できない」—
    /// 色ではなく位置固定の記号で示す）
    @Test func ミキサー選択席は記号で示し色は変えない() {
        var colors = [UInt8?](repeating: nil, count: 32)
        colors[0] = 71  // 赤
        let knobs = RotoMidiSetupExport.mixerKnobs(
            names: names, colors: colors, selectedSlot: 0)
        #expect(knobs[0].name == ">T1")
        #expect(knobs[0].colorScheme == 71)  // 地色はトラックカラーのまま
        #expect(knobs[1].name == "T2")  // 非選択に印は付かない
        #expect(knobs[1].colorScheme == 36)  // 未設定はバンク色
        #expect(knobs[8].colorScheme == 37)
        #expect(knobs.allSatisfy { $0.name.utf8.count <= 13 })
        // 後半冊（half 1）: 通しスロットで選択判定 — T33 = slot 32 = 冊内位置 0
        let back = RotoMidiSetupExport.mixerKnobs(
            names: names, selectedSlot: 32, half: 1)
        #expect(back[0].name == ">T33")
        #expect(back[0].cc == 32)  // CC も通し
        #expect(back[1].name == "T34")
    }

    /// INST 冊のライブラベルと席色 — 割当がある席は選択スロットの割当名、
    /// 無い席は正典ラベル。色はトラックカラー > ページ色
    @Test func 席冊のライブラベル() {
        let labels = [0: "Cutoff", 33: "Reverb Mix"]
        let front = RotoMidiSetupExport.seatKnobs(half: 0, labels: labels, color: 22)
        #expect(front[0].name == "Cutoff")
        #expect(front[1].name == "\(KnobPages.label(forCC: 1)!) CC1")  // 正典のまま
        #expect(front.allSatisfy { $0.colorScheme == 22 })  // 全席トラックカラー
        let back = RotoMidiSetupExport.seatKnobs(half: 1, labels: labels)
        #expect(back[1].name == "Reverb Mix")  // CC33 = 後半冊の位置 1
        #expect(back[0].colorScheme == 32)  // 色 nil = ページ色（CC32 = P5）
    }

    /// ライブラベルも 13 byte に切り詰める（LCD の物理制約）
    @Test func ライブラベルの切り詰め() {
        let knobs = RotoMidiSetupExport.seatKnobs(
            half: 0, labels: [0: "Filter Resonance Amount"])
        #expect(knobs[0].name.utf8.count <= 13)
    }

    /// 席色の優先順は **席色（trackCells）> トラックカラー > ページ色**
    /// （mako 要望 2026-08-12「ノブ毎の色」— LCD の地は 1 色なので全体の地色）
    @Test func 席色はセル指定が最優先() {
        let knobs = RotoMidiSetupExport.seatKnobs(
            half: 0, labels: [:], color: 22, cellColors: [1: 71])
        #expect(knobs[1].colorScheme == 71)  // セル指定
        #expect(knobs[0].colorScheme == 22)  // トラックカラー
        let plain = RotoMidiSetupExport.seatKnobs(half: 0, cellColors: [1: 71])
        #expect(plain[0].colorScheme == 28)  // どちらも無ければページ色
    }

    /// INST 冊の冊名 = 「TR{番号}{-|+} {inst 名}」（mako 裁定 2026-08-14
    /// 「-Tn は TRn-/+ に」— 記号は後置。実効 12 バイト）
    @Test func 冊名はTナンバーとinst名() {
        let books = RotoMidiSetupExport.books(slotNames: names, selectedTrack: 3)
        #expect(books[0].name == "MIXER-")
        #expect(books[1].name == "MIXER+")
        #expect(books[2].name == "TR3- T3")  // テスト名簿はスロット名も T3
        #expect(books[3].name == "TR3+ T3")
        #expect(books.allSatisfy { $0.name.utf8.count <= 12 })
        // 長い inst 名は 12 バイトへ切り詰め（クリップ後の尻尾の空白は掃く）
        #expect(
            RotoMidiSetupExport.instBookName(
                set: 1, selectedTrack: 2, trackName: "Montreal (E.Piano)")
                == "TR2- Montrea")
        #expect(
            RotoMidiSetupExport.instBookName(
                set: 2, selectedTrack: 25, trackName: "Firenze (Clav)")
                == "TR25+ Firenz")
        // inst 名が無いときは番号へ畳む（記号は残す）
        #expect(RotoMidiSetupExport.instBookName(set: 1, selectedTrack: 7) == "TR7-")
        #expect(RotoMidiSetupExport.instBookName(set: 2, selectedTrack: 7) == "TR7+")
        // JSON 控え（selectedTrack なし）はベース名 — 選択依存の一時状態を残さない
        #expect(RotoMidiSetupExport.setups(slotNames: names)[2].fileName == "INST-.json")
        #expect(RotoMidiSetupExport.setups(slotNames: names)[3].fileName == "INST+.json")
    }

    /// **全席 = set XOR clear**（mako 指摘 2026-08-12「L02 INST はゴミが多い」）。
    /// 4 冊 × ノブ 32 + ボタン 32 の全席が必ず載る — 焼くこと自体がまっさら化
    @Test func 全席は設定か掃除のどちらか() {
        let requests = RotoMidiSetupExport.allRequests(
            slotNames: names, seatLabels: [0: "Cutoff"])
        // 冊名 4 + (ノブ 32 + ボタン 32) × 4 冊 + 掃除冊（名前 1 + 64 席）× 2
        #expect(requests.count == 4 + 64 * 4 + 65 * RotoMidiSetupExport.scrubSetups.count)
        func isClear(_ request: [UInt8]) -> Bool {
            request.count > 2 && request[2] == RotoAdmin.Midi.clearControlConfig
        }
        // MIXER 冊（SETUP 01/02）: ノブ 32 全部 set、ボタンも 32 全部 set（Track 直接選択）
        for setup in [RotoMidiSetupExport.mixerSetup1, RotoMidiSetupExport.mixerSetup2] {
            let mixer = requests.filter { $0.key.setup == setup && $0.key.kind != .name }
            #expect(mixer.count == 64)
            #expect(mixer.allSatisfy { !isClear($0.request) })
        }
        // INST 冊（SETUP 03）: 割当のある CC0 の席だけ set、残りのノブは clear。
        // ボタンは全 clear（RK 冊切替は 2026-08-13 オミット）
        let instKnobs = requests.filter {
            $0.key.setup == RotoMidiSetupExport.instSetup1 && $0.key.kind == .knob
        }
        #expect(instKnobs.count { !isClear($0.request) } == 1)
        let instButtons = requests.filter {
            $0.key.setup == RotoMidiSetupExport.instSetup1 && $0.key.kind == .button
        }
        #expect(instButtons.allSatisfy { isClear($0.request) })
        // 掃除冊（SETUP 05/06 — 旧配置の残骸）: 冊名は工場既定へ、全 64 席 clear
        for setup in RotoMidiSetupExport.scrubSetups {
            let scrub = requests.filter { $0.key.setup == setup }
            #expect(scrub.count == 65)
            #expect(scrub.filter { $0.key.kind != .name }.allSatisfy { isClear($0.request) })
        }
    }

    /// 席冊 2 冊で帯 CC0-63 を過不足なく覆う — Keystage と同じ地図であること
    /// （新しいサーフェスは KnobPages を参照する。mako 裁定 2026-08-10）
    @Test func 帯を過不足なく覆う() throws {
        var covered: [Int] = []
        for setup in RotoMidiSetupExport.setups(slotNames: names).suffix(2) {
            let parsed =
                try JSONSerialization.jsonObject(with: Data(setup.contents.utf8)) as? [String: Any]
            let knobs = try #require(parsed?["knobs"] as? [[String: Any]])
            covered += knobs.compactMap { $0["controlParam"] as? Int }
        }
        #expect(covered == KnobPages.all)
    }

    /// ページの識別は色でやる — 正典ページ（8 ノブの塊）ごとに 1 色、
    /// 席 8 ページ + ミキサー 4 バンクの計 12 色が全部違う
    /// （MIXER 2 は MIXER 1 と同じ帯 36-39 を繰り返す — 冊は MAIN LCD で区別）
    @Test func ページ色は12ページで重複しない() throws {
        var colors: [Int] = []
        for setup in RotoMidiSetupExport.setups(slotNames: names) {
            let parsed =
                try JSONSerialization.jsonObject(with: Data(setup.contents.utf8)) as? [String: Any]
            let knobs = try #require(parsed?["knobs"] as? [[String: Any]])
            for pageStart in stride(from: 0, to: knobs.count, by: 8) {
                let pageColors = Set(
                    knobs[pageStart..<pageStart + 8].compactMap { $0["colorScheme"] as? Int })
                #expect(pageColors.count == 1)  // ページ内は同色（ページの地色）
                colors.append(try #require(pageColors.first))
            }
        }
        #expect(colors.count == 16)  // 4 冊 × 4 ページ
        #expect(Set(colors).count == 12)  // MIXER 2 の 4 バンクは繰り返し
    }

    /// ノブ LCD の名前は DAW モードの 13 byte 制限に収める
    /// （MIDI モードの上限は未確認 — 確認までは厳しい方に合わせる）
    @Test func 名前は13文字以内() throws {
        for setup in RotoMidiSetupExport.setups(slotNames: names) {
            let parsed =
                try JSONSerialization.jsonObject(with: Data(setup.contents.utf8)) as? [String: Any]
            let knobs = try #require(parsed?["knobs"] as? [[String: Any]])
            for knob in knobs {
                let name = try #require(knob["controlName"] as? String)
                #expect(name.utf8.count <= 13)
            }
        }
    }

    /// Export All 互換のフォルダ構造で書けること（ROTO-CONTROL <日時>/MIDI/*.json）
    @Test func バックアップフォルダの形() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("roto-midi-setup-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let stamp = Date(timeIntervalSince1970: 1_784_000_000)
        let folder = try RotoMidiSetupExport.write(into: parent, slotNames: names, at: stamp)
        #expect(folder.lastPathComponent.hasPrefix("ROTO-CONTROL "))
        let files = try FileManager.default.contentsOfDirectory(
            atPath: folder.appendingPathComponent("MIDI").path)
        #expect(
            files.sorted() == [
                "INST+.json", "INST-.json", "MIXER+.json", "MIXER-.json",
            ])
    }
}
