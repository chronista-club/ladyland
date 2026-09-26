//! Jack の刺し替え（spec/09、mako 裁定 2026-09-26「スタジオにある MIDI 鍵盤を
//! Keystage の代わりに、Keystage のつまみの役は LPD8 で」）。
//!
//! 守りたい不変条件:
//!   - **未知の鍵盤は捨てない** — Keystage 不在ならシンセ入力 1、居ればシンセ入力 2
//!   - 汎用鍵盤は keyboard 経路の**演奏の帳簿（latch / 和音）**を共有しつつ、
//!     Keystage 専用の解釈（帯の飲み込み / PC ナビ / 焼きボタン）は通らない
//!   - LPD8 のノブ 8 は「drums」か「顔つまみ」のどちらかの Jack に刺さり、
//!     顔つまみのときは**位置 i → 現ページの席 i**

import Foundation
import Testing

@testable import Ladyland

private final class TraceBox: @unchecked Sendable {
    var routes: [MidiRoute] = []
}

// MARK: - 接続表（名前 → 経路）

@Suite("Jack 接続表 — 未知の鍵盤は捨てない")
struct MIDISourceRouteTests {
    @Test("既知の機材は従来どおり")
    func knownGear() {
        #expect(MIDIInput.route(forSourceName: "Keystage KBD/CTRL", hasKeystage: true) == .keystage)
        #expect(MIDIInput.route(forSourceName: "Keystage DAW IN", hasKeystage: true) == .keystage)
        #expect(MIDIInput.route(forSourceName: "LPD8 mk2", hasKeystage: true) == .drums)
        #expect(MIDIInput.route(forSourceName: "Arturia MiniLab mkII", hasKeystage: true) == .secondKeyboard)
        #expect(MIDIInput.route(forSourceName: "NCXse keyboard", hasKeystage: true) == .secondKeyboard)
        #expect(MIDIInput.route(forSourceName: "NCXse controller", hasKeystage: true) == nil, "意図的に繋がない")
    }

    @Test("未知の鍵盤 — Keystage 不在ならシンセ入力 1、居ればシンセ入力 2")
    func unknownKeyboard() {
        #expect(MIDIInput.route(forSourceName: "Roland A-88", hasKeystage: false) == .genericKeyboard)
        #expect(MIDIInput.route(forSourceName: "Roland A-88", hasKeystage: true) == .secondKeyboard)
        #expect(MIDIInput.route(forSourceName: "Nord Stage 3", hasKeystage: false) == .genericKeyboard)
    }

    @Test("鍵盤ではないものは繋がない — ROTO / IAC / Network")
    func excluded() {
        #expect(MIDIInput.route(forSourceName: "ROTO-CONTROL", hasKeystage: false) == nil)
        #expect(MIDIInput.route(forSourceName: "Roto Control", hasKeystage: false) == nil)
        #expect(MIDIInput.route(forSourceName: "IAC Driver Bus 1", hasKeystage: false) == nil)
        #expect(MIDIInput.route(forSourceName: "Network Session 1", hasKeystage: false) == nil)
    }

    @Test("名前の一覧から結線を組む — Keystage の有無は一覧全体で決まる")
    func plan() {
        let alone = MIDIInput.plan(sourceNames: ["Roland A-88", "LPD8 mk2"])
        #expect(alone == [
            MIDIConnectedSource(name: "Roland A-88", route: .genericKeyboard),
            MIDIConnectedSource(name: "LPD8 mk2", route: .drums),
        ])
        // Keystage が一覧の後ろに居ても、汎用鍵盤は鍵盤 2 へ
        let both = MIDIInput.plan(sourceNames: ["Roland A-88", "Keystage KBD/CTRL", "IAC Driver Bus 1"])
        #expect(both == [
            MIDIConnectedSource(name: "Roland A-88", route: .secondKeyboard),
            MIDIConnectedSource(name: "Keystage KBD/CTRL", route: .keystage),
        ])
    }
}

// MARK: - 汎用鍵盤の keyboard 経路

