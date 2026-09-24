//! focus pane（画面中央の常設プラグイン view）のテスト。
//!
//! VC は 1 ユニットにつき一度しか取れないため、focus pane はウィンドウ機構
//! から view を借りる（custody）。ここでは表示状態の決定と、view を領域に
//! 収める fit 計算（純関数）をピン留めする。

import AppKit
import CoreAudioKit
import SwiftUI
import Testing

@testable import Ladyland

@Suite("focus pane 表示状態")
struct FocusPaneModeTests {
    @Test("空トラックは empty — 他の条件より優先")
    func emptyWins() {
        #expect(
            FocusPaneMode.decide(hasUnit: false, hasView: false, editorOnScreen: false)
                == .empty)
        #expect(
            FocusPaneMode.decide(hasUnit: false, hasView: false, editorOnScreen: true)
                == .empty)
    }

    @Test("view を借りられたら hosting（ウィンドウ表示より優先されない前提 — 借用時点で排他）")
    func hostingWhenViewHeld() {
        #expect(
            FocusPaneMode.decide(hasUnit: true, hasView: true, editorOnScreen: false)
                == .hosting)
    }

    @Test("view が無くウィンドウ表示中は editingInWindow、どちらも無ければ waiting")
    func placeholderStates() {
        #expect(
            FocusPaneMode.decide(hasUnit: true, hasView: false, editorOnScreen: true)
                == .editingInWindow)
        #expect(
            FocusPaneMode.decide(hasUnit: true, hasView: false, editorOnScreen: false)
                == .waiting)
    }
}

@Suite("focus pane fit 計算")
struct FocusPaneFitTests {
    @Test("領域が余れば拡大してフィットする（中央寄せ・比率維持）")
    func upscalesToFill() {
        let fit = FocusPaneFit.fit(
            native: .init(width: 400, height: 300), in: .init(width: 800, height: 600))
        #expect(fit.scale == 2)
        #expect(fit.frame == .init(x: 0, y: 0, width: 800, height: 600))
    }

    @Test("拡大は 2 倍で頭打ち（AU の view はビットマップ主体でぼやけるため）")
    func upscaleIsCapped() {
        let fit = FocusPaneFit.fit(
            native: .init(width: 100, height: 100), in: .init(width: 1000, height: 1000))
        #expect(fit.scale == FocusPaneFit.maxScale)
        #expect(fit.frame == .init(x: 400, y: 400, width: 200, height: 200))
    }

    @Test("はみ出すなら比率維持で縮小し、短辺方向を中央寄せ")
    func downscaleKeepsAspect() {
        let fit = FocusPaneFit.fit(
            native: .init(width: 1000, height: 500), in: .init(width: 500, height: 500))
        #expect(fit.scale == 0.5)
        #expect(fit.frame == .init(x: 0, y: 125, width: 500, height: 250))
    }

    @Test("高さ制約が効くケース — 幅でなく高さの比で縮む")
    func heightConstrained() {
        let fit = FocusPaneFit.fit(
            native: .init(width: 800, height: 600), in: .init(width: 1200, height: 300))
        #expect(fit.scale == 0.5)
        #expect(fit.frame == .init(x: 400, y: 0, width: 400, height: 300))
    }

    @Test("ゼロサイズは安全に zero を返す（起動直後の未レイアウト）")
    func zeroSizes() {
        #expect(FocusPaneFit.fit(native: .zero, in: .init(width: 100, height: 100)).frame == .zero)
        #expect(
            FocusPaneFit.fit(native: .init(width: 100, height: 100), in: .zero).frame == .zero)
    }
}

// mem_1CfGrPJYSvy8xFk3eZf4Ra: responsive AU views must receive the fitted size.
private final class ResizingTestUnit: AUAudioUnit {
    var acceptsResize = true
    var selections: [CGSize] = []
    override func supportedViewConfigurations(_ configurations: [AUAudioUnitViewConfiguration]) -> IndexSet {
        acceptsResize ? IndexSet(integersIn: configurations.indices) : []
    }
    override func select(_ configuration: AUAudioUnitViewConfiguration) {
        selections.append(CGSize(width: configuration.width, height: configuration.height))
    }
}

