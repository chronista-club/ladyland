//! focus pane（画面中央の常設プラグイン view）のテスト。
//!
//! VC は 1 ユニットにつき一度しか取れないため、focus pane はウィンドウ機構
//! から view を借りる（custody）。ここでは表示状態の決定と、view を領域に
//! 収める fit 計算（純関数）をピン留めする。

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
