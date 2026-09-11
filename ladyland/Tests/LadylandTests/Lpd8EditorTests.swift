//! Lpd8EditorModel のテスト — GET/SET 状態機械とプリセット保存。
//!
//! fake の送信口を注入し、実機ゴールデン（Lpd8ProgramTests.golden）を
//! 応答として食わせる。SET 安全策（GET-before-SET / 照合）を固定する。

import Foundation
import Testing

import Lpd8Kit

@testable import Ladyland

@Suite("Lpd8EditorModel")
@MainActor
struct Lpd8EditorTests {
    private func makeEditor() -> (Lpd8EditorModel, SentFrames) {
        let editor = Lpd8EditorModel()
        let sent = SentFrames()
        editor.send = { frame in
            sent.frames.append(frame)
            return true
        }
        return (editor, sent)
    }

    @MainActor
    final class SentFrames {
        var frames: [[UInt8]] = []
    }

    @Test("read → GET 送信 → ゴールデン応答で program が埋まる")
    func readFlow() {
        let (editor, sent) = makeEditor()
        editor.selectedProgram = 1
        editor.read()
        #expect(sent.frames.first == Lpd8SysEx.programGetRequest(program: 1))
        #expect(editor.phase == .reading)

        editor.handleSysEx(Lpd8ProgramTests.golden)
        #expect(editor.phase == .idle)
        #expect(editor.program?.pads.first?.note == 44)
        #expect(editor.deviceCopy == editor.program)
        #expect(!editor.isDirty)
    }

    @Test("GET-before-SET — 読み込み前は write が何も送らない")
    func writeRequiresRead() {
        let (editor, sent) = makeEditor()
        editor.program = Lpd8Program.decode(frame: Lpd8ProgramTests.golden)
        editor.write()  // deviceCopy が無い → 拒否
        #expect(sent.frames.isEmpty)
    }

    @Test("write → SET フレーム送信 → GET-back 照合で verified")
    func writeAndVerify() async {
        let (editor, sent) = makeEditor()
        editor.selectedProgram = 1
        editor.read()
        editor.handleSysEx(Lpd8ProgramTests.golden)

        // 変更なしでも SET 経路を通す（dirty 判定は UI 側の disabled が担う）
        editor.write()
        var expectedSet = Lpd8ProgramTests.golden
        expectedSet[4] = 0x01
        #expect(sent.frames.last == expectedSet)

        // 300ms 後に照合の GET が飛ぶ（負荷でずれても良いようポーリングで待つ）
        for _ in 0..<50 where editor.phase != .verifying {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(editor.phase == .verifying)
        #expect(sent.frames.last == Lpd8SysEx.programGetRequest(program: 1))

        // 実機が同じ内容を返す → 照合 OK
        editor.handleSysEx(Lpd8ProgramTests.golden)
        #expect(editor.phase == .verified)
    }

    @Test("対象外プログラムの応答は無視される")
    func ignoresOtherPrograms() {
        let (editor, _) = makeEditor()
        editor.selectedProgram = 2  // ゴールデンは program 1
        editor.read()
        editor.handleSysEx(Lpd8ProgramTests.golden)
        #expect(editor.phase == .reading, "program 番号が違う応答では完了しない")
    }

    @Test("送信不能（LPD8 不在）は即エラー")
    func sendFailure() {
        let editor = Lpd8EditorModel()
        editor.send = { _ in false }
        editor.read()
        #expect(editor.phase == .error("送信できない（LPD8 が見つからない）"))
    }
}

@Suite("Lpd8PresetStore")
struct Lpd8PresetStoreTests {
    @Test("save → list → load の roundtrip")
    func roundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let program = try #require(Lpd8Program.decode(frame: Lpd8ProgramTests.golden))
        try Lpd8PresetStore.save(program, name: "live-8-8", in: dir)
        #expect(Lpd8PresetStore.list(in: dir) == ["live-8-8"])

        let loaded = try #require(Lpd8PresetStore.load(name: "live-8-8", in: dir))
        #expect(loaded == program)
        // JSON 経由でも SET フレームは byte-exact のまま
        var expected = Lpd8ProgramTests.golden
        expected[4] = 0x01
        #expect(loaded.encodeSetFrame() == expected)
    }

    @Test("存在しないプリセットは nil")
    func missingPreset() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-presets-\(UUID().uuidString)")
        #expect(Lpd8PresetStore.load(name: "nope", in: dir) == nil)
        #expect(Lpd8PresetStore.list(in: dir).isEmpty)
    }
}
