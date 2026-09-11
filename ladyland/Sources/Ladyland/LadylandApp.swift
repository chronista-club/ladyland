//! ladyland — 8〜12 の自分の楽器を住まわせ、持ち替えながら完全即興を演奏する
//! macOS アプリ（design/06）。
//!
//! SPM executable から SwiftUI アプリを起動する。@main の App だけだと
//! `swift run` 時に前面に来ない（activation policy が .prohibited 相当）ため、
//! AppDelegate で .regular へ昇格して activate する。

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // ウィンドウ配置（フルスクリーン / ウィンドウ + 画面 + 位置）は
        // AppState が持つ WindowPlacementController の仕事（start() で適用）
    }

    // ライブ用途: ウィンドウを閉じたら終了（バックグラウンド残留させない）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LadylandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("ladyland") {
            ThemedRoot {
                ContentView()
                    .environmentObject(appState)
            }
        }
    }
}
