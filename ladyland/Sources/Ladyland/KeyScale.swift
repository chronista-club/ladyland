//! キー/スケール状態と音階→パッド色の写像（design/06 §8、spec/04 interaction 層）。
//!
//! LPD8 を第 2 の声部（セカンドキーボード）として使うとき、
//! 「どのパッドがキーの中の音か」を LED の基本色で示す:
//!   ルート音 = 強い暖色 / スケール内 = 淡い寒色 / スケール外 = 消灯
//! 純関数のみ — LedBus の setBase に流す色配列を作るのが仕事。

import Lpd8Kit

/// スケール種（interval set はルートからの半音距離）
enum ScaleKind: String, Codable, CaseIterable, Sendable {
    case major
    case naturalMinor
    case dorian
    case mixolydian
    case majorPentatonic
    case minorPentatonic
    case chromatic

    var intervals: Set<Int> {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .naturalMinor: return [0, 2, 3, 5, 7, 8, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .majorPentatonic: return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .chromatic: return Set(0..<12)
        }
    }

    var displayName: String {
        switch self {
        case .major: return "メジャー"
        case .naturalMinor: return "ナチュラルマイナー"
        case .dorian: return "ドリアン"
        case .mixolydian: return "ミクソリディアン"
        case .majorPentatonic: return "メジャーペンタ"
        case .minorPentatonic: return "マイナーペンタ"
        case .chromatic: return "クロマチック（全部）"
        }
    }
}

/// パッド 1 枚の音階上の役割
enum NoteRole: Equatable {
    case root
    case inScale
    case outOfScale
}

struct KeyScale: Codable, Equatable, Sendable {
    /// ルートのピッチクラス 0-11（0 = C）
    var root: Int
    var scale: ScaleKind

    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// note（MIDI ノート番号）の役割 — オクターブ非依存の純関数
    func role(ofNote note: Int) -> NoteRole {
        let interval = ((note - root) % 12 + 12) % 12
        if interval == 0 { return .root }
        return scale.intervals.contains(interval) ? .inScale : .outOfScale
    }

    /// LED 基本色: ルート = 暖色で強く / スケール内 = 寒色で淡く / 外 = 消灯。
    /// padNotes は実機のパッド → ノート対応（プログラムごとに違う。
    /// エディタの GET で実機値に更新される — それまでは既定マップ）
    func baseColors(padNotes: [UInt8]) -> [Rgb8] {
        padNotes.map { note in
            switch role(ofNote: Int(note)) {
            case .root: return Rgb8(255, 120, 0)
            case .inScale: return Rgb8(0, 60, 140)
            case .outOfScale: return .off
            }
        }
    }
}

/// LPD8 実機（プログラム 1）のパッド → ノート対応の既定値。
/// 2026-07-31 の実機ダンプで観測（entry 0-3 = note 44-47、entry 4-7 = 40-43）。
/// エディタ PR の GET でプログラムに追従する
enum Lpd8DefaultPadNotes {
    static let program1: [UInt8] = [44, 45, 46, 47, 40, 41, 42, 43]

    /// **プログラムごとに番号をばらす**（mako 裁定 2026-08-04「LPD8 を
    /// ガンガンこちらが更新する運用なので、それぞれの PROGRAM 1-4 に
    /// ばらけるように割り当てられない？」）。
    ///
    /// LPD8 は**プログラム切替を MIDI で通知しない**。番号が重なっていると
    /// どのプログラムから来たか永久に分からないが、ばらしておけば
    /// **受けた番号だけで判別できる**。
    ///
    /// 上段 4 → 下段 4 の並びは PROG1 の実機観測に倣う（44-47 が上段）
    static let byProgram: [[UInt8]] = [
        program1,
        [52, 53, 54, 55, 48, 49, 50, 51],
        [60, 61, 62, 63, 56, 57, 58, 59],
        [68, 69, 70, 71, 64, 65, 66, 67],
    ]

    /// 受けたノートがどのプログラムのものか（1-4。未知は nil）
    static func program(of note: UInt8) -> Int? {
        byProgram.firstIndex { $0.contains(note) }.map { $0 + 1 }
    }

    /// プログラム内の位置（0-7。未知は nil）
    static func index(of note: UInt8) -> Int? {
        for pads in byProgram {
            if let i = pads.firstIndex(of: note) { return i }
        }
        return nil
    }
}

/// LPD8 mk2 パッドの **CC**（mako 2026-08-06「基本は Pad は、CC モードにしてる想定で」）。
///
/// LPD8 のパッドは Note / CC / Program Change の**どれを送るかを本体ボタンで切り替える**
/// （SysEx には 3 つとも入っていて、モードのフィールドは無い）。演奏中に切り替わりうるので、
/// **ホスト側は Note と CC の両方を拾う** — そうすればモードに依存しない。
///
/// ノート番号と同じくプログラムごとにばらす（`Lpd8DefaultPadNotes` と同じ作法）
enum Lpd8DefaultPadCCs {
    /// ⚠️ **32 を飛ばす** — Bank Select LSB で、叩くと機器内部のバンクが変わる
    /// （`FaceKnobAssignment.unsafeCCs`）。ノブの CC（79-117）とも重ならない帯を使う
    static let byProgram: [[UInt8]] = [
        [12, 13, 14, 15, 16, 17, 18, 19],
        [20, 21, 22, 23, 24, 25, 26, 27],
        [33, 34, 35, 36, 37, 38, 39, 40],
        [41, 42, 43, 44, 45, 46, 47, 48],
    ]

    /// 受けた CC がどのプログラムのパッドか（1-4。未知は nil）
    static func program(of cc: UInt8) -> Int? {
        byProgram.firstIndex { $0.contains(cc) }.map { $0 + 1 }
    }

    /// プログラム内の位置（0-7。未知は nil）
    static func index(of cc: UInt8) -> Int? {
        for ccs in byProgram {
            if let i = ccs.firstIndex(of: cc) { return i }
        }
        return nil
    }
}

/// LPD8 mk2 ノブの既定 CC（実機ゴールデンダンプの観測値。K1-K8 = CC79-86。
/// エディタの GET でプログラムに追従する — padNotes と同じ作法）
enum Lpd8DefaultKnobCCs {
    static let program1: [UInt8] = [79, 80, 81, 82, 83, 84, 85, 86]

    /// パッドと同じくプログラムごとにばらす。
    ///
    /// ⚠️ **95-101 を飛ばしている** — 96-101 は NRPN / RPN のアドレス指定で、
    /// 単独で回すと機器内部の別パラメータが書き換わる（`FaceKnobAssignment
    /// .unsafeCCs`）。95 は Effects Depth で GM 機器が拾う
    static let byProgram: [[UInt8]] = [
        program1,
        [87, 88, 89, 90, 91, 92, 93, 94],
        [102, 103, 104, 105, 106, 107, 108, 109],
        [110, 111, 112, 113, 114, 115, 116, 117],
    ]

    /// 受けた CC がどのプログラムのものか（1-4。未知は nil）
    static func program(of cc: UInt8) -> Int? {
        byProgram.firstIndex { $0.contains(cc) }.map { $0 + 1 }
    }

    /// プログラム内の位置（0-7。未知は nil）。
    /// **どの PROG のノブでも位置が同じなら同じものを動かす**ようにするため
    static func index(of cc: UInt8) -> Int? {
        for ccs in byProgram {
            if let i = ccs.firstIndex(of: cc) { return i }
        }
        return nil
    }
}
