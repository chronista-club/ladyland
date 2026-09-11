import Foundation
import KeystageKit
import Testing

@Suite("Keystage SysEx")
struct KeystageSysExTests {
    @Test("フレームは F0 42 4g 00 01 69 mm <len×3> <Func> … F7")
    func framesRequest() {
        let frame = Keystage.frame(.sceneDumpRequest)
        #expect(Array(frame.prefix(7)) == [0xF0, 0x42, 0x40, 0x00, 0x01, 0x69, 0x01])
        #expect(Array(frame[7..<10]) == [0x01, 0x00, 0x00], "len = Func 1 バイトのみ")
        #expect(frame[10] == 0x10)
        #expect(frame.last == 0xF7)
    }

    @Test("Global チャンネルと機種がヘッダに乗る")
    func framesWithChannelAndModel() {
        let frame = Keystage.frame(.globalDumpRequest, globalChannel: 3, model: .keys61)
        #expect(frame[2] == 0x43, "4g の g = Global Ch")
        #expect(frame[6] == 0x09, "Keystage-61 = 09")
        #expect(frame[10] == 0x0E)
    }

    @Test("受信フレームから Func を読む")
    func readsFunction() {
        let ack = Keystage.frame(.ack)
        #expect(Keystage.function(of: ack) == .ack)
        #expect(Keystage.function(of: [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]) == nil, "他社 SysEx")
    }

    // MARK: - NOTE 2 の詰め替え

    @Test("7bit 詰め替えは往復して元に戻る")
    func roundTrips() {
        let original: [UInt8] = [0x00, 0x7F, 0x80, 0xFF, 0x01, 0xAB, 0xCD, 0xEF, 0x10]
        let encoded = Keystage.encode7bit(original)
        #expect(encoded.allSatisfy { $0 < 0x80 }, "SysEx に載るのは 7bit のみ")
        #expect(Keystage.decode7bit(encoded) == original)
    }

    @Test("7 バイトごとに MSB を集めた 1 バイトが先頭に付く")
    func packsMsbFirst() {
        // 全部 MSB が立っていれば、先頭バイトは 7 ビットぶん全部 1 = 0x7F
        let encoded = Keystage.encode7bit([UInt8](repeating: 0x80, count: 7))
        #expect(encoded.count == 8, "7 バイト → 8 バイト")
        #expect(encoded[0] == 0x7F)
        #expect(Array(encoded.dropFirst()) == [UInt8](repeating: 0, count: 7))
    }

    @Test("端数も落とさず往復する")
    func handlesRemainder() {
        for count in 1...20 {
            let data = (0..<count).map { UInt8(($0 * 37) % 256) }
            #expect(Keystage.decode7bit(Keystage.encode7bit(data)) == data, "count=\(count)")
        }
    }

    // MARK: - Scene / Global の書き換え

    @Test("Scene の該当バイトだけが変わる")
    func writesSceneOffset() {
        let scene = [UInt8](repeating: 0, count: 60)
        let changed = Keystage.setting(scene, at: Keystage.SceneOffset.chordSetNum, to: 33)
        #expect(changed[47] == 33, "Chord Set Num = User01")
        #expect(changed[46] == 0, "隣は無傷")
        #expect(changed.count == scene.count)
    }

    @Test("範囲外の書き込みは黙って無視する — Dump を壊さない")
    func ignoresOutOfRange() {
        let scene = [UInt8](repeating: 0, count: 10)
        #expect(Keystage.setting(scene, at: 47, to: 1) == scene)
    }

    @Test("User Chord Set は Size + Note×8 で 1 キー")
    func writesChord() {
        let global = [UInt8](repeating: 0, count: 4000)
        // User01（set 0）の C（key 0）に Cmaj7 を書く
        let changed = Keystage.settingChord(global, set: 0, key: 0, notes: [60, 64, 67, 71])
        let base = Keystage.GlobalOffset.keyOffset(set: 0, key: 0)
        #expect(base == 211)
        #expect(changed[base] == 4, "Size")
        #expect(Array(changed[(base + 1)...(base + 4)]) == [60, 64, 67, 71])
        #expect(changed[base + 5] == 0, "余りはゼロ埋め")
    }

