//! Keystage の ARP / CHORD 設定（mako 裁定 2026-08-04「ラック全体で 1 セット」）。
//!
//! **ladyland が SSOT**。本体で操作した内容はホストから読めない（Dump は
//! 保存済みしか返さない — README「Dump の二重構造」）ので、ズレを気にせず
//! こちらが持ち、変更のたびに送り込む push 型で扱う。
//!
//! ⚠️ **ARP / CHORD の on/off はここに無い**。Dump に載らない（揮発）ので
//! ホストからは起こせない — **起動は手で、中身はホストから**という分担。

import Foundation

public struct KeystageSettings: Codable, Equatable, Sendable {
    // ── Arpeggiator ──
    /// 0=Up 1=Down 2=Up-Down 3=Down-Up 4=Play 5=Random 6=Trigger
    public var arpMode: Int
    /// 0-11 = 1/1, 1/2, 1/3, 1/4, 1/6, 1/8, 1/12, 1/16, 1/24, 1/32, 1/48, 1/64
    public var arpRate: Int
    /// 0-3 = 1〜4 オクターブ
    public var arpOctave: Int
    /// 手を離しても鳴り続ける（ライブでは実質必須 — 両手が空く）
    public var arpLatch: Bool
    /// 弾き直しでパターンを頭から始めるか
    public var arpKeySync: Bool
    /// 0-100 (%)
    public var arpSwing: Int
    /// 0-200 = -100%〜+100%（100 = ±0）
    public var arpGateTime: Int
    /// 0 = 弾いた強さを使う / 1-127 = 固定
    public var arpVelocity: Int
    /// 1-100 (%) — 音が鳴る確率。落とすと人力っぽい揺れが出る
    public var arpChance: Int

    // ── Chord ──
    /// 0-31 = Preset01-32 / 32-63 = User01-32
    public var chordSet: Int
    /// 0-100（0 = 同時、上げるほどジャラン）
    public var strumTime: Int
    /// 0=Up 1=Down 2=Up&Down 3=Random 4=Velocity（強さで向きが変わる）
    public var strumDirection: Int

    /// 実機の初期状態に合わせた既定（Scene "CREO" の実測値）。
    ///
    /// ただし **chordSet だけは User01（32）を既定にする**（mako 2026-08-04）—
    /// ladyland から中身を触れるのは User セットだけ（Preset は機器内蔵で
    /// Global Dump に含まれない）ので、Preset1 で始まると設定タブを開いても
    /// 中身が読めない状態になる
    public init(
        arpMode: Int = 0, arpRate: Int = 7, arpOctave: Int = 0,
        arpLatch: Bool = false, arpKeySync: Bool = true,
        arpSwing: Int = 0, arpGateTime: Int = 100,
        arpVelocity: Int = 0, arpChance: Int = 100,
        chordSet: Int = 32, strumTime: Int = 0, strumDirection: Int = 0
    ) {
        self.arpMode = arpMode
        self.arpRate = arpRate
        self.arpOctave = arpOctave
        self.arpLatch = arpLatch
        self.arpKeySync = arpKeySync
        self.arpSwing = arpSwing
        self.arpGateTime = arpGateTime
        self.arpVelocity = arpVelocity
        self.arpChance = arpChance
        self.chordSet = chordSet
        self.strumTime = strumTime
        self.strumDirection = strumDirection
    }

    // ── 表示用の名前（GUI と実機で同じ呼び名にする）──

    public static let arpModeNames = [
        "Up", "Down", "Up-Down", "Down-Up", "Play", "Random", "Trigger",
    ]
    public static let arpRateNames = [
        "1/1", "1/2", "1/3", "1/4", "1/6", "1/8", "1/12", "1/16", "1/24", "1/32", "1/48", "1/64",
    ]
    public static let strumDirectionNames = ["Up", "Down", "Up&Down", "Random", "Velocity"]

    /// Chord Set の呼び名（0-31 = Preset / 32-63 = User）
    public static func chordSetName(_ value: Int) -> String {
        value < 32 ? "Preset\(value + 1)" : "User\(value - 31)"
    }
}

extension Keystage {
    /// 設定を Scene Dump に焼き込む（純関数 — 元は壊さない）。
    /// **Dump の他のバイトには触らない** — ノブ割当やシーン名を巻き添えにしない
    public static func applying(_ settings: KeystageSettings, to dump: [UInt8]) -> [UInt8] {
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> UInt8 {
            UInt8(min(max(value, range.lowerBound), range.upperBound))
        }
        var out = dump
        let writes: [(Int, UInt8)] = [
            (SceneOffset.arpMode, clamp(settings.arpMode, 0...6)),
            (SceneOffset.arpRate, clamp(settings.arpRate, 0...11)),
            (SceneOffset.arpOctave, clamp(settings.arpOctave, 0...3)),
            (SceneOffset.arpLatch, settings.arpLatch ? 1 : 0),
            (SceneOffset.arpKeySync, settings.arpKeySync ? 1 : 0),
            (SceneOffset.arpSwing, clamp(settings.arpSwing, 0...100)),
            (SceneOffset.arpGateTime, clamp(settings.arpGateTime, 0...200)),
            (SceneOffset.arpVelocity, clamp(settings.arpVelocity, 0...127)),
            (SceneOffset.arpChance, clamp(settings.arpChance, 1...100)),
            (SceneOffset.chordSetNum, clamp(settings.chordSet, 0...63)),
            (SceneOffset.strumTime, clamp(settings.strumTime, 0...100)),
            (SceneOffset.strumDirection, clamp(settings.strumDirection, 0...4)),
        ]
        for (offset, value) in writes where out.indices.contains(offset) {
            out[offset] = value
        }
        return out
    }

    /// Scene Dump から設定を読む（起動時の初期値用）。
    /// 短すぎる Dump なら nil
    public static func settings(from dump: [UInt8]) -> KeystageSettings? {
        guard dump.indices.contains(SceneOffset.strumDirection) else { return nil }
        return KeystageSettings(
            arpMode: Int(dump[SceneOffset.arpMode]),
            arpRate: Int(dump[SceneOffset.arpRate]),
            arpOctave: Int(dump[SceneOffset.arpOctave]),
            arpLatch: dump[SceneOffset.arpLatch] != 0,
            arpKeySync: dump[SceneOffset.arpKeySync] != 0,
            arpSwing: Int(dump[SceneOffset.arpSwing]),
            arpGateTime: Int(dump[SceneOffset.arpGateTime]),
            arpVelocity: Int(dump[SceneOffset.arpVelocity]),
            arpChance: Int(dump[SceneOffset.arpChance]),
            chordSet: Int(dump[SceneOffset.chordSetNum]),
            strumTime: Int(dump[SceneOffset.strumTime]),
            strumDirection: Int(dump[SceneOffset.strumDirection]))
    }
}
