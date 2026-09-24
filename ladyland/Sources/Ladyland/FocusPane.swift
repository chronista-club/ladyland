//! 選択トラックの常設 focus pane（mako 裁定 2026-08-01 スタジオ試奏後
//! 「選択したプラグインのビューを常設で映す UI 領域をセンターに」）。
//!
//! 画面中央に選択トラックのプラグイン view そのものが住む。VALUE
//! エンコーダー / 矢印での順移動に追従し、選択した楽器の顔が常に見える。
//! アイコンからの別ウィンドウ（PluginEditorWindows）はそのまま —
//! **VC は 1 ユニットにつき一度しか取れない**（KORG AU 実機確定）ため、
//! focus pane は view を新規要求せず、隠れているウィンドウから**借りる**
//! （custody 移動 — borrowFocusPaneView / reclaimFocusPaneView）。
//! ウィンドウで編集中はそちらが優先で、focus pane はプレースホルダに退く。

import AppKit
import CoreAudioKit
import CreoUI
import SwiftUI

/// focus pane の表示状態 — 純関数（テスト対象）
enum FocusPaneMode: Equatable {
    /// 空トラック（ロードすべきものが無い）
    case empty
    /// プラグイン view の到着待ち（VC 要求中 / 選択スクラブ中）
    case waiting
    /// ユーザーが別ウィンドウで編集中（custody はウィンドウ側）
    case editingInWindow
    /// focus pane が view を保持して表示中
    case hosting

    static func decide(hasUnit: Bool, hasView: Bool, editorOnScreen: Bool) -> FocusPaneMode {
        guard hasUnit else { return .empty }
        if hasView { return .hosting }
        if editorOnScreen { return .editingInWindow }
        return .waiting
    }
}

/// ネイティブサイズの view を領域に収める配置 — 純関数（テスト対象）。
/// 比率維持・中央寄せ。**領域が余れば拡大もする**（mako 裁定 2026-08-02
/// 「プラグインの表示領域の縦が広くなるので、その表示領域にフィットさせて」）。
/// 拡大は maxScale で頭打ち — AU の view はビットマップ主体で、
/// 上げすぎると単にぼやけるため
enum FocusPaneFit {
    /// 拡大の上限（等倍の 2 倍まで）
    static let maxScale: CGFloat = 2.0

    static func fit(native: CGSize, in container: CGSize) -> (frame: CGRect, scale: CGFloat) {
        guard native.width > 0, native.height > 0,
              container.width > 0, container.height > 0
        else { return (.zero, 1) }
        let scale = min(maxScale, container.width / native.width, container.height / native.height)
        let size = CGSize(width: native.width * scale, height: native.height * scale)
        let origin = CGPoint(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2)
        return (CGRect(origin: origin, size: size), scale)
    }
}

/// 借りてきたプラグイン view を収める AppKit コンテナ。
/// AU が fitted size をサポートする場合は view 自体をリサイズする。
/// 非対応の場合のみ wrapper の frame / bounds の座標変換で比例拡縮する。
final class FocusPaneContainerView: NSView {
    private(set) var hosted: NSView?
    private let wrapper = NSView()
    private var nativeSize: CGSize = .zero
    private weak var audioUnit: AUAudioUnit?
    private var lastProposedSize: CGSize?
    private var resizesView = false