@Suite("focus pane AU view sizing")
@MainActor
struct FocusPaneContainerTests {
    private func unit() throws -> ResizingTestUnit {
        try ResizingTestUnit(componentDescription: AudioComponentDescription(
            componentType: 0x61756d75, componentSubType: 0x74657374,
            componentManufacturer: 0x74657374, componentFlags: 0, componentFlagsMask: 0))
    }

    @Test("対応AUはframeをリサイズし、親の座標拡縮を重ねない")
    func responsiveView() throws {
        let au = try unit()
        let container = FocusPaneContainerView(frame: CGRect(x: 0, y: 0, width: 664, height: 500))
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 1328, height: 747))
        container.host(view, audioUnit: au)
        container.layout()
        #expect(view.frame.size == CGSize(width: 664, height: 373.5))
        #expect(view.superview?.bounds.size == view.superview?.frame.size)
        #expect(au.selections == [CGSize(width: 664, height: 373.5)])
        container.layout()
        #expect(au.selections.count == 1)
        container.setFrameSize(CGSize(width: 332, height: 500))
        container.layout()
        #expect(view.frame.size == CGSize(width: 332, height: 186.75))
        #expect(au.selections.count == 2)
    }

    @Test("別窓が回収したビューを古いペインのlayoutや解除が変更しない")
    func reclaimedView() throws {
        let au = try unit()
        let container = FocusPaneContainerView(frame: CGRect(x: 0, y: 0, width: 450, height: 300))
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        container.host(view, audioUnit: au)
        container.layout()
        let editor = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        editor.addSubview(view)
        view.frame = editor.bounds
        container.layout()
        #expect(view.frame == editor.bounds)
        container.host(nil)
        #expect(view.superview === editor)
    }

    @Test("非対応AUは元のサイズと従来の比例縮小を維持する")
    func fixedView() throws {
        let au = try unit()
        au.acceptsResize = false
        let container = FocusPaneContainerView(frame: CGRect(x: 0, y: 0, width: 450, height: 300))
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        container.host(view, audioUnit: au)
        container.layout()
        #expect(view.frame.size == CGSize(width: 900, height: 600))
        #expect(view.superview?.frame.size == CGSize(width: 450, height: 300))
        #expect(au.selections.isEmpty)
    }
}

/// 実測 2026-09-23（スタジオ練習）: Lady MPE のトラックへ切り替えると
/// `NSGenericException`（Update Constraints in Window のパスが尽きない）で落ちた。
/// Lady MPE の画面は NSHostingController で、既定の sizingOptions だと SwiftUI が
/// 最小・最大サイズを**制約**として張る。focus pane は frame / bounds で縮小表示する
/// ので両者がぶつかり、窓のレイアウトが収束しない。
/// 実物の部品（ラック・プラグイン窓・focus pane）で切り替えを通す — 落ちれば赤
@Suite("focus pane 実物の切り替え", .serialized)
@MainActor
struct FocusPaneSwitchTests {
    @MainActor
    private final class Pane: ObservableObject {
        @Published var view: NSView?
        @Published var unit: AUAudioUnit?
    }

    private struct Root: View {
        @ObservedObject var pane: Pane
        var body: some View {
            FocusPaneHost(hosted: pane.view, audioUnit: pane.unit).padding(4)
        }
    }

    @Test("自作楽器の画面を載せ替えてもレイアウトが収束する", arguments: [
        LadySynth.displayName, LadySampler.displayName,
    ])
    func switchToBuiltInEditor(name: String) async throws {
        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        rack.engine.mainMixerNode.outputVolume = 0
        let component = try #require(rack.catalog.first { $0.name == name })
        try await rack.load(component, into: rack.slots[0])
        let slot = rack.slots[0]

        let editors = PluginEditorWindows()
        var ready = false
        editors.onViewReady = { _ in ready = true }
        _ = editors.borrowFocusPaneView(for: slot)  // 1 回目は取得を蹴るだけ
        for _ in 0..<100 where !ready { try await Task.sleep(for: .milliseconds(20)) }
        try #require(ready, "\(name) の画面が届かない")

        let pane = Pane()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Root(pane: pane))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<3 {
            pane.view = try #require(editors.borrowFocusPaneView(for: slot))
            pane.unit = slot.audioUnit?.auAudioUnit
            try await Task.sleep(for: .milliseconds(150))
            pane.view = nil
            editors.reclaimFocusPaneView(slot.index)
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
