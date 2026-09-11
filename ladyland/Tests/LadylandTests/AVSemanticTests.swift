//! AV semantic とテーマのテスト。
//!
//! ladyland で発明中の「状態が音楽的」な色語彙（creo-ui への逆輸入候補）。
//! レベル勾配のしきい値はオーディオ機器の慣習（緑→黄→赤）に従う。
//!
//! ⚠️ 語彙は `CreoTheme` の extension に載っている（2026-08-06）ので、
//! **どのテーマでも勾配が成り立つこと**を全 family で確かめる。

import CreoUI
import Testing

@testable import Ladyland

@Suite("AV semantic")
struct AVSemanticTests {
    /// **全テーマで**勾配が成り立つこと。テーマを足したり色を差し替えたりしても
    /// 「緑 → 黄 → 赤」の順序が壊れないことを、family ごとに固定する
    @Test("レベル勾配: 緑（safe）→ 黄（hot）→ 赤（clip）の境界", arguments: CreoThemeFamily.allCases)
    func levelGradient(family: CreoThemeFamily) {
        for theme in [family.dark, family.light] {
            #expect(theme.levelColor(for: 0.0) == theme.levelSafe)
            #expect(theme.levelColor(for: 0.24) == theme.levelSafe)
            #expect(theme.levelColor(for: 0.25) == theme.levelHot)
            #expect(theme.levelColor(for: 0.69) == theme.levelHot)
            #expect(theme.levelColor(for: 0.7) == theme.levelClip)
            #expect(theme.levelColor(for: 1.0) == theme.levelClip)
        }
    }

    @Test("しきい値の順序が保たれている")
    func thresholdOrder() {
        #expect(AVSemantic.hotThreshold < AVSemantic.clipThreshold)
        #expect(AVSemantic.hotThreshold > 0)
        #expect(AVSemantic.clipThreshold < 1)
    }

    /// ⚠️ **しきい値はテーマに乗せない**という設計判断を固定する。
    /// 「何 dB で赤くなるか」は音の事実であって見た目の好みではない —
    /// テーマを変えたらクリップ判定が変わる、という事故を型で防いでいる
    @Test("しきい値はテーマに依存しない — 見た目を変えても判定は動かない")
    func thresholdsAreThemeIndependent() {
        let boundary = AVSemantic.clipThreshold
        for family in CreoThemeFamily.allCases {
            let theme = family.dark
            #expect(theme.levelColor(for: boundary) == theme.levelClip)
            #expect(theme.levelColor(for: boundary - 0.001) == theme.levelHot)
        }
    }
}

@Suite("テーマの選択")
@MainActor
struct ThemeStoreTests {
    @Test("既定は mint / dark — 何も選んでいない状態は今までと同じ見た目")
    func defaults() {
        let store = ThemeStore()
        #expect(store.family == .mint)
        #expect(store.appearance == .dark)
    }

    @Test("保存文字列が往復する", arguments: CreoThemeFamily.allCases)
    func persistRoundTrip(family: CreoThemeFamily) {
        for appearance in ThemeAppearance.allCases {
            let source = ThemeStore()
            source.family = family
            source.appearance = appearance

            let restored = ThemeStore()
            restored.restore(from: source.persistedValue)

            #expect(restored.family == family)
            #expect(restored.appearance == appearance)
        }
    }

    /// ⚠️ **壊れた設定で起動できなくなる方が、テーマが戻らないことより遥かに困る**。
    /// ステージで起きたら詰むので、読めない値は黙って既定へ倒す
    @Test("読めない値は既定へ倒れる — 壊れた設定で起動を止めない")
    func brokenValueFallsBack() {
        for broken in ["", "/", "nope/dark", "mint/nope", "ゴミ", "a/b/c"] {
            let store = ThemeStore()
            store.restore(from: broken)
            #expect(CreoThemeFamily.allCases.contains(store.family))
            #expect(ThemeAppearance.allCases.contains(store.appearance))
        }
    }

    @Test("nil は何も変えない — 初回起動で既定が上書きされない")
    func nilKeepsCurrent() {
        let store = ThemeStore()
        store.family = .sora
        store.restore(from: nil)
        #expect(store.family == .sora)
    }

    @Test("変わったら知らせる — 保存の引き金になる")
    func notifiesOnChange() {
        let store = ThemeStore()
        var count = 0
        store.onChange = { count += 1 }

        store.family = .sora
        #expect(count == 1)

        store.family = .sora  // 同じ値では鳴らさない（無駄な保存を呼ばない）
        #expect(count == 1)

        store.appearance = .light
        #expect(count == 2)
    }
}
