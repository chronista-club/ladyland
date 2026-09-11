//! AU プラグイン画面のウィンドウ管理（design/06 §2・§4・§8 追補）。
//!
//! 「音色は ladyland 内で作る」の実体。スロットのエディタボタンから
//! `auAudioUnit.requestViewController` でプラグイン自身の画面を取り出し、
//! 独立した NSWindow で表示する（複数楽器の画面を同時に開ける）。
//!
//! **VC は 1 ユニットにつき一度しか取れない**（2026-07-31 実機 + 統合テストで
//! 確定: KORG AU は 2 回目の requestViewController に nil を返す）。そのため:
//!   - VC の所有者はこのクラスだけ（サムネ撮影も同じ経路）
//!   - ウィンドウは**閉じない** — ユーザーの close は隠すだけ（orderOut）、
//!     サムネ撮影用は画面外で「駐機」。開く = 前面へ昇格
//!   - 本当に閉じるのはスロット差し替え時（close(for:)）だけ。その後の
//!     開き直しは新しいユニットの初回要求なので問題ない

import AppKit
import AVFoundation
import CoreAudioKit

@MainActor
final class PluginEditorWindows: NSObject, NSWindowDelegate {
    /// スロット index → ウィンドウ（可視・隠し・画面外駐機を含む）
    private var windows: [Int: NSWindow] = [:]
    /// 画面外（-20000, -20000）で駐機中 — 昇格時に center() が必要な index
    private var parkedOffscreen: Set<Int> = []
    /// requestViewController の応答待ち index（二重要求の防止）
    private var requesting: Set<Int> = []
    /// 応答待ちの間にユーザーが開こうとした index（届いたら前面で開く）
    private var promoteWhenReady: Set<Int> = []
    /// willClose 時の撮り納めに使う desc（ウィンドウ生成時に確定）
    private var descriptions: [Int: AudioComponentDescription] = [:]

    /// スロット index → VC の強参照台帳。**VC は 1 ユニットにつき一度しか
    /// 取れない**ため、focus pane 貸出で window.contentViewController が
    /// 切れても VC が解放されないようここが正で保持する
    private var controllers: [Int: NSViewController] = [:]

    /// focus pane へ view を貸出中の index（custody は常にどちらか一方）
    private var lentToFocus: Set<Int> = []

    /// VC が届いたときの通知（focus pane が借り直すきっかけ）
    var onViewReady: ((Int) -> Void)?

    /// サムネ撮影先（AppState が注入。design/06 §8 追補）
    var thumbnails: PluginThumbnailStore?

    /// プラグイン画面を閉じた（隠した）ときに呼ばれる — 音色エディットの節目。
    /// プラグイン UI 内の操作はホストに通知が来ないため、常時保存はこの節目
    /// （+ 30 秒の定期保険）で fullState の変化を拾う
    var onEditorHidden: (() -> Void)?

    /// focus pane 用に view を借りる（custody 移動）。nil = まだ借りられない:
    /// VC 未取得（駐機取得を蹴っておく — 届いたら onViewReady）/
    /// ユーザーがウィンドウで編集中（そちらが優先）
    func borrowFocusPaneView(for slot: InstrumentSlot) -> NSView? {
        let index = slot.index
        if lentToFocus.contains(index) { return controllers[index]?.view }
        if isOpenOnScreen(index) { return nil }
        guard let vc = controllers[index], let window = windows[index] else {
            if slot.audioUnit != nil, !requesting.contains(index) {
                acquireWindow(for: slot, visible: false)
            }
            return nil
        }
        window.orderOut(nil)
        // contentView の差し替えで vc.view をウィンドウから外す
        // （contentViewController は nil になるが VC は controllers が保持）
        window.contentView = NSView()
        lentToFocus.insert(index)
        return vc.view
    }

    /// focus pane から view を返してもらいウィンドウへ戻す（隠れたまま）
    func reclaimFocusPaneView(_ index: Int) {
        guard lentToFocus.remove(index) != nil,
              let vc = controllers[index], let window = windows[index]
        else { return }
        vc.view.removeFromSuperview()
        window.contentViewController = vc
    }

    /// スロットのプラグイン画面を開く（既存ウィンドウがあれば昇格/再表示）
    func open(for slot: InstrumentSlot) {
        let index = slot.index
        // focus pane に貸出中なら先にウィンドウへ返す（custody は一方通行）
        if lentToFocus.contains(index) { reclaimFocusPaneView(index) }
        if let window = windows[index] {
            if parkedOffscreen.remove(index) != nil {
                window.center()  // 駐機位置から画面内へ
            }
            window.makeKeyAndOrderFront(nil)
            scheduleCapture(of: window, desc: descriptions[index], after: 0.3)
            return
        }
        if requesting.contains(index) {
            promoteWhenReady.insert(index)  // 届いたら前面で開く（二重要求しない）
            return
        }
        acquireWindow(for: slot, visible: true)
    }

