//! 画面のテーマ（mako 要望 2026-08-06「画面の UI テーマを作成しよう。色とかフォントサイズとか」）。
//!
//! フォントは `LadylandFont`（視距離という軸）、**色はここ**。
//!
//! ## creo-ui の 8 テーマに載せる — 新しく色を作らない
//!
//! `CreoThemeEnvironment.swift` の冒頭にこう書いてある:
//!
//! > ladyland consumer feedback #4: 「8 テーマ資産が Swift に届いていない。
//! > 本命は `@Environment(\.creoTheme)` の SwiftUI テーマ注入」への応答
//!
//! **ladyland 自身が要望して作られた経路が、当の ladyland で使われていなかった**
//! （2026-08-06 実測: フラット定数 `theme.textSecondary` を 151 箇所、
//! = `.mintDark` 固定）。CLAUDE.md が cortex について書いている「器はあるが
//! 未配線」と同じ形だったので、ここで繋ぐ。
//!
//! ## なぜ Environment だけでは足りないか
//!
//! ⚠️ **`NSHostingController` は環境ツリーを切る**。ladyland には SwiftUI の
//! ルートが 4 つある:
//!
//! | ルート | 出どころ |
//! |---|---|
//! | 本体ウィンドウ | `LadylandApp` の `WindowGroup` |
//! | 設定ウィンドウ | `SettingsWindow` の `NSHostingController` |
//! | Debug ウィンドウ | `DebugWindow` の `NSHostingController` |
//! | **サンプラーの画面** | `LadySampler.requestViewController`（AU の中） |
//!
//! 本体に注入しても他の 3 つには届かない。とくに 4 つ目は **AU の中**で、
//! `AppState` を知らない（知らせるべきでもない — AU はホストの都合を知らない）。
//!
//! そこで**選択を持つのは `ThemeStore`（1 個）**、注入は各ルートが自分でやる。
//! 読む側は今までどおり `@Environment(\.creoTheme)` で受ける。

import CreoUI
import SwiftUI

/// 外観（light / dark をどう決めるか）
enum ThemeAppearance: String, CaseIterable, Identifiable, Sendable {
    /// 常に暗い — **ステージの既定**。客席が暗いので明るい画面は目が眩む
    case dark
    /// 常に明るい — 昼のリハ・明るいスタジオ
    case light
    /// macOS の外観設定に追従する
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "ダーク"
        case .light: return "ライト"
        case .system: return "システムに追従"
        }
    }
}

/// テーマの選択を持つ 1 個。**4 つのルートがここを見て自分に注入する**
@MainActor
final class ThemeStore: ObservableObject {
    /// ⚠️ **AU の中（`LadySampler`）から届く唯一の口**。AU は `AppState` を
    /// 知らないので、`@EnvironmentObject` では渡せない。
    /// アプリ 1 プロセスに 1 つの外観設定なので、共有 1 個で足りる
    static let shared = ThemeStore()

    /// 色の系統（mint / contrast / oldschool / sora）
    @Published var family: CreoThemeFamily = .mint {
        didSet { if family != oldValue { onChange?() } }
    }

    /// 明暗の決め方
    @Published var appearance: ThemeAppearance = .dark {
        didSet { if appearance != oldValue { onChange?() } }
    }

    /// 変わったことをアプリへ知らせる（**保存の引き金**）。
    /// テーマは設営中に決めるもので頻繁には動かないので、変わった瞬間に保存する
    var onChange: (() -> Void)?

    /// 保存用の文字列（`"mint/dark"`）。**family と appearance を 1 列に畳む** —
    /// 設定 1 つに列 2 本を足すより、増えたときに移行が楽
    var persistedValue: String { "\(family.rawValue)/\(appearance.rawValue)" }

    /// 保存された文字列から戻す。**読めない値は既定へ倒す**（壊れた設定で
    /// 起動できなくなる方が、テーマが戻らないことより遥かに困る）
    func restore(from value: String?) {
        guard let value else { return }
        let parts = value.split(separator: "/", maxSplits: 1)
        if let first = parts.first, let restored = CreoThemeFamily(rawValue: String(first)) {
            family = restored
        }
        if parts.count > 1, let restored = ThemeAppearance(rawValue: String(parts[1])) {
            appearance = restored
        }
    }
}

