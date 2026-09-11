//! 設定ウィンドウの管理（design/06 §8）。
//!
//! 演奏・楽器エディットを隠さない非モーダル補助ウィンドウ — 開いて確認して
//! 閉じる。PluginEditorWindows と同じ NSWindow 直接管理パターン
//! （WindowGroup を増やすと @StateObject の AppState を再注入できないため）。

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    /// 設定ウィンドウが key かどうか（キーモニタのガード判定に使う）
    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    /// 設定ウィンドウを開く（既に開いていれば前面へ）
    func open(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: ThemedRoot { SettingsView().environmentObject(appState) }
        )
        let window = NSWindow(contentViewController: host)
        window.title = "ladyland 設定"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // 閉じられたら管理から外す（次回は作り直す）
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.window = nil
            }
        }
    }
}