@Suite("汎用鍵盤 — keyboard 経路の通行証")
struct GenericKeyboardRouteTests {
    @Test("演奏は通る — ノート / ベンド / ダンパー。Mod（CC1）は ModWheel 席へ翻訳")
    func performanceForwards() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }

        router.routeKeyboard(0x90, 60, 100, origin: .generic)
        router.routeKeyboard(0xE0, 0, 64, origin: .generic)
        router.routeKeyboard(0xB0, 1, 80, origin: .generic)

        let mod = UInt8(FaceKnobAssignment.modWheelCC)
        #expect(box.routes == [
            .keyboard(status: 0x90, data1: 60, data2: 100, hasTarget: false),
            .keyboard(status: 0xE0, data1: 0, data2: 64, hasTarget: false),
            .keyboard(status: 0xB0, data1: mod, data2: 80, hasTarget: false),
        ])
    }

    @Test("Keystage 専用の解釈は通らない — 帯 / PC / 焼きボタン / 音量 CC7 は黙って落ちる")
    func keystageOnlyInterpretationsSkipped() {
        let router = MIDIRouter()
        let box = TraceBox()
        final class Nav: @unchecked Sendable { var steps: [Int] = [] }
        let nav = Nav()
        router.setTraceHandler { box.routes.append($0) }
        router.setNavHandler { step, _ in nav.steps.append(step) }
        router.setKnobRouting(ccs: [3]) { _, _ in }

        router.routeKeyboard(0xB0, 3, 100, origin: .generic)  // 帯（割当あり）— 席ではない
        router.routeKeyboard(0xB0, 7, 100, origin: .generic)  // 音量
        router.routeKeyboard(0xC0, 5, 0, origin: .generic)  // Program Change
        router.routeKeyboard(0xC0, 6, 0, origin: .generic)
        router.routeKeyboard(0xB0, 117, 127, origin: .generic)  // Keystage の REW と同じ番号
        router.routeKeyboard(0xB0, 32, 0, origin: .generic)  // Bank Select LSB

        #expect(box.routes.isEmpty, "何も楽器へ行かず、ナビも動かない")
        #expect(nav.steps.isEmpty)
    }

    @Test("キープの帳簿は共有 — ダンパーで鍵を離しても鳴り続ける")
    func latchShared() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }

        router.routeKeyboard(0x90, 60, 100, origin: .generic)
        router.routeKeyboard(0xB0, 64, 127, origin: .generic)  // 踏む
        router.routeKeyboard(0x80, 60, 0, origin: .generic)  // 離す → 握りつぶす

        #expect(box.routes.contains(.latch(engaged: true, released: 0)))
        #expect(box.routes.contains(.latchHold(note: 60, sustaining: 1)))
    }

    @Test("CC120 = All Sound Off は汎用鍵盤でも panic")
    func panic() {
        let router = MIDIRouter()
        final class Flag: @unchecked Sendable { var fired = 0 }
        let flag = Flag()
        router.setPanicHandler { flag.fired += 1 }
        router.routeKeyboard(0xB0, 120, 0, origin: .generic)
        #expect(flag.fired == 1)
    }

    @Test("既定は Keystage — 呼び方を変えない限り従来の契約")
    func defaultOriginIsKeystage() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }
        router.routeKeyboard(0xB0, 3, 100)
        #expect(box.routes == [.knob(cc: 3, value: 100)])
    }
}

// MARK: - LPD8 ノブ → 顔つまみ

@Suite("LPD8 ノブの Jack — drums / 顔つまみ")
struct Lpd8FaceKnobsTests {
    @Test("位置 i → 現ページの席 i（どの PROG のノブでも位置が同じなら同じ席）")
    func seatForCC() {
        let current = Lpd8DefaultKnobCCs.program1
        #expect(Lpd8FaceKnobs.seat(forCC: 79, current: current, page: 0) == 0)
        #expect(Lpd8FaceKnobs.seat(forCC: 86, current: current, page: 0) == 7)
        #expect(Lpd8FaceKnobs.seat(forCC: 79, current: current, page: 2) == 16, "P3-1")
        #expect(Lpd8FaceKnobs.seat(forCC: 90, current: current, page: 1) == 11, "PROG2 の K4 → P2-4")
        #expect(Lpd8FaceKnobs.seat(forCC: 117, current: current, page: 7) == 63, "PROG4 の K8 → P8-8")
        #expect(Lpd8FaceKnobs.seat(forCC: 1, current: current, page: 0) == nil, "ノブではない")
        #expect(Lpd8FaceKnobs.seat(forCC: 79, current: current, page: 8) == nil, "9 ページ目は無い")
    }

    @Test("エディタで焼き替えた現在の CC も位置で読む")
    func customCurrentCCs() {
        let custom: [UInt8] = [20, 21, 22, 23, 24, 25, 26, 27]
        #expect(Lpd8FaceKnobs.seat(forCC: 23, current: custom, page: 0) == 3)
        #expect(Lpd8FaceKnobs.interceptedCCs(current: custom).isSuperset(of: Set(custom)))
        #expect(Lpd8FaceKnobs.interceptedCCs(current: custom).isSuperset(of: Set(Lpd8DefaultKnobCCs.program1)))
    }

