//! ladyland — 8〜12 の自分の楽器を住まわせ、持ち替えながら完全即興を演奏する
//! macOS アプリ（design/06）。
//!
//! SPM executable から SwiftUI アプリを起動する。@main の App だけだと
//! `swift run` 時に前面に来ない（activation policy が .prohibited 相当）ため、
//! AppDelegate で .regular へ昇格して activate する。

import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var canCheckForUpdates = false
    private var updaterController: SPUStandardUpdaterController?
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
        startUpdates()
        // ウィンドウ配置（フルスクリーン / ウィンドウ + 画面 + 位置）は
        // AppState が持つ WindowPlacementController の仕事（start() で適用）
    }

    // ライブ用途: ウィンドウを閉じたら終了（バックグラウンド残留させない）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// design/13-app-updates.md — 定期確認は静かな表示だけ。適用・再起動は明示操作から。
// Sparkle 2 の ObjC protocol は actor 未注釈。UI callback はメインスレッドで届く。
extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    func startUpdates() {
        // swift run / swift test では更新もネットワークアクセスも始めない。
        guard updaterController == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // 起動直後・idle 復帰も演奏している可能性がある。手動確認には呼ばれない。
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        availableUpdateVersion = update.displayVersionString
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableUpdateVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdateVersion = nil
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
                    .environmentObject(appDelegate)
                    .onAppear {
                        appDelegate.prepareForTermination = { await appState.midiUse.stop() }
                    }
            }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("アップデートを確認…", action: appDelegate.checkForUpdates)
                    .disabled(!appDelegate.canCheckForUpdates)
                Divider()
            }
        }
    }
}
