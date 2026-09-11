//! 面のポップアウト — サイドバーの面を別ウィンドウへ切り離す
//! （mako 火花 2026-09-12「別ウィンドウに分けたい Pane あるんだよな。
//! 一枚の広い画面で設定したいやつ。機材の繋げる Editor とか」）。
//!
//! 設定ウィンドウ（`SettingsWindowController`）と同じ NSWindow 直接管理
//! （WindowGroup を増やすと @StateObject の AppState を再注入できない）。
//! 中身は**サイドバーと同じ View を差す** — 二重実装しない。広い姿は View 自身が
//! 幅で決める（`JackBoardView.layout(forWidth:)`）。
//!
//! 置き場は window.json（マシン固有 — ラックと一緒に持ち出さない）。閉じる =
//! 面をサイドバーへ返す。終了時に開いていた面は次回起動で同じ場所に開き直す。

import AppKit
import CreoUI
import SwiftUI

@MainActor
final class PaneWindowController: ObservableObject {
    /// 開いている面（View がこれを見て「別ウィンドウで表示中」に切り替わる）
    @Published private(set) var openPanes: Set<PaneID> = []

    private var windows: [PaneID: NSWindow] = [:]
    private var observers: [PaneID: [NSObjectProtocol]] = [:]

    /// いずれかの面のウィンドウが key か（キーモニタのガード判定。
    /// 設定ウィンドウと同じ扱い — 数字キーや矢印を飲まない）
    var isAnyKeyWindow: Bool { windows.values.contains { $0.isKeyWindow } }

    func isOpen(_ pane: PaneID) -> Bool { openPanes.contains(pane) }

    /// 面を別ウィンドウで開く（既に開いていれば前面へ）
    func open(_ pane: PaneID, appState: AppState) {
        if let window = windows[pane] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: ThemedRoot {
                PaneContent(pane: pane).environmentObject(appState)
            })
        let window = NSWindow(contentViewController: host)
        window.title = pane.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = pane.minimumSize

        let placement = appState.windowPlacement
        if let landing = PaneWindowPlacement.resolve(
            placement.panePlacement(pane), pane: pane,
            screens: WindowPlacementController.currentScreens())
        {
            window.setFrame(landing.frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        windows[pane] = window
        openPanes.insert(pane)
        placement.capturePane(pane, window: window, open: true)
        observe(pane, window: window, placement: placement)
    }

    /// 面をサイドバーへ返す
    func close(_ pane: PaneID) {
        windows[pane]?.close()
    }

    /// 前回終了時に開いていた面を開き直す（主ウィンドウの配置が済んだ後に呼ぶ）
    func restoreAtLaunch(appState: AppState) {
        for pane in PaneID.allCases where appState.windowPlacement.panePlacement(pane)?.open == true {
            open(pane, appState: appState)
        }
    }

    private func observe(_ pane: PaneID, window: NSWindow, placement: WindowPlacementController) {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            tokens.append(
                center.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        placement.capturePane(pane, window: window, open: true)
                    }
                })
        }
        tokens.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    placement.capturePane(pane, window: window, open: false)
                    self.observers[pane]?.forEach(center.removeObserver)
                    self.observers[pane] = nil
                    self.windows[pane] = nil
                    self.openPanes.remove(pane)
                }
            })
        observers[pane] = tokens
    }
}

/// 切り離した面の中身 — サイドバーの `case` と同じ View
private struct PaneContent: View {
    let pane: PaneID
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SurfaceContent(pane: pane)
            .padding(CreoUITokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