    /// 左上原点で扱う（FocusPaneFit は左上原点で frame を返す）
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AU view はネイティブサイズのまま来る。縮小が間に合わない一瞬や
        // 自前でリサイズする AU があっても、ペインの外へ描かせない
        clipsToBounds = true
        wrapper.clipsToBounds = true
        addSubview(wrapper)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func host(_ view: NSView?, audioUnit: AUAudioUnit? = nil) {
        guard view !== hosted || audioUnit !== self.audioUnit else { return }
        if view !== hosted {
            // A separate editor may already have reclaimed the view.
            if let hosted, hosted.superview === wrapper {
                hosted.removeFromSuperview()
                hosted.setFrameSize(nativeSize)
            }
        }
        self.audioUnit = audioUnit
        lastProposedSize = nil
        resizesView = false
        let sameView = view === hosted
        hosted = view
        guard let view else {
            needsLayout = true
            return
        }
        // AU view はウィンドウ生成時の preferred サイズを frame に持って届く
        var size = view.frame.size
        if size.width < 1 || size.height < 1 {
            size = view.fittingSize
        }
        if !sameView { nativeSize = size }
        // ウィンドウ contentView 由来の autoresizing を切る — 残っていると
        // wrapper の bounds 変更に追従して view 自身が伸縮し、縮小写像が壊れる
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        wrapper.addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let hosted, hosted.superview === wrapper,
              nativeSize.width > 0, nativeSize.height > 0 else { return }
        // 比率と中央寄せは両方式で共通。AU の名前による特例は作らない。
        let fit = FocusPaneFit.fit(native: nativeSize, in: bounds.size)
        guard fit.frame.width > 0, fit.frame.height > 0 else { return }
        if lastProposedSize != fit.frame.size {
            lastProposedSize = fit.frame.size
            let configuration = AUAudioUnitViewConfiguration(
                width: fit.frame.width, height: fit.frame.height, hostHasController: false)
            resizesView = audioUnit?.supportedViewConfigurations([configuration]).contains(0) == true
            if resizesView {
                audioUnit?.select(configuration)
            }
        }
        // Responsive AUs lay out their own content at the fitted size. Scaling
        // their remote parent as well can clip or double-scale the WebView.
        let contentSize = resizesView ? fit.frame.size : nativeSize
        wrapper.frame = fit.frame
        wrapper.bounds = CGRect(origin: .zero, size: contentSize)
        hosted.frame = CGRect(origin: .zero, size: contentSize)
    }
}

struct FocusPaneHost: NSViewRepresentable {
    let hosted: NSView?
    var audioUnit: AUAudioUnit? = nil

    func makeNSView(context: Context) -> FocusPaneContainerView {
        FocusPaneContainerView()
    }

    func updateNSView(_ view: FocusPaneContainerView, context: Context) {
        view.host(hosted, audioUnit: audioUnit)
    }

    static func dismantleNSView(_ view: FocusPaneContainerView, coordinator: ()) {
        view.host(nil)
    }
}

/// focus pane 本体 — 選択トラックに追従する画面中央の常設領域
struct FocusPaneView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let hosted: NSView?
    let editorOnScreen: Bool
    let thumbnail: NSImage?
    let onOpenWindow: () -> Void

    private var mode: FocusPaneMode {
        .decide(hasUnit: slot.audioUnit != nil, hasView: hosted != nil,
                editorOnScreen: editorOnScreen)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(theme.surfaceSurface)
                // 枠は背景側で描く。ペイン全体への overlay は、ヒットテストを
                // 無効にしても AUv3 の WebView 入力を妨げる（MediSynth 実機確認）。
                .overlay(
                    RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                        .stroke(theme.surfaceBorderSubtle, lineWidth: 1)
                        .allowsHitTesting(false)
                )
            switch mode {
            case .hosting:
                FocusPaneHost(hosted: hosted, audioUnit: slot.audioUnit?.auAudioUnit)
                    .padding(4)
            case .empty:
                Label("空トラック — タイルのメニューからロード", systemImage: "square.dashed")
                    .font(LadylandFont.body)
                    .foregroundColor(theme.textTertiary)
            case .editingInWindow:
                placeholder(
                    text: "別ウィンドウで編集中",
                    icon: "macwindow", action: ("前面へ", onOpenWindow))
            case .waiting:
                placeholder(text: "プラグイン画面を準備中…", icon: nil, action: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func placeholder(
        text: String, icon: String?, action: (label: String, run: () -> Void)?
    ) -> some View {
        VStack(spacing: CreoUITokens.spacingS) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 120)
                    .opacity(0.4)
                    .clipShape(RoundedRectangle(cornerRadius: CreoUITokens.radiusS))
            }
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                }
                Text("\(slot.displayName ?? "") — \(text)")
            }
            .font(LadylandFont.body)
            .foregroundColor(theme.textSecondary)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.bordered)
            }
        }
    }
}