    /// 差し替え直後のサムネ自動撮影。既存ウィンドウがあればそこから撮り、
    /// 無ければ画面外で駐機ウィンドウを作って撮る（作ったら閉じずに残す —
    /// 次にユーザーが開いたとき即昇格できる）
    func refreshThumbnail(for slot: InstrumentSlot) {
        let index = slot.index
        if let window = windows[index] {
            scheduleCapture(of: window, desc: descriptions[index], after: 0.5)
            return
        }
        guard !requesting.contains(index) else { return }
        acquireWindow(for: slot, visible: false)
    }

    /// 画面上に見えるエディタが開いているか（テスト・診断用）
    func isOpenOnScreen(_ index: Int) -> Bool {
        guard let window = windows[index] else { return false }
        return window.isVisible && !parkedOffscreen.contains(index)
    }

    /// タイル並び替えに合わせてウィンドウの担当スロットを入れ替える
    /// （design/06 §8 追補。InstrumentRack.swapSlots と対で呼ぶ）。
    ///
    /// 既知の許容エッジ: VC 応答待ち（requestViewController 飛行中）に
    /// スワップすると、届いた VC が旧 index に紐づく — ロード直後 ~1 秒の
    /// 窓でのみ起きうるレア事象で、閉じて開き直せば回復する
    func swap(_ a: Int, _ b: Int) {
        guard a != b else { return }
        swapValues(&windows, a, b)
        swapValues(&descriptions, a, b)
        swapValues(&controllers, a, b)
        swapMembership(&parkedOffscreen, a, b)
        swapMembership(&requesting, a, b)
        swapMembership(&promoteWhenReady, a, b)
        swapMembership(&lentToFocus, a, b)
    }

    private func swapValues<V>(_ dict: inout [Int: V], _ a: Int, _ b: Int) {
        let valueA = dict[a]
        dict[a] = dict[b]  // nil なら a キーは消える（辞書 subscript の仕様どおり）
        dict[b] = valueA
    }

    private func swapMembership(_ set: inout Set<Int>, _ a: Int, _ b: Int) {
        let hasA = set.contains(a)
        let hasB = set.contains(b)
        guard hasA != hasB else { return }
        if hasA {
            set.remove(a)
            set.insert(b)
        } else {
            set.remove(b)
            set.insert(a)
        }
    }

    /// スロットの差し替え時だけ本当に閉じる（新ユニットの初回要求は成功する）
    func close(for index: Int) {
        lentToFocus.remove(index)
        controllers.removeValue(forKey: index)
        guard let window = windows[index] else { return }
        window.delegate = nil
        window.close()
        windows.removeValue(forKey: index)
        parkedOffscreen.remove(index)
        descriptions.removeValue(forKey: index)
    }

    // MARK: - NSWindowDelegate

    /// ユーザーの close は隠すだけ（VC は二度と取れないため手放さない）。
    /// 隠す直前が一番「触った後の顔」なのでサムネを撮り納める
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let index = windows.first(where: { $0.value === sender })?.key {
            if let desc = descriptions[index], let view = sender.contentViewController?.view {
                thumbnails?.capture(view: view, for: desc)
            }
        }
        sender.orderOut(nil)
        onEditorHidden?()
        return false
    }

    // MARK: - 内部

    /// VC を要求してウィンドウを作る唯一の経路
    private func acquireWindow(for slot: InstrumentSlot, visible: Bool) {
        guard let auAudioUnit = slot.audioUnit?.auAudioUnit else { return }
        let desc = slot.audioUnit?.audioComponentDescription
        let title = slot.displayName ?? "plugin"
        let index = slot.index
        requesting.insert(index)

        auAudioUnit.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                guard let self else { return }
                self.requesting.remove(index)
                let promoted = self.promoteWhenReady.remove(index) != nil
                let wantsVisible = visible || promoted

                guard let viewController else {
                    if wantsVisible {
                        NSLog("editor: %@ は画面を提供しない", title)
                    }
                    return
                }
                let window = NSWindow(contentViewController: viewController)
                window.title = title
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                window.delegate = self
                if wantsVisible {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // 画面外で駐機: 描画は走るが画面には現れない
                    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                    window.orderBack(nil)
                    self.parkedOffscreen.insert(index)
                }
                self.windows[index] = window
                self.controllers[index] = viewController
                if let desc {
                    self.descriptions[index] = desc
                }
                self.onViewReady?(index)

                // 描画が落ち着いた頃にサムネを撮る（単色 = Metal 系は store 側で破棄）
                self.scheduleCapture(of: window, desc: desc, after: wantsVisible ? 0.8 : 1.2)

                // 駐機撮影の場合: 撮影が済んだら orderOut で休眠（描画コストを止める。
                // ウィンドウと VC は保持したまま — 昇格に備える）
                if !wantsVisible {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.parkedOffscreen.contains(index),
                              self.windows[index] === window else { return }
                        window.orderOut(nil)
                    }
                }
            }
        }
    }

    private func scheduleCapture(
        of window: NSWindow, desc: AudioComponentDescription?, after delay: TimeInterval
    ) {
        guard let desc else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let view = window.contentViewController?.view else { return }
            self?.thumbnails?.capture(view: view, for: desc)
        }
    }
}