    @Test("顔つまみに刺さっているときは 4 プログラム分のノブ CC を全部飲む")
    func routerInterceptsFace() {
        let router = MIDIRouter()
        let box = TraceBox()
        final class Got: @unchecked Sendable { var events: [(UInt8, UInt8)] = [] }
        let got = Got()
        router.setTraceHandler { box.routes.append($0) }
        router.setDrumKnobRouting(ccs: [79]) { _, _ in }
        router.setLpd8FaceRouting(ccs: Lpd8FaceKnobs.interceptedCCs(current: Lpd8DefaultKnobCCs.program1)) {
            got.events.append(($0, $1))
        }

        router.routeDrums(0xB0, 79, 100)  // K1 — drums の割当より顔つまみが先
        router.routeDrums(0xB0, 94, 50)  // PROG2 の K8
        router.routeDrums(0x99, 44, 120)  // パッドは従来どおり drums へ

        #expect(box.routes == [
            .lpd8FaceKnob(cc: 79, value: 100),
            .lpd8FaceKnob(cc: 94, value: 50),
            .drums(status: 0x99, data1: 44, data2: 120, hasTarget: false),
        ])
        #expect(got.events.map(\.0) == [79, 94])
    }

    @Test("刺し先は raw 値で保存される（drums / face）")
    func jackRawValues() {
        #expect(Lpd8KnobJack.drums.rawValue == "drums")
        #expect(Lpd8KnobJack.face.rawValue == "face")
        #expect(Lpd8KnobJack(rawValue: "typo") == nil)
    }
}

// MARK: - 永続化

@Suite("LPD8 ノブの Jack — 永続化")
struct Lpd8KnobJackPersistenceTests {
    @Test("lldata snapshot を往復する")
    func snapshotRoundTrip() throws {
        var snapshot = RackSnapshot(slots: [], selected: 0)
        snapshot.lpd8KnobJack = "face"
        let imported = try LlDataSnapshot.import(
            LlDataSnapshot.export(snapshot, at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(imported.globals.lpd8KnobJack == "face")
    }

    @Test("SQLite を往復する")
    func databaseRoundTrip() throws {
        let db = try RackDatabase.inMemory()
        var snapshot = RackSnapshot(slots: [], selected: 0)
        snapshot.lpd8KnobJack = "face"
        try db.save(snapshot, includeBlobs: false)
        let loaded = try #require(try db.load())
        #expect(loaded.lpd8KnobJack == "face")
    }
}

// MARK: - Jack 結線図

@Suite("Jack 結線図 — 行は機材のセクション単位")
struct JackBoardRowsTests {
    @Test("汎用鍵盤は名前で行になり、結線先は接続表どおり")
    func genericKeyboardRow() {
        let rows = JackBoardView.gearRows(
            sources: [MIDIConnectedSource(name: "Roland A-88", route: .genericKeyboard)],
            lpd8KnobJack: .drums)
        let generic = rows.first { $0.gear == "Roland A-88" }
        #expect(generic?.jack == .synth1)
        #expect(generic?.connected == true)

        let second = JackBoardView.gearRows(
            sources: [
                MIDIConnectedSource(name: "Keystage KBD/CTRL", route: .keystage),
                MIDIConnectedSource(name: "Roland A-88", route: .secondKeyboard),
            ],
            lpd8KnobJack: .drums)
        #expect(second.first { $0.gear == "Roland A-88" }?.jack == .synth2)
        #expect(second.first { $0.id == "keystage.keys" }?.connected == true)
    }

    @Test("Keystage / LPD8 はセクションごとの行 — ノブ 8 は顔つまみ Jack に刺さる")
    func sectionRows() {
        let rows = JackBoardView.gearRows(sources: [], lpd8KnobJack: .face)
        #expect(rows.first { $0.id == "keystage.knobs" }?.jack == .faceKnobs)
        #expect(rows.first { $0.id == "lpd8.pads" }?.jack == .drums)
        #expect(rows.first { $0.id == "lpd8.knobs" }?.jack == .faceKnobs)
        #expect(rows.first { $0.id == "keystage.keys" }?.connected == false, "未接続は線が消える")

        let drums = JackBoardView.gearRows(sources: [], lpd8KnobJack: .drums)
        #expect(drums.first { $0.id == "lpd8.knobs" }?.jack == .drums)
    }
}
