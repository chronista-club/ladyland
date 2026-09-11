//! 面のポップアウト（別ウィンドウ化）のテスト
//! （mako 火花 2026-09-12「別ウィンドウに分けたい Pane あるんだよな。
//! 一枚の広い画面で設定したいやつ。機材の繋げる Editor とか」）。
//!
//! 置き場は window.json（マシン固有）。旧ファイルがそのまま読めること、
//! raw 値が固定であること、配置の解決が主ウィンドウと同じ fail-open で
//! あることを仕様として固定する。

import AppKit
import Foundation
import Testing

@testable import Ladyland

@Suite("面のポップアウト — モデル")
struct PaneWindowModelTests {
    @Test("raw 値は変えない（window.json に入る）")
    func rawValuesArePinned() {
        #expect(PaneID.jack.rawValue == "jack")
        #expect(PaneID.keystage.rawValue == "keystage")
        #expect(PaneID.lpd8.rawValue == "lpd8")
        #expect(PaneID.roto.rawValue == "roto")
        #expect(PaneID.allCases.count == 4)
    }

    @Test("面 → サイドバーの SurfaceTab が 1:1（Track は切り離せない）")
    func mapsToSurface() {
        #expect(PaneID.jack.surface == .jack)
        #expect(PaneID.keystage.surface == .keystage)
        #expect(PaneID.lpd8.surface == .lpd8)
        #expect(PaneID.roto.surface == .roto)
        #expect(PaneID(surface: .track) == nil)
        #expect(PaneID(surface: .jack) == .jack)
    }

    @Test("panes の無い旧 window.json はそのまま読める（panes = nil）")
    func oldFileWithoutPanesDecodes() throws {
        let json = #"{"mode":"windowed","frame":[0,0,1400,800],"screenUUID":"x"}"#
        let prefs = try JSONDecoder().decode(WindowPreferences.self, from: Data(json.utf8))
        #expect(prefs.panes == nil)
        #expect(prefs.mode == .windowed)
    }

    @Test("panes が往復する（キーは raw 値の文字列）")
    func panesRoundTrip() throws {
        var prefs = WindowPreferences.default
        prefs.panes = [
            "jack": PanePlacement(frame: [10, 20, 960, 560], screenUUID: "s", open: true)
        ]
        let data = try JSONEncoder().encode(prefs)
        let back = try JSONDecoder().decode(WindowPreferences.self, from: data)
        #expect(back == prefs)
        #expect(back.panes?["jack"]?.open == true)
    }
}

@Suite("面のポップアウト — 配置の解決")
struct PaneWindowPlacementTests {
    private let builtin = ScreenInfo(
        uuid: "builtin-uuid", isBuiltin: true,
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 930))
    private let external = ScreenInfo(
        uuid: "external-uuid", isBuiltin: false,
        visibleFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1415))

    @Test("保存があり画面も居れば、その枠をそのまま使う")
    func savedFrameOnSavedScreen() {
        let saved = PanePlacement(frame: [1600, 100, 960, 560], screenUUID: external.uuid, open: true)
        let landing = PaneWindowPlacement.resolve(saved, pane: .jack, screens: [builtin, external])
        #expect(landing?.screenUUID == external.uuid)
        #expect(landing?.frame == CGRect(x: 1600, y: 100, width: 960, height: 560))
    }

    @Test("保存画面が消えていたら内蔵へ押し戻す（fail-open）")
    func missingScreenFallsBackToBuiltin() {
        let saved = PanePlacement(frame: [1600, 100, 960, 560], screenUUID: "gone", open: true)
        let landing = PaneWindowPlacement.resolve(saved, pane: .jack, screens: [builtin])
        #expect(landing?.screenUUID == builtin.uuid)
        // 枠は内蔵画面に収まる位置へ（サイズは保つ）
        #expect(landing?.frame.width == 960)
        #expect(landing?.frame.maxX ?? .infinity <= builtin.visibleFrame.maxX)
    }

    @Test("保存が無ければ面の既定サイズで内蔵画面の中央")
    func noSaveUsesDefaultSizeCentered() {
        let landing = PaneWindowPlacement.resolve(nil, pane: .jack, screens: [external, builtin])
        #expect(landing?.screenUUID == builtin.uuid)
        #expect(landing?.frame.size == PaneID.jack.defaultSize)
        #expect(landing?.frame.midX == builtin.visibleFrame.midX)
        #expect(landing?.frame.midY == builtin.visibleFrame.midY)
    }

    @Test("最小サイズを下回る保存値は最小まで戻す")
    func belowMinimumIsRaised() {
        let saved = PanePlacement(frame: [0, 0, 200, 100], screenUUID: builtin.uuid, open: true)
        let landing = PaneWindowPlacement.resolve(saved, pane: .jack, screens: [builtin])
        #expect(landing?.frame.size == PaneID.jack.minimumSize)
    }

    @Test("画面が 1 枚も無ければ nil")
    func noScreensIsNil() {
        #expect(PaneWindowPlacement.resolve(nil, pane: .jack, screens: []) == nil)
    }
}

@Suite("Jack 結線図の姿")
struct JackBoardLayoutTests {
    @Test("幅で姿が決まる — 720 未満はサイドバー版、以上は広い版")
    func layoutByWidth() {
        #expect(JackBoardView.layout(forWidth: 356) == .sidebar)
        #expect(JackBoardView.layout(forWidth: 719) == .sidebar)
        #expect(JackBoardView.layout(forWidth: 720) == .wide)
        #expect(JackBoardView.layout(forWidth: 1400) == .wide)
    }

    @Test("担当ピッカーの見出し — 席番号 + 名前、名前が無ければ番号だけ")
    func trackLabel() {
        #expect(JackBoardView.trackLabel(index: 0, name: "Madrid (Bass)") == "T1  Madrid (Bass)")
        #expect(JackBoardView.trackLabel(index: 11, name: "") == "T12")
    }
}
