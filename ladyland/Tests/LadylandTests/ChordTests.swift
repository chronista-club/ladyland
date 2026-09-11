import Testing

@testable import Ladyland

@Suite("和音判定")
struct ChordTests {
    /// C4 = 60 を基準にした音名 → ノート番号
    private func n(_ names: [Int]) -> [UInt8] { names.map { UInt8(60 + $0) } }

    @Test("三和音 — メジャー / マイナー")
    func triads() {
        #expect(ChordDetector.detect(notes: n([0, 4, 7]))?.name == "C")
        #expect(ChordDetector.detect(notes: n([0, 3, 7]))?.name == "Cm")
        #expect(ChordDetector.detect(notes: n([2, 5, 9]))?.name == "Dm")
        #expect(ChordDetector.detect(notes: n([7, 11, 14]))?.name == "G")
    }

    @Test("四和音 — 7th 系")
    func sevenths() {
        #expect(ChordDetector.detect(notes: n([0, 4, 7, 11]))?.name == "Cmaj7")
        #expect(ChordDetector.detect(notes: n([7, 11, 14, 17]))?.name == "G7")
        #expect(ChordDetector.detect(notes: n([2, 5, 9, 12]))?.name == "Dm7")
        #expect(ChordDetector.detect(notes: n([11, 14, 17, 21]))?.name == "Bm7b5")
    }

    @Test("転回形はスラッシュ表記になる")
    func inversions() {
        // E G C = C の第 1 転回
        #expect(ChordDetector.detect(notes: n([4, 7, 12]))?.name == "C/E")
        // G C E = C の第 2 転回
        #expect(ChordDetector.detect(notes: n([7, 12, 16]))?.name == "C/G")
    }

    @Test("ベース音が曖昧さを決める — 同じピッチクラス集合でも読みが変わる")
    func bassDecidesAmbiguity() {
        // A C E G は Am7 とも C6 とも読める。**最低音がルートの読みを採る**
        let am7 = ChordDetector.detect(notes: n([-3, 0, 4, 7]))  // A3 C4 E4 G4
        #expect(am7?.name == "Am7")

        let c6 = ChordDetector.detect(notes: n([0, 4, 7, 9]))  // C4 E4 G4 A4
        #expect(c6?.name == "C6")
    }

    @Test("キーが分かるとキー外のルートを避ける")
    func keyContextBreaksTies() {
        // D F# A（キー C では F# がキー外）— キー情報なしでも D と読めるが、
        // キーを渡しても壊れないこと（回帰の壁）
        let inD = ChordDetector.detect(notes: n([2, 6, 9]), keyRoot: 2, scale: .major)
        #expect(inD?.name == "D")
    }

    @Test("オクターブ違いの重複は同じ和音として畳まれる")
    func octavesCollapse() {
        #expect(ChordDetector.detect(notes: n([0, 4, 7, 12, 16]))?.name == "C")
    }

    @Test("判定できないものは nil — 単音・無音")
    func rejectsUnknown() {
        #expect(ChordDetector.detect(notes: []) == nil)
        #expect(ChordDetector.detect(notes: n([0])) == nil)
        #expect(ChordDetector.detect(notes: n([0, 12])) == nil, "オクターブは 1 音に畳まれる")
        // 半音塊は既知の型に当たらない
        #expect(ChordDetector.detect(notes: n([0, 1, 2])) == nil)
    }

    @Test("5 度だけは power chord として読む")
    func powerChord() {
        #expect(ChordDetector.detect(notes: n([0, 7]))?.name == "C5")
    }

    @Test("sus は三和音より後回しにしない — 完全一致なので迷わない")
    func suspended() {
        #expect(ChordDetector.detect(notes: n([0, 5, 7]))?.name == "Csus4")
        #expect(ChordDetector.detect(notes: n([0, 2, 7]))?.name == "Csus2")
    }
}
