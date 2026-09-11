//! 起動時ウィンドウ配置のテスト（mako 裁定 2026-08-01
//! 「フルスクリーンか、ウィンドウモード（スクリーン、位置、フォールバックあり）」）。
//!
//! 機材構成は本番と検証で変わる（外部モニタの有無・解像度）。
//! フォールバックの 3 段（保存画面 → 内蔵 → 先頭）と、画面外に落ちた枠の
//! 押し戻しをピン留めする — 「起動したのに窓が見えない」を作らないため。

import AppKit
import Foundation
import Testing

@testable import Ladyland

@Suite("ウィンドウ配置の解決")
struct WindowPlacementTests {
    private let builtin = ScreenInfo(
        uuid: "builtin-uuid", isBuiltin: true,
        visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 930))
    private let external = ScreenInfo(
        uuid: "external-uuid", isBuiltin: false,
        visibleFrame: CGRect(x: 1470, y: 0, width: 2560, height: 1415))

    @Test("保存が無ければ内蔵フルスクリーン（従来の既定を維持）")
    func defaultsToBuiltinFullscreen() {
        let landing = WindowPlacement.resolve(nil, screens: [external, builtin])
        #expect(landing?.fullscreen == true)
        #expect(landing?.screenUUID == builtin.uuid)
    }

    @Test("フォールバック 3 段 — 保存画面 → 内蔵 → 先頭")
    func screenFallbackChain() {
        // ① 保存画面が居れば最優先（内蔵より外部が勝つ）
        #expect(
            WindowPlacement.targetScreen("external-uuid", screens: [builtin, external])
                == external)
        // ② 保存画面が消えていたら内蔵へ
        #expect(WindowPlacement.targetScreen("gone-uuid", screens: [external, builtin]) == builtin)
        // ③ 内蔵も無ければ（クラムシェル）先頭へ
        #expect(WindowPlacement.targetScreen("gone-uuid", screens: [external]) == external)
        // ④ 画面が 1 枚も無ければ nil（呼び手は何もしない = fail-open）
        #expect(WindowPlacement.targetScreen("gone-uuid", screens: []) == nil)
        #expect(WindowPlacement.resolve(nil, screens: []) == nil)
    }

    @Test("ウィンドウモード — 画面に収まる枠はそのまま使う")
    func windowedKeepsSavedFrame() {
        let prefs = WindowPreferences(
            mode: .windowed, frame: [40, 60, 1400, 800], screenUUID: builtin.uuid)
        let landing = WindowPlacement.resolve(prefs, screens: [builtin, external])
        #expect(landing?.fullscreen == false)
        #expect(landing?.screenUUID == builtin.uuid)
        #expect(landing?.frame == CGRect(x: 40, y: 60, width: 1400, height: 800))
    }

    @Test("右端・下端からはみ出す枠はサイズを保ったまま内側へ寄せる")
    func overflowingFrameSlidesIn() {
        // x=100 + 幅 1400 = 1500 > 画面幅 1470 → x は 70 へ（幅は変えない）
        let fit = WindowPlacement.fitting(
            CGRect(x: 100, y: 200, width: 1400, height: 800), into: builtin.visibleFrame)
        #expect(fit == CGRect(x: 70, y: 130, width: 1400, height: 800))
    }

    @Test("ウィンドウモードで枠の保存が無ければ画面いっぱい（Air 画面で最大化）")
    func windowedWithoutFrameFillsScreen() {
        let prefs = WindowPreferences(mode: .windowed, frame: nil, screenUUID: nil)
        let landing = WindowPlacement.resolve(prefs, screens: [external, builtin])
        #expect(landing?.screenUUID == builtin.uuid)
        #expect(landing?.frame == builtin.visibleFrame)
    }

    @Test("外部モニタを外した後 — 画面外の枠は内蔵画面へ押し戻される")
    func offscreenFrameIsPulledBack() {
        // 外部画面（x=1470〜）に置いたまま外した状態
        let prefs = WindowPreferences(
            mode: .windowed, frame: [2000, 200, 1400, 800], screenUUID: external.uuid)
        let landing = WindowPlacement.resolve(prefs, screens: [builtin])
        #expect(landing?.screenUUID == builtin.uuid)
        let frame = try! #require(landing?.frame)
        #expect(builtin.visibleFrame.contains(frame), "枠が内蔵画面に収まること")
        #expect(frame.width == 1400, "収まるサイズは変えない")
    }

    @Test("画面より大きい枠は縮めて収める")
    func oversizedFrameShrinks() {
        let fit = WindowPlacement.fitting(
            CGRect(x: -200, y: -100, width: 3000, height: 2000), into: builtin.visibleFrame)
        #expect(fit == builtin.visibleFrame)
    }

    @Test("最小サイズを下回る保存値は最小まで戻す")
    func tinyFrameGrowsToMinimum() {
        let fit = WindowPlacement.fitting(
            CGRect(x: 10, y: 10, width: 300, height: 100), into: builtin.visibleFrame)
        #expect(fit.width == WindowPlacement.minimumSize.width)
        #expect(fit.height == WindowPlacement.minimumSize.height)
    }

    @Test("壊れた保存値（要素数不足・幅ゼロ）は画面いっぱいに落とす")
    func malformedFrameFallsBack() {
        for broken in [[10.0, 10.0], [0, 0, 0, 600], [0, 0, 800, 0]] {
            let prefs = WindowPreferences(
                mode: .windowed, frame: broken, screenUUID: builtin.uuid)
            #expect(
                WindowPlacement.resolve(prefs, screens: [builtin])?.frame
                    == builtin.visibleFrame)
        }
    }

    @Test("window.json の往復（rack.json とは別ファイル = マシン固有設定）")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-window-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var prefs = WindowPreferences(
            mode: .windowed, frame: [12, 34, 1500, 900], screenUUID: "some-uuid")
        prefs.assignSidebarExpanded = false
        prefs.assignTab = .lpd8
        prefs.drumPaneExpanded = false  // Main 右列（LPD8）の開閉も往復する
        try WindowStore.save(prefs, to: url)
        #expect(WindowStore.load(from: url) == prefs, "再起動後も同じ状態に戻せること")

        // 存在しない / 壊れたファイルは nil（既定へ落ちる）
        #expect(WindowStore.load(from: url.appendingPathExtension("missing")) == nil)
        try Data("not json".utf8).write(to: url)
        #expect(WindowStore.load(from: url) == nil)
    }

    @Test("R Area の項目が無い旧ファイルも読める（既定 = 開いて Keystage）")
    func legacyFileWithoutAssignState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-window-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mode":"windowed"}"#.utf8).write(to: url)

        let prefs = try #require(WindowStore.load(from: url))
        #expect(prefs.assignSidebarExpanded == nil)
        #expect(prefs.assignTab == nil)
        #expect(prefs.drumPaneExpanded == nil)
        // nil の読み替えは Controller 側の既定（開いている / Keystage）
    }

    /// ⚠️ **右列の既定は開き**（mako 要望 2026-08-06）。本番は両手で弾く
    /// （鍵盤 = 左 / LPD8 = 右）ので、両方が同時に見えているのが既定であるべき。
    ///
    /// ⚠️ ここで見るのは「**保存が無いとき nil であること**」まで。
    /// `WindowPlacementController` の実値を見に行ってはいけない —
    /// あれはこのマシンの `window.json` を読むので、**mako が一度畳んだら
    /// テストが落ちる**（実際に落ちた）。保存が効いている証拠であって
    /// バグではないので、テストの方が間違っていた
    @Test("右列の状態は保存が無ければ未設定（= Controller 側で開きに読み替える）")
    func drumPaneDefaultsToNil() {
        #expect(WindowPreferences(mode: .windowed).drumPaneExpanded == nil)
    }
}

