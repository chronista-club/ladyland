//! 和音判定（mako 要望 2026-08-04「Keystage で弾いてるのからコードって
//! 割り出せる？ 最近の DAW で見るけど」）。
//!
//! 純関数のみ — 入力は「いま鳴っているノート番号」、出力は和音名。
//! KeyScale と同じ語彙（ルートからの半音距離 Set）で書いてあるので、
//! 「この和音はキー内か」の判定も同じ土俵に乗る。
//!
//! ⚠️ **原理的に曖昧なものがある**: `A C E G` は Am7 とも C6 とも読める
//! （ピッチクラス集合が同一）。決め手は 2 つ —
//!   1. **ベース音**（最低音）をルート候補として優先する
//!   2. それでも割れるならキー内の和音を優先する
//! DAW の Chord 表示が「だいたい合っているが時々ずれる」のはこの構造のため。

import Foundation

/// 和音の型 — ルートからの半音距離で定義する（ScaleKind.intervals と同じ表現）
enum ChordQuality: String, CaseIterable, Sendable {
    case power
    case major
    case minor
    case diminished
    case augmented
    case sus2
    case sus4
    case major6
    case minor6
    case dominant7
    case major7
    case minor7
    case minorMajor7
    case halfDiminished7
    case diminished7
    case add9

    /// ルートからの半音距離
    var intervals: Set<Int> {
        switch self {
        case .power: return [0, 7]
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .sus2: return [0, 2, 7]
        case .sus4: return [0, 5, 7]
        case .major6: return [0, 4, 7, 9]
        case .minor6: return [0, 3, 7, 9]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        case .minorMajor7: return [0, 3, 7, 11]
        case .halfDiminished7: return [0, 3, 6, 10]
        case .diminished7: return [0, 3, 6, 9]
        case .add9: return [0, 2, 4, 7]
        }
    }

    /// ルート名に続けて出す接尾辞（ROTO の LCD は 12 字なので短く）
    var suffix: String {
        switch self {
        case .power: return "5"
        case .major: return ""
        case .minor: return "m"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .sus2: return "sus2"
        case .sus4: return "sus4"
        case .major6: return "6"
        case .minor6: return "m6"
        case .dominant7: return "7"
        case .major7: return "maj7"
        case .minor7: return "m7"
        case .minorMajor7: return "mM7"
        case .halfDiminished7: return "m7b5"
        case .diminished7: return "dim7"
        case .add9: return "add9"
        }
    }

    /// 曖昧なとき、どちらを先に読むか（小さいほど優先）。
    /// 三和音を四和音より先に見るのは、増えた音がテンションのこともあるため
    var priority: Int {
        switch self {
        case .major, .minor: return 0
        case .dominant7, .major7, .minor7: return 1
        case .sus4, .sus2, .diminished, .augmented: return 2
        case .major6, .minor6, .minorMajor7, .halfDiminished7, .diminished7, .add9: return 3
        case .power: return 4
        }
    }
}

/// 判定結果
struct Chord: Equatable, Sendable {
    /// ルートのピッチクラス（0 = C）
    let root: Int
    let quality: ChordQuality
    /// ルート以外が最低音のときのベース（転回形。同じなら nil）
    let bass: Int?

    /// "Cmaj7" / "Am7/G"
    var name: String {
        let base = Chord.noteName(root) + quality.suffix
        guard let bass else { return base }
        return base + "/" + Chord.noteName(bass)
    }

    static func noteName(_ pitchClass: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((pitchClass % 12) + 12) % 12]
    }
}

enum ChordDetector {
    /// 鳴っているノートから和音を割り出す（純関数）。
    ///
    /// - Parameters:
    ///   - notes: MIDI ノート番号。**オクターブ違いの重複は問わない**が、
    ///     最低音はベース判定に使うので実音のまま渡すこと
    ///   - keyRoot: キーのルート（0 = C）。曖昧なときの決め手に使う
    ///   - scale: キーのスケール。同上
    /// - Returns: 判定できなければ nil（2 音未満、既知の型に当たらない）
    static func detect(notes: [UInt8], keyRoot: Int? = nil, scale: ScaleKind? = nil) -> Chord? {
        guard let lowest = notes.min() else { return nil }
        let pitchClasses = Set(notes.map { Int($0) % 12 })
        guard pitchClasses.count >= 2 else { return nil }

        let bass = Int(lowest) % 12
        var best: (chord: Chord, score: Int)?

        for root in pitchClasses {
            // ルートからの相対に置き換えて既知の型と**完全一致**を見る。
            // 部分一致まで許すと、テンション 1 個で別の和音に化けて
            // 表示がちらつく（ライブでは読めない情報になる）
            let relative = Set(pitchClasses.map { (($0 - root) % 12 + 12) % 12 })
            for quality in ChordQuality.allCases where quality.intervals == relative {
                // スコアは小さいほど良い
                var score = quality.priority
                // ベース音がルート = 基本形。転回形より読みやすいので優先
                if root != bass { score += 10 }
                // キーが分かっているならキー内のルートを優先
                if let keyRoot, let scale {
                    let degree = ((root - keyRoot) % 12 + 12) % 12
                    if !scale.intervals.contains(degree) { score += 5 }
                }
                if best == nil || score < best!.score {
                    best = (
                        Chord(root: root, quality: quality, bass: root == bass ? nil : bass),
                        score
                    )
                }
            }
        }
        return best?.chord
    }
}