/// **テーマを被せるラッパ**。4 つの SwiftUI ルートがそれぞれこれで包む。
///
/// `@ObservedObject` でストアを見ているので、**設定でテーマを変えると
/// 4 ルート全部が同時に追従する**（注入し直しではなく再評価で届く）。
///
/// ⚠️ 「システムに追従」だけ `creoTheme(_ family:)` の方を使う —
/// creo-ui 側が `@Environment(\.colorScheme)` を見て light/dark を選ぶ modifier を
/// 持っているので、外観の追従を**こちらで再実装しない**
struct ThemedRoot<Content: View>: View {
    @ObservedObject private var store = ThemeStore.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    @ViewBuilder
    var body: some View {
        switch store.appearance {
        case .dark: content.creoTheme(store.family.dark)
        case .light: content.creoTheme(store.family.light)
        case .system: content.creoTheme(store.family)
        }
    }
}

extension CreoThemeFamily {
    /// 設定に出す名前。**色そのものを説明しない** — 選んで見るのが速い
    var label: String {
        switch self {
        case .mint: return "Mint（既定）"
        case .contrast: return "Contrast（高コントラスト）"
        case .oldschool: return "Oldschool"
        case .sora: return "Sora"
        }
    }

    /// 設定のプレビューに出す代表色（brand / text / surface の 3 点）
    var swatch: [Color] { [dark.brandPrimary, dark.textPrimary, dark.surfaceBgEmphasis] }
}

// MARK: - AV セマンティックカラー

/// AV セマンティックカラー — ladyland での発明（creo-ui への逆輸入候補）。
///
/// creo-ui の semantic（success/warning/error）は「フォーム的」な意味体系で、
/// オーディオ UI に必要な「状態が音楽的」な語彙が無い（creoui atlas への提言 #10、
/// `mem_1CdYDzMNtEZsfLZjeDi7Mn`）。ここで名前を発明して実戦で磨き、
/// 安定したら `color.av.*` として creo-ui の DTCG に逆輸入する。
///
/// ⚠️ **`CreoTheme` の extension として持つ**（2026-08-06）。以前は
/// `enum AVSemantic` の `static let` で、フラット定数を指していた —
/// つまり**テーマを切り替えてもメーターだけ前の色のまま**になる形だった。
/// 語彙はテーマの上に乗るものなので、テーマ自身に生やすのが正しい。
///
/// 実体は creo-ui の既存トークンへの alias（色相はオーディオ機器の慣習と
/// 一致: レベルの緑→黄→赤）。名前だけを先に確定させる。
extension CreoTheme {

    // MARK: レベルメーター（音量の安全域）

    /// 安全域 (〜 -12dBFS 相当)。健全に鳴っている
    var levelSafe: Color { semanticSuccess }

    /// ホット域 (-12 〜 -3dBFS 相当)。攻めているが割れていない
    var levelHot: Color { semanticWarning }

    /// クリップ域 (-3dBFS 〜)。歪みの危険
    var levelClip: Color { semanticError }

    /// メーターの背景（無音レンジ）
    var levelTrack: Color { surfaceBgEmphasis }

    // MARK: 演奏状態

    /// live — いま音を受ける楽器（選択中）
    var live: Color { brandPrimary }

    /// standby — 常駐しているが選択されていない
    var standby: Color { textTertiary }

    /// ピーク値に応じたメーター色
    func levelColor(for peak: Float) -> Color {
        if peak >= AVSemantic.clipThreshold { return levelClip }
        if peak >= AVSemantic.hotThreshold { return levelHot }
        return levelSafe
    }
}

/// しきい値（dBFS ではなく linear peak）。
/// **色ではないのでテーマに乗せない** — テーマを変えても「何 dB で赤くなるか」は
/// 変わってはいけない（音の事実であって、見た目の好みではない）
enum AVSemantic {
    /// levelSafe → levelHot の境界（≈ -12dBFS）
    static let hotThreshold: Float = 0.25

    /// levelHot → levelClip の境界（≈ -3dBFS）
    static let clipThreshold: Float = 0.7
}
