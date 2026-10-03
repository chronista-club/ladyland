//! 8ch ミキサー面（mako 火花 2026-10-01「8ch の Mixer component 欲しいな」
//! 「いわゆる DAW のミキサー的な感じで」）。
//!
//! 守りたい不変条件:
//!   - 面は 8 本 = **選択中のバンク**（LPD8 PROG4 の Track 選択と同じ切り方）
//!   - フェーダーのドラッグは**下が 0・上が 1**、枠外は端に張り付く
//!   - タブ / 面の raw 値は window.json に入るので固定

import AppKit
import Testing

@testable import Ladyland

@Suite("8ch ミキサー — モデル")
struct MixerViewTests {
    @Test("バンク = 選択中の席を含む 8 本（T1-8 / T9-16 …）")
    func bankIndices() {
        #expect(MixerModel.bankIndices(selected: 0, trackCount: 16) == Array(0..<8))
        #expect(MixerModel.bankIndices(selected: 7, trackCount: 16) == Array(0..<8))
        #expect(MixerModel.bankIndices(selected: 8, trackCount: 16) == Array(8..<16))
        #expect(MixerModel.bankIndices(selected: 9, trackCount: 12) == Array(8..<12), "端数のバンクは在る分だけ")
    }

    @Test("フェーダーのドラッグ位置 → gain（下 0 / 上 1、枠外は端）")
    func gainFromDrag() {
        #expect(MixerModel.gain(atY: 100, height: 100) == 0)
        #expect(MixerModel.gain(atY: 0, height: 100) == 1)
        #expect(MixerModel.gain(atY: 25, height: 100) == 0.75)
        #expect(MixerModel.gain(atY: -10, height: 100) == 1, "上にはみ出しても 1 止まり")
        #expect(MixerModel.gain(atY: 130, height: 100) == 0, "下にはみ出しても 0 止まり")
        #expect(MixerModel.gain(atY: 10, height: 0) == 0, "高さ 0 でも落ちない")
    }

    @Test("ストリップの見出し — トラック名 > プラグイン名 > T 番号")
    func stripTitle() {
        #expect(MixerModel.title(index: 0, trackName: nil) == "T1")
        #expect(MixerModel.title(index: 8, trackName: "Bass") == "Bass")
    }

    @Test("面として足す — raw 値 mixer、アイコン実在、切り離せる")
    func surfaceAndPane() {
        #expect(SurfaceTab.mixer.rawValue == "mixer")
        #expect(PaneID.mixer.rawValue == "mixer")
        #expect(PaneID(surface: .mixer) == .mixer)
        #expect(PaneID.mixer.surface == .mixer)
        #expect(NSImage(systemSymbolName: SurfaceTab.mixer.icon, accessibilityDescription: nil) != nil)
    }
}
