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
/// 縮小は wrapper の frame（縮小後）/ bounds（ネイティブ）の座標変換で行う —
/// 描画もマウスイベントも AppKit が正しく写像する（layer transform と違い
/// クリック位置がズレない）
final class FocusPaneContainerView: NSView {
    private(set) var hosted: NSView?
    private let wrapper = NSView()
    private var nativeSize: CGSize = .zero

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

    func host(_ view: NSView?) {
        guard view !== hosted else { return }
        hosted?.removeFromSuperview()
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
        nativeSize = size
        // ウィンドウ contentView 由来の autoresizing を切る — 残っていると
        // wrapper の bounds 変更に追従して view 自身が伸縮し、縮小写像が壊れる
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        wrapper.addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let hosted, nativeSize.width > 0, nativeSize.height > 0 else { return }
        // frame（縮小後）と bounds（ネイティブ）の食い違いが縮小写像そのもの。
        // 描画もマウス座標も AppKit が変換する（layer transform と違いズレない）
        let fit = FocusPaneFit.fit(native: nativeSize, in: bounds.size)
        wrapper.frame = fit.frame
        wrapper.bounds = CGRect(origin: .zero, size: nativeSize)
        hosted.frame = CGRect(origin: .zero, size: nativeSize)
    }
}

struct FocusPaneHost: NSViewRepresentable {
    let hosted: NSView?

    func makeNSView(context: Context) -> FocusPaneContainerView {
        FocusPaneContainerView()
    }

    func updateNSView(_ view: FocusPaneContainerView, context: Context) {
        view.host(hosted)
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
            switch mode {
            case .hosting:
                FocusPaneHost(hosted: hosted)
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
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(theme.surfaceBorderSubtle, lineWidth: 1)
        )
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