    @Test("9 音以上は 8 音で切る")
    func clipsToEightNotes() {
        let global = [UInt8](repeating: 0, count: 4000)
        let changed = Keystage.settingChord(
            global, set: 1, key: 5, notes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let base = Keystage.GlobalOffset.keyOffset(set: 1, key: 5)
        #expect(changed[base] == 8)
        #expect(Array(changed[(base + 1)...(base + 8)]) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("セットは 108 バイト刻み（12 キー × 9）")
    func setStride() {
        #expect(Keystage.GlobalOffset.bytesPerSet == 108)
        #expect(Keystage.GlobalOffset.keyOffset(set: 1, key: 0) == 211 + 108)
        #expect(Keystage.GlobalOffset.keyOffset(set: 0, key: 1) == 211 + 9)
    }
}

@Suite("Keystage 設定の焼き込み")
struct KeystageSettingsTests {
    /// 実機の Scene Dump と同じ長さのダミー
    private var blank: [UInt8] { [UInt8](repeating: 0, count: 500) }

    @Test("設定 → Dump → 設定 で往復する")
    func roundTrips() {
        var settings = KeystageSettings()
        settings.arpMode = 5  // Random
        settings.arpRate = 6  // 1/12
        settings.arpLatch = true
        settings.arpChance = 80
        settings.chordSet = 32  // User1
        settings.strumDirection = 4  // Velocity

        let dump = Keystage.applying(settings, to: blank)
        #expect(Keystage.settings(from: dump) == settings)
    }

    @Test("該当バイトだけが変わる — ノブ割当やシーン名を巻き添えにしない")
    func touchesOnlyItsOwnBytes() {
        var canvas = blank
        canvas[0] = 0x43  // シーン名 "C…"
        canvas[100] = 99  // ノブ割当の領域
        let dump = Keystage.applying(KeystageSettings(), to: canvas)

        #expect(dump[0] == 0x43, "シーン名は無傷")
        #expect(dump[100] == 99, "ノブ割当は無傷")
        #expect(dump.count == canvas.count)
    }

    @Test("範囲外の値は丸める — 壊れた設定を実機へ送らない")
    func clampsOutOfRange() {
        var settings = KeystageSettings()
        settings.arpMode = 99
        settings.arpRate = -5
        settings.arpChance = 0  // 下限は 1
        settings.chordSet = 200

        let dump = Keystage.applying(settings, to: blank)
        #expect(dump[Keystage.SceneOffset.arpMode] == 6, "Mode は 0-6")
        #expect(dump[Keystage.SceneOffset.arpRate] == 0)
        #expect(dump[Keystage.SceneOffset.arpChance] == 1, "Chance は 1-100")
        #expect(dump[Keystage.SceneOffset.chordSetNum] == 63)
    }

    @Test("短すぎる Dump からは読めない")
    func rejectsShortDump() {
        #expect(Keystage.settings(from: [UInt8](repeating: 0, count: 10)) == nil)
    }

    @Test("既定値は実機の初期状態と同じ（Scene \"CREO\" の実測）")
    func defaultsMatchDevice() {
        let settings = KeystageSettings()
        #expect(settings.arpRate == 7, "1/16")
        #expect(settings.arpGateTime == 100, "±0%")
        #expect(settings.arpChance == 100)
        // **chordSet だけは実機の初期値（Preset1）ではなく User01**。
        // ladyland から中身を触れるのは User セットだけなので、
        // Preset で始まると設定タブを開いても中身が読めない
        #expect(settings.chordSet == 32, "User01")
        #expect(KeystageSettings.chordSetName(settings.chordSet) == "User1")
    }

    @Test("呼び名は GUI と実機で揃う")
    func names() {
        #expect(KeystageSettings.arpModeNames[5] == "Random")
        #expect(KeystageSettings.arpRateNames[6] == "1/12")
        #expect(KeystageSettings.strumDirectionNames[4] == "Velocity")
        #expect(KeystageSettings.chordSetName(0) == "Preset1")
        #expect(KeystageSettings.chordSetName(32) == "User1")
    }
}

@Suite("Keystage 設定の永続化")
struct KeystageSettingsCodableTests {
    @Test("JSON で往復する — 保存は列を増やさず 1 列")
    func encodesToJSON() throws {
        var settings = KeystageSettings()
        settings.arpMode = 4
        settings.arpLatch = true
        settings.chordSet = 40  // User9
        settings.strumTime = 25

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(KeystageSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("既定値も往復する（保存が無い状態からの初回保存）")
    func encodesDefaults() throws {
        let settings = KeystageSettings()
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(KeystageSettings.self, from: data) == settings)
    }
}

@Suite("User セットのコピー")
struct KeystageCopyTests {
    /// 実機と同じ長さの Global Dump
    private var blank: [UInt8] { [UInt8](repeating: 0, count: 4000) }

    @Test("12 キーぶんと名前をまるごと写す")
    func copiesSet() {
        var dump = blank
        dump = Keystage.settingChord(dump, set: 0, key: 0, notes: [60, 64, 67, 71])
        dump = Keystage.settingChord(dump, set: 0, key: 5, notes: [65, 69, 72])
        dump = Keystage.settingChordSetName(dump, set: 0, name: "VERSE")

        let copied = Keystage.copyingChordSet(dump, from: 0, to: 7)
        #expect(Keystage.chord(from: copied, set: 7, key: 0) == [60, 64, 67, 71])
        #expect(Keystage.chord(from: copied, set: 7, key: 5) == [65, 69, 72])
        #expect(Keystage.chordSetName(from: copied, set: 7) == "VERSE")
        // 写し元は無傷
        #expect(Keystage.chord(from: copied, set: 0, key: 0) == [60, 64, 67, 71])
    }

    @Test("写し先の元データは消える — 上書きであって混ざらない")
    func overwritesTarget() {
        var dump = blank
        dump = Keystage.settingChord(dump, set: 3, key: 2, notes: [50, 54, 57])
        // set 0 は空のまま。それを set 3 に写すと set 3 の中身は消える
        let copied = Keystage.copyingChordSet(dump, from: 0, to: 3)
        #expect(Keystage.chord(from: copied, set: 3, key: 2) == [])
    }

    @Test("同じセットへの写しは何もしない")
    func selfCopyIsNoop() {
        let dump = Keystage.settingChord(blank, set: 4, key: 1, notes: [60, 63, 67])
        #expect(Keystage.copyingChordSet(dump, from: 4, to: 4) == dump)
    }

    @Test("範囲外は元の Dump をそのまま返す — 壊さない")
    func rejectsOutOfRange() {
        let short = [UInt8](repeating: 0, count: 300)
        #expect(Keystage.copyingChordSet(short, from: 0, to: 31) == short)
    }
}
