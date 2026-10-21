//! ladyland — 8〜12 の自分の楽器を住まわせ、持ち替えながら完全即興を演奏する
//! macOS アプリ（design/06）。
//!
//! SPM executable から SwiftUI アプリを起動する。@main の App だけだと
//! `swift run` 時に前面に来ない（activation policy が .prohibited 相当）ため、
//! AppDelegate で .regular へ昇格して activate する。

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var prepareForTermination: (() async -> Void)?
    var replyToTermination: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    private var terminationTask: Task<Void, Never>?
    private var readyToTerminate = false

    /// QUICを明示的に閉じてから終了する。次の起動を旧sessionのtimeout待ちにしない。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task { [weak self] in
                guard let self else { return }
                await prepareForTermination?()
                readyToTerminate = true
                replyToTermination(sender, true)
            }
        }
        return .terminateLater
    }

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
                    .onAppear {
                        appDelegate.prepareForTermination = { await appState.midiUse.stop() }
                    }
            }
        }
    }
}