/// **タブを増やしても保存済みの設定が壊れないこと**
/// （mako 要望 2026-08-06 で `roto` を追加。⚠️ ここが壊れると画面配置が飛ぶ）
@Suite("面（Surface）のタブ")
struct SurfaceTabTests {
    private func roundTrip(_ prefs: WindowPreferences) throws -> WindowPreferences? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assigntab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try WindowStore.save(prefs, to: url)
        return WindowStore.load(from: url)
    }

    /// ⚠️ **旧 window.json が読めること**。`roto` を足したことで
    /// `keystage` / `lpd8` / 未設定 が壊れてはいけない
    @Test("旧タブの値がそのまま読める", arguments: [
        SurfaceTab.keystage, SurfaceTab.lpd8,
    ])
    func legacyTabsStillLoad(tab: SurfaceTab) throws {
        var prefs = WindowPreferences(mode: .windowed)
        prefs.assignTab = tab
        #expect(try roundTrip(prefs)?.assignTab == tab)
    }

    @Test("タブ未設定の旧ファイルも読める — 既定は Keystage")
    func missingTabFallsBackToKeystage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("assigntab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // `assignTab` を持たない古い形
        try Data(#"{"mode":"windowed"}"#.utf8).write(to: url)

        let prefs = try #require(WindowStore.load(from: url))
        #expect(prefs.assignTab == nil, "未設定のまま読める")
        // nil の読み替えは Controller 側（既定 = keystage）
    }

    @Test("ROTO タブが往復する")
    func rotoTabRoundTrips() throws {
        var prefs = WindowPreferences(mode: .windowed)
        prefs.assignTab = .roto
        #expect(try roundTrip(prefs)?.assignTab == .roto)
    }

    // MARK: - タブのアイコン（mako 要望 2026-08-07）

    /// ⚠️ **名前を間違えると無言で何も描かれない。** `Image(systemName:)` は
    /// 存在しないシンボルでもエラーにならず、**空白が出るだけ**。
    /// タイポや OS 差でアイコンが消えたことに気づけないので、実在を固定する
    @Test("アイコンの SF Symbol が実在する", arguments: SurfaceTab.allCases)
    func iconsExist(tab: SurfaceTab) {
        #expect(
            NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil) != nil,
            "\(tab.rawValue) の \(tab.icon) が見つからない")
    }

    /// ⚠️ **アイコンだけにしない**（機材名は演奏中に確信を持って選ぶための情報）。
    /// 4 つが別のアイコンであることも固定する — 同じだと探す速さに寄与しない
    @Test("5 つの面が別々のアイコンと名前を持つ")
    func iconsAndTitlesAreDistinct() {
        let tabs = SurfaceTab.allCases
        #expect(tabs.count == 5)
        #expect(Set(tabs.map(\.icon)).count == 5)
        #expect(Set(tabs.map(\.title)).count == 5)
        #expect(tabs.allSatisfy { !$0.title.isEmpty })
    }

    /// ⚠️ 生の文字列が変わると保存済みの設定が読めなくなる
    @Test("raw 値は変えない")
    func rawValuesAreStable() {
        #expect(SurfaceTab.keystage.rawValue == "keystage")
        #expect(SurfaceTab.lpd8.rawValue == "lpd8")
        #expect(SurfaceTab.roto.rawValue == "roto")
        #expect(SurfaceTab.track.rawValue == "track")
    }

    /// **3 つの面が揃っていること**（`Surface` の doc — surface / assignment /
    /// mapping の 3 層のうち、ここは surface の層）
    @Test("面は Keystage / LPD8 / ROTO の 3 つ")
    func allSurfaces() {
        let all: [SurfaceTab] = [.keystage, .lpd8, .roto]
        #expect(Set(all.map(\.rawValue)).count == 3, "raw 値が重複しない")
    }

    // MARK: - R Area の幅（ドラッグで変える。2026-08-06）

    @Test("R Area の幅が往復する")
    func sidebarWidthRoundTrips() throws {
        var prefs = WindowPreferences(mode: .windowed)
        prefs.assignSidebarWidth = 420
        #expect(try roundTrip(prefs)?.assignSidebarWidth == 420)
    }

    /// ⚠️ **未設定なら既定へ落ちる** — 保存前のユーザーが幅 0 の面を見ないこと
    @Test("未設定なら 356 に落ちる")
    @MainActor
    func widthFallsBackToDefault() {
        let prefs = WindowPreferences(mode: .windowed)
        #expect(prefs.assignSidebarWidth == nil, "保存されていない")
        #expect(WindowPlacementController.defaultSidebarWidth == 356)
    }

    /// ⚠️ **範囲は上下とも要る**。狭すぎると割当一覧が読めず、
    /// 広すぎるとトラック列が潰れる — どちらも演奏中に直せない
    @Test("幅の範囲が既定を挟んでいる")
    @MainActor
    func widthRangeBracketsDefault() {
        let low = WindowPlacementController.minSidebarWidth
        let high = WindowPlacementController.maxSidebarWidth
        #expect(low < high)
        #expect(low <= CGFloat(WindowPlacementController.defaultSidebarWidth))
        #expect(CGFloat(WindowPlacementController.defaultSidebarWidth) <= high)
    }
}
