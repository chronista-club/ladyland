//! Debug ウィンドウ（design/06 §8 追補）。
//!
//! ログをアプリ内で直接見る非モーダル補助ウィンドウ — 設定ウィンドウと同じ
//! NSWindow 直接管理パターン。「開いて確認して閉じる」。

import AppKit
import CreoUI
import SwiftUI

@MainActor
final class DebugWindowController {
    private var window: NSWindow?

    /// キーモニタのガード判定用（Debug ウィンドウの TextField を壊さない）
    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    func open(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: ThemedRoot { DebugLogView(log: appState.debugLog) }
        )
        let window = NSWindow(contentViewController: host)
        window.title = "ladyland debug"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.window = nil
            }
        }
    }
}

/// ログビュー — 追尾スクロール + フィルタ + クリア。
///
/// 独立ウィンドウと **R sidebar の下段**（mako 要望 2026-08-04
/// 「デバッグログウィンドウを R sidebar に常設＋開閉付き＋下付き」）の
/// 両方で使う。サイドバーは幅 356 しかないので、**最小サイズは呼び手が決める**
struct DebugLogView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var log: DebugLog
    /// 狭いところ（サイドバー）に入れるとき true — 最小サイズを主張しない
    var compact = false
    @State private var query = ""
    @State private var follow = true
    /// MIDI だけに絞るか（mako 要望 2026-08-04「常時 MIDI は見れた方がいい」）。
    /// NSLog と同じ川に流れるので、絞らないと MIDI が埋もれる
    @State private var midiOnly = false

    private var visibleLines: [DebugLog.Line] {
        // `log.revision` を読むことで間引き後の更新に追随する
        // （`lines` は @Published ではない — DebugLog の頭のコメント参照）
        _ = log.revision
        return DebugLog.filter(log.lines, query: query, kinds: midiOnly ? [.midi] : nil)
    }

    var body: some View {
        VStack(spacing: CreoUITokens.spacingS) {
            HStack(spacing: compact ? CreoUITokens.spacingS : CreoUITokens.spacingM) {
                TextField(compact ? "フィルタ" : "フィルタ（例: keystage / thumbnail / editor）",
                    text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(compact ? LadylandFont.deskCaption : nil)
                Toggle("追尾", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .font(compact ? LadylandFont.deskCaption : nil)
                Text("\(visibleLines.count)")
                    .font(LadylandFont.deskCaption)
                    .monospacedDigit()
                    .foregroundColor(theme.textSecondary)
                if !compact {
                    Button("クリア") { log.clear() }
                }
            }
            .padding([.horizontal, .top], compact ? CreoUITokens.spacingS : CreoUITokens.spacingM)

            // **すべて ⇄ MIDI**。MIDI 側は MidiRouter の判断だけが残るので、
            // 「どの Ctrl から・何が・どこへ」が連続して読める
            Picker("", selection: $midiOnly) {
                Text("すべて").tag(false)
                Text("MIDI").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(compact ? LadylandFont.deskCaption : nil)
            .padding(.horizontal, compact ? CreoUITokens.spacingS : CreoUITokens.spacingM)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines) { line in
                            Text(line.displayText)
                                .font(compact ? LadylandFont.logCompact : LadylandFont.log)
                                // MIDI は前に出す — 混在時に流れが追える
                                .foregroundColor(line.kind == .midi
                                    ? theme.textPrimary : theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, compact ? CreoUITokens.spacingS : CreoUITokens.spacingM)
                }
                .onChange(of: log.revision) {
                    if follow, let last = visibleLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        // 独立ウィンドウのときだけ最小サイズを主張する
        .frame(minWidth: compact ? nil : 640, minHeight: compact ? nil : 400)
        .background(theme.surfaceBgBase)
    }
}
