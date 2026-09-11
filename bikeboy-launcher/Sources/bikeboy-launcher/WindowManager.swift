import Foundation
import AppKit
import ApplicationServices

// MARK: - Window Manager

class WindowManager {

    // MARK: - App Activation

    /// アプリをアクティブ化
    func activateApp(bundleId: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            // アプリが起動していない場合は起動
            return launchApp(bundleId: bundleId)
        }

        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    /// アプリを起動
    func launchApp(bundleId: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            print("アプリが見つかりません: \(bundleId)")
            return false
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if let error = error {
                print("アプリ起動エラー: \(error)")
            }
        }

        return true
    }

    // MARK: - Window Management

    /// 特定のウィンドウタイトルを持つウィンドウをアクティブ化
    func activateWindow(bundleId: String, windowTitle: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return false
        }

        let pid = app.processIdentifier
        guard let axApp = getAXApplication(pid: pid) else {
            return false
        }

        guard let windows = getAXWindows(from: axApp) else {
            return false
        }

        for window in windows {
            if let title = getAXWindowTitle(window), title.contains(windowTitle) {
                // ウィンドウを最前面に
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)

                // アプリをアクティブ化
                app.activate(options: [.activateIgnoringOtherApps])
                return true
            }
        }

        return false
    }

    /// ウィンドウの位置とサイズを設定
    func setWindowPosition(bundleId: String, windowTitle: String?, position: WindowPosition) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            return false
        }

        let pid = app.processIdentifier
        guard let axApp = getAXApplication(pid: pid) else {
            return false
        }

        guard let windows = getAXWindows(from: axApp) else {
            return false
        }

        for window in windows {
            // タイトルフィルタ
            if let titleFilter = windowTitle {
                guard let title = getAXWindowTitle(window), title.contains(titleFilter) else {
                    continue
                }
            }

            // 位置を設定
            var point = CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
            if let pointValue = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
            }

            // サイズを設定
            var size = CGSize(width: CGFloat(position.width), height: CGFloat(position.height))
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }

            return true
        }

        return false
    }

    // MARK: - Scene Activation

    /// Sceneをアクティブ化（全アプリを配置）
    func activateScene(_ scene: Scene, in context: Context) {
        print("Scene切り替え: \(context.name)/\(scene.name)")

        for app in scene.apps {
            // アプリをアクティブ化
            if let windowTitle = app.windowTitle {
                if !activateWindow(bundleId: app.bundleId, windowTitle: windowTitle) {
                    // ウィンドウが見つからない場合はアプリ自体をアクティブ化
                    _ = activateApp(bundleId: app.bundleId)
                }
            } else {
                _ = activateApp(bundleId: app.bundleId)
            }

            // 位置を設定
            if let position = app.position {
                // 少し待ってから位置設定（ウィンドウ生成待ち）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    _ = self?.setWindowPosition(
                        bundleId: app.bundleId,
                        windowTitle: app.windowTitle,
                        position: position
                    )
                }
            }
        }

        // 最後のアプリにフォーカス
        if let lastApp = scene.apps.last {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                _ = self?.activateApp(bundleId: lastApp.bundleId)
            }
        }
    }

    // MARK: - Accessibility Helpers

    private func getAXApplication(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return app
    }

    private func getAXWindows(from app: AXUIElement) -> [AXUIElement]? {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        return windows
    }

    private func getAXWindowTitle(_ window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

        guard result == .success, let title = titleRef as? String else {
            return nil
        }

        return title
    }

    // MARK: - Accessibility Permission

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
