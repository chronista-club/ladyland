import Testing

@testable import Ladyland

/// PC キーボード演奏モードの状態機械（`KeyPlay`。cortex の Tab 演奏モード移植）
@Suite("PC キーボード演奏")
struct KeyPlayTests {
    @Test("A = C4（60）から始まり、A 行 = 白鍵 / W 行 = 黒鍵で半音が繋がる")
    func layoutIsChromatic() {
        var play = KeyPlay()
        #expect(play.keyDown(0) == 60, "A = C4")
        // A W S E D F T G Y H U J K O L P ; = C から E+1 まで半音 17 個
        let order: [UInt16] = [0, 13, 1, 14, 2, 3, 17, 5, 16, 4, 32, 38, 40, 31, 37, 35, 41]
        var fresh = KeyPlay()
        let notes = order.compactMap { fresh.keyDown($0) }
        #expect(notes == (60...76).map(UInt8.init), "半音が隙間なく並ぶ")
    }

    @Test("Note Off は押下時の番号 — オクターブを途中で変えても残らない")
    func noteOffUsesPressedNote() {
        var play = KeyPlay()
        #expect(play.keyDown(0) == 60)
        play.shiftOctave(+1)
        // ⚠️ cortex が踏んだ罠: ここで「今のオクターブ」で計算すると 72 に
        // Note Off が飛び、60 が鳴りっぱなしになる
        #expect(play.keyUp(0) == 60, "押下時の 60 へ消音")
        #expect(play.keyDown(0) == 72, "次の押下は新オクターブ")
    }

    @Test("二重押下は nil（リピートの保険）・知らないキーも nil")
    func duplicatesAndUnknownAreNil() {
        var play = KeyPlay()
        #expect(play.keyDown(0) == 60)
        #expect(play.keyDown(0) == nil, "押しっぱなしの再押下")
        #expect(play.keyDown(99) == nil, "演奏キーではない")
        #expect(play.keyUp(99) == nil)
    }

    @Test("オクターブは 0-8 で止まり、releaseAll が押下中を全部返して空になる")
    func octaveClampsAndReleaseAll() {
        var play = KeyPlay()
        for _ in 0..<20 { play.shiftOctave(-1) }
        #expect(play.octave == 0)
        #expect(play.keyDown(0) == 12, "C0")
        for _ in 0..<20 { play.shiftOctave(+1) }
        #expect(play.octave == 8)
        #expect(play.keyDown(1) == 110, "D8")
        let released = play.releaseAll().sorted()
        #expect(released == [12, 110])
        #expect(play.releaseAll().isEmpty, "二度目は空")
    }

    @Test("Z / X と音符キー・既存ショートカットの keyCode が重ならない")
    func keyCodesDoNotCollide() {
        let notes = Set(KeyPlay.semitoneOffsets.keys)
        #expect(!notes.contains(KeyPlay.octaveDownKey))
        #expect(!notes.contains(KeyPlay.octaveUpKey))
        // 既存の役割（Esc 53 / Tab 48 / 矢印 123-126 / ⌥,. 43,47 / ⌘Return 36）
        for reserved: UInt16 in [53, 48, 123, 124, 125, 126, 43, 47, 36] {
            #expect(!notes.contains(reserved), "keyCode \(reserved) が音符と衝突")
        }
    }
}
