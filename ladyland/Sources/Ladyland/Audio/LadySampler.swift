//! **8 パッドのワンショットサンプラー**（mako 要望 2026-08-05
//! 「LPD8 の 3Program に、サンプラーを設定しよう。シンプルなワンショットで
//! 8pad に音声ファイル割り当てて、右の 8 個のつまみは、それぞれの Vol」）。
//!
//! Lady MPE と同じくプロセス内登録（`AUAudioUnit.registerSubclass`）なので、
//! 既存のカタログに並んで普通のトラックとして載る。
//!
//! ## パッドとノブの対応
//!
//! LPD8 はプログラムごとに番号をばらしてある（`Lpd8DefaultPadNotes`）。
//! **受けたノート番号から位置（0-7）を引く**ので、PROG 1-3 のどれでも鳴る
//! （PROG 4 はプラグイン選択に使うので ladyland が横取りしていて届かない）。
//!
//! | | |
//! |---|---|
//! | パッド | Note On で **Play / Pause**（止めた位置から再開。押している長さとは無関係） |
//! | ノブ | そのスロットの音量。CC 番号も `Lpd8DefaultKnobCCs` から引く |
//!
//! ⚠️ ノブの CC が ladyland の顔つまみに割り当てられていると**横取りされて
//! ここへ届かない**。サンプラーを使うプログラムのノブは割り当てないこと。

import AVFoundation
import AppKit
import Foundation
import SwiftUI

/// 8 パッドのワンショットサンプラー
final class LadySampler: AUAudioUnit, @unchecked Sendable {
    static let componentSubType: OSType = 0x6C647370  // 'ldsp'
    static let componentManufacturer: OSType = 0x4348524E  // 'CHRN'
    static let displayName = "Lady Sampler"

    /// パッドの数（LPD8 に合わせる）
    static let padCount = 8

    /// **音量の CC**（mako 指定「cc57-64 を順にそれぞれのボリュームに対応させて」）。
    /// CC57 → pad 1、CC64 → pad 8。
    ///
    /// ⚠️ **実機がこの帯を送るよう設定されている**（実測 2026-08-06 のログ:
    /// `LPD8 CC57 = 30 → drums (Lady Sampler)`）。一度「LPD8 の既定 CC と
    /// 一致しないから」と位置引きへ寄せたが、**見ていたのは ladyland の既定値**で、
    /// 実機の設定ではなかった。実機の帯を第一に受ける
    static let volumeCCs = 57...64

    /// **パッドの CC**（実測 2026-08-06: 実機の PROG 3 は CC モードで `CC49-56`）。
    /// CC49 → pad 1、CC56 → pad 8
    static let padTriggerCCs = 49...56

    /// **パッドの Note**（実測 2026-08-06: 実機の PROG 3 は `36-43`）。
    static let padTriggerNotes: ClosedRange<Int> = 36...43

    /// Note からパッド位置（0-7）を引く。
    ///
    /// ⚠️ **上下段が CC とは逆順に並ぶ**（実測 2026-08-06: mako「Note の方が
    /// 上下逆だね」）。LPD8 は **大きい番号が上段**なので:
    ///
    /// ```
    /// 上段（pad 1-4） = Note 40-43     CC 49-52
    /// 下段（pad 5-8） = Note 36-39     CC 53-56
    /// ```
    ///
    /// CC は小さい番号が上段なので素直に引けるが、Note は**段を入れ替える**必要がある。
    /// `Lpd8DefaultPadNotes`（規約側）も `[44,45,46,47, 40,41,42,43]` と
    /// 上段を先に並べていて、同じ規則になっている
    static func padIndex(forNote note: Int) -> Int? {
        guard padTriggerNotes.contains(note) else { return nil }
        let offset = note - padTriggerNotes.lowerBound  // 0-7
        return offset >= 4 ? offset - 4 : offset + 4
    }

    /// **不変条件: メモリ上のバッファは、常にいまのエンジンのレートに対応済み**
    /// （mako 設計 2026-08-06）。
    ///
    /// 対応していないバッファは**存在しない** — 作り直している最中は `nil`、
    /// つまり「まだ無い」として扱い、鳴らさない。デバイスを切り替えた直後に
    /// 一瞬鳴らなくなるが、**古いレートの音を鳴らす方が間違い**（音程がずれる）。
    ///
    /// これで実行時のレート比（`step = 素材レート / 出力レート`）が構造から消える。
    /// あの比は「Zenith 2 を 192kHz にした瞬間に 4.35 倍速」バグ族の温床だった。
    ///
    /// ⚠️ **上限判定は入れない**（mako 裁定）。6 分の現場録音は mono Float32 で
    /// 44.1kHz なら約 63.5MB、192kHz へ展開すると約 277MB、8 席全部なら約 2.2GB。
    /// この数字を見た上で閾値フォールバックを**入れないと決めた** —
    /// 入れた瞬間に不変条件が嘘になるから。将来ここが効いたときの逃げ道は
    /// フォールバックのリサンプラではなく**ディスクストリーミング**
    /// （そちらなら不変条件を壊さずに済む）
    private struct PreparedSample {
        /// エンジンのレートへ変換済みの mono Float32
        var frames: [Float]
        /// このバッファが対応しているレート。**`engineRate` と必ず一致する**
        var rate: Double
        /// **波形を描くためのピーク包絡**（`PeakEnvelope`）。
        ///
        /// ⚠️ **ここに持たせるのが要点** — この型は「エンジンに対応済みの
        /// データ」という不変式を背負っている。**レートが変わって再変換されれば
        /// 包絡も一緒に作り直される**。別に持つと、片方だけ古いまま残る
        var envelope: PeakEnvelope
    }

    /// **波形の縮小表現**（min/max のバケット）。
    ///
    /// ⚠️ **生波形は描けない。** 192kHz の 32 分素材は約 3.7 億フレームで、
    /// 毎フレームなめるのは不可能。**固定数のバケットへ畳んで 1 回だけ作る**。
    ///
    /// `2048 × 2 × 4 byte = 16KB` — 素材が何分でもこの大きさで変わらない
    struct PeakEnvelope: Equatable {
        /// バケットごとの最小値（-1...0 側）
        var lows: [Float]
        /// バケットごとの最大値（0...1 側）
        var highs: [Float]

        var isEmpty: Bool { lows.isEmpty }

        /// ⚠️ **素材の長さによらず一定**。ここが可変だと描画側が毎回
        /// 幅を計算し直すことになり、席ごとに違う密度の波形が並ぶ
        static let bucketCount = 2048

        /// 変換済みフレームから 1 回だけ作る。
        /// ⚠️ **呼ぶのは変換と同じ非同期の中**。UI の初回描画で作ると、
        /// そこで一瞬固まる
        static func make(_ frames: [Float]) -> PeakEnvelope {
            guard !frames.isEmpty else { return PeakEnvelope(lows: [], highs: []) }
            var lows = [Float](repeating: 0, count: bucketCount)
            var highs = [Float](repeating: 0, count: bucketCount)
            // ⚠️ **フレームが少なくても割り切れる形にする**（1 未満にしない）
            let per = max(1, frames.count / bucketCount)
            for bucket in 0..<bucketCount {
                let start = bucket * per
                guard start < frames.count else { break }
                let end = min(frames.count, start + per)
                var low: Float = 0
                var high: Float = 0
                for index in start..<end {
                    let value = frames[index]
                    if value < low { low = value }
                    if value > high { high = value }
                }
                lows[bucket] = low
                highs[bucket] = high
            }
            return PeakEnvelope(lows: lows, highs: highs)
        }
    }

    /// 席ごとの変換済みバッファ。**`nil` = まだ無い**（未割当 or 作り直し中）。
    /// **レンダースレッドから読む**ので、差し替えはロックで守る
    private var prepared = [PreparedSample?](repeating: nil, count: padCount)
    /// **後段エフェクト 4 段の on/off**（mako 裁定 2026-08-06「CC の方はその
    /// プラグインの後にかけるエフェクトを切り替えるのに使う」）。
    ///
    /// 実体（`AVAudioUnitEffect`）はホスト側にある — AU の中からは自分の後段に
    /// 手が届かない。**状態はここが持ち**、ホストが読んで `bypass` に反映する。
    /// 画面もここを読むので、実機・ホスト・画面の 3 者が同じ 1 つを見る。
    ///
    /// ⚠️ **読むときもロックを取ること**（`effectStates()`）。書くのは実機の
    /// パッド = CoreMIDI の高優先度スレッド、読むのは main とホスト。
    /// 素の配列を直に読むと**書いている最中を掴む**
    private var effectsEnabled = [Bool](repeating: false, count: effectCount)

    /// 4 段の on/off を **ロック 1 回**で読む（ホストと画面が使う）
    func effectStates() -> [Bool] {
        var states = [Bool](repeating: false, count: Self.effectCount)  // 確保は lock の外
        lock.lock()
        for index in 0..<Self.effectCount { states[index] = effectsEnabled[index] }
        lock.unlock()
        return states
    }

    /// 後段エフェクトの段数（Delay / Reverb / Distortion / Filter）
    static let effectCount = 4

    // MARK: - リアルタイム経路の控え

    /// **パッドを叩いた結果**。記録する理由は 918472e（「無音の理由をログに出す」）
    /// と同じ — 変えたのは**出す場所だけ**で、内容は 1 つも減らしていない
    enum PadEvent: UInt8 {
        case none = 0
        /// 席が空だった（音が入っていない）
        case empty
        /// 鳴っていたので**一時停止**した（位置は残る）
        case paused
        /// 鳴らしはしたが音量がほぼ 0 — ノブを上げる必要がある
        case silent
        /// CC モードで叩かれたが予備のパッド（FX は 1-4 だけ）
        case reserved
    }

    /// ⚠️ **リアルタイム経路では NSLog を呼ばない**（2026-08-06）。
    ///
    /// MIDI は CoreMIDI の高優先度スレッドから `scheduleMIDIEventBlock` 経由で
    /// ここまで一直線に届く（`MIDIInput.swift` の read block は main へホップ
    /// しない）。そこで NSLog を呼ぶと 3 つ起きる:
    ///
    /// 1. 書式化で malloc が走る（`LadySynth.swift` の
    ///    「**確保・解放をしないこと**」に反する）
    /// 2. **stderr は `DebugLog` がパイプに差し替えている** — 読み手が追いつかず
    ///    バッファが埋まれば `write(2)` はそこでブロックする
    /// 3. `trigger` は **lock を握ったまま**呼んでいた。その lock は
    ///    `render` も待つ — つまり**ログを書いている間オーディオが止まる**
    ///
    /// 控えは固定長の配列に `UInt8` を書くだけ（確保なし）。文字列にするのは
    /// `drainEvents()` を呼ぶ側
    private var padEvents = [UInt8](repeating: 0, count: padCount)
    /// `silent` のときの音量（メッセージに出すため）
    private var padEventGains = [Float](repeating: 0, count: padCount)

    /// 溜まった控えを人が読む文字列にして返し、控えを空にする。
    /// **リアルタイム経路の外から呼ぶこと** — ここで初めて確保が起きる。
    ///
    /// 同じ席で続けて起きたことは**最後の 1 つだけ**残る。溜める器を持たない
    /// 代わりに確保も上限管理も要らない — 切り分けたいのは「**今**叩いたのに
    /// なぜ鳴らないか」なので、最後の 1 つで足りる
    func drainEvents() -> [String] {
        // ⚠️ **入れ物は lock の外で用意する**。`map` や配列の作り直しを lock 内で
        // やると、そのぶんオーディオのレンダースレッドが待つ
        var events = [UInt8](repeating: 0, count: Self.padCount)
        var eventGains = [Float](repeating: 0, count: Self.padCount)

        lock.lock()
        for pad in 0..<Self.padCount {
            events[pad] = padEvents[pad]
            eventGains[pad] = padEventGains[pad]
            padEvents[pad] = 0
        }
        lock.unlock()

        var messages: [String] = []
        for pad in 0..<Self.padCount {
            switch PadEvent(rawValue: events[pad]) ?? .none {
            case .none:
                continue
            case .empty:
                messages.append("sampler: pad \(pad + 1) は空 — 音が入っていない")
            case .paused:
                messages.append("sampler: pad \(pad + 1) を一時停止（位置は残る）")
            case .silent:
                let percent = Int((eventGains[pad] * 100).rounded())
                messages.append(
                    "sampler: pad \(pad + 1) は鳴らすが音量 \(percent)% — ノブ K\(pad + 1) を上げる")
            case .reserved:
                messages.append("sampler: pad \(pad + 1) は予備（エフェクトは 1-4）")
            }
        }
        return messages
    }

    // MARK: - render コストの控え

    /// 控え（`RenderStats` の説明。**加算と max だけ**、確保も割り算もしない）
    private var renderCalls: UInt64 = 0
    private var renderTotalNs: UInt64 = 0
    private var renderMaxNs: UInt64 = 0
    private var renderFrameCount: UInt32 = 0
    /// **出したフレームの累積**（実測レートの分子）。
    /// ⚠️ RT 経路に足したのは**この加算 1 つだけ**（`RenderStats` の説明）
    private var renderFrames: UInt64 = 0
    /// 前回ドレインした時刻。**実経過を測る**ため（0.5 秒と決め打ちしない）
    private var renderDrainedAt: UInt64 = 0

    /// ⚠️ **lock を持ったまま呼ぶこと**（`render` の defer から）
    private func recordRenderLocked(startNs: UInt64, frameCount: AUAudioFrameCount) {
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNs
        renderCalls &+= 1
        renderTotalNs &+= elapsed
        if elapsed > renderMaxNs { renderMaxNs = elapsed }
        renderFrameCount = UInt32(frameCount)
        renderFrames &+= UInt64(frameCount)  // ← 実測レートの分子（加算 1 つ）
    }

    /// エフェクトの切替をホストへ知らせる（bypass の反映を頼む）
    var onEffectsChanged: (() -> Void)?

    /// パッド（CC モード）でエフェクトをトグルする。
    /// **1-4 が 4 段に対応**、5-8 は今のところ予備
    private func toggleEffect(_ index: Int) {
        guard (0..<Self.effectCount).contains(index) else {
            lock.lock()
            if (0..<Self.padCount).contains(index) {
                padEvents[index] = PadEvent.reserved.rawValue
            }
            lock.unlock()
            return
        }
        lock.lock()
        effectsEnabled[index].toggle()
        lock.unlock()
        // ⚠️ **ここでログを出さない** — 呼ばれているのは CoreMIDI の高優先度
        // スレッド（下記 `padEvents`）。入り切りの結果はホスト側
        // （`applySamplerEffects`）が main で出す。
        //
        // ⚠️ この通知だけは残す（`Task` の確保が 1 回走る）。**画面を閉じていても
        // FX は効かなければならない**ので、画面の毎フレーム読みに寄せると
        // 機能が壊れる — 確保 1 回と機能、天秤にかけて機能を採る
        onEffectsChanged?()
    }

    /// **音を差し替えたことをホストへ知らせる**（重い保存の引き金。実測 2026-08-06）。
    ///
    /// ホストが `fullState` を取り直すのは「プラグイン画面を閉じた」「終了時」
    /// 「draft 操作」の 3 つだけ。**この画面は focus pane に常設されて閉じないので、
    /// 割り当てても記録されずに消えていた**。ホストが察する術は無いので自分で言う
    var onSamplesChanged: (() -> Void)?

    /// **元データの素性**（mako 要望 2026-08-06「これ元のデータの情報表示できる？」）。
    ///
    /// 「音が間延びしている」を目で切り分けるための表示。**元のレートと、
    /// いま対応済みのレートを並べて出す**のが肝 — 間延びは片方だけ見ても
    /// 分からず、**比**でしか判断できない。K1 と K3 でフォーマットが違う、
    /// のような食い違いもここで見える
    struct SampleInfo: Equatable {
        /// 元ファイルのサンプルレート
        var sourceRate: Double
        /// 元ファイルのチャンネル数
        var sourceChannels: Int
        /// 元ファイルの長さ（秒）
        var sourceDuration: Double
        /// 元ファイルのフレーム数
        var sourceFrames: Int
        /// 拡張子（`wav` / `aiff` / `m4a` …）
        var fileType: String

        /// **元ファイルのビット深度**（16 / 24 / 32 …）。
        ///
        /// ⚠️ **`processingFormat` からは取れない** — あれは常にデコード後の
        /// Float32 なので、どのファイルでも 32 と答える。ディスク上の形式
        /// （`fileFormat`）から取る必要がある。
        ///
        /// ⚠️ **圧縮（m4a / mp3 / aac）は 0 になる**。ビット深度という概念が
        /// 無いので、`0bit` と書かずに別表記にする（`isCompressed`）
        var sourceBits: Int

        /// 元ファイルが**浮動小数**か（`32bit` と `32bit float` は別物）。
        /// mako は 32bit のリグで回しているのでこの区別に意味がある
        var sourceIsFloat: Bool

        /// 圧縮フォーマットか（ビット深度が意味を持たない）
        var isCompressed: Bool { sourceBits == 0 }

        /// 人が読む形式表記。**圧縮なら拡張子を出す**（`0bit` とは書かない）
        var formatLabel: String {
            guard !isCompressed else { return fileType }
            return sourceIsFloat ? "\(sourceBits)bit float" : "\(sourceBits)bit"
        }
        /// 変換後のフレーム数（メモリ上の実体）
        var preparedFrames: Int
        /// 変換後のレート = **このバッファが対応しているレート**
        var preparedRate: Double

        /// メモリ上の実サイズ（mono Float32）
        var bytes: Int { preparedFrames * MemoryLayout<Float>.size }

        /// **元と変換後でレートが違ったか**（＝ SRC がかかったか）
        var wasResampled: Bool { sourceRate != preparedRate }
    }

    /// 席ごとの素性（表示用。**作り直し中も残す** — 何が入っていたかは消さない）
    private(set) var sampleInfos = [SampleInfo?](repeating: nil, count: padCount)

    /// 読み込んだファイル名（UI 表示用）
    private(set) var sampleNames = [String?](repeating: nil, count: padCount)
    /// 読み込み元の URL（**保存と復元に要る** — `fullState` が持つのはこちら）
    private(set) var sampleURLs = [URL?](repeating: nil, count: padCount)
    /// スロットごとの音量（0...1）
    private var gains = [Float](repeating: 0.8, count: padCount)

    /// **再生位置**（0 = 頭）。⚠️ **常に有効な位置**であって停止の印ではない
    /// （mako 要望 2026-08-06「止めた位置から再生になる」）。
    ///
    /// ⚠️ **`Int` で足りる**（2026-08-06 の設計変更）。以前は `Double` で
    /// レート比の歩幅を進めていたが、**バッファが常にエンジンのレートに
    /// 揃っている**ので歩幅は 1 に決まった（`prepared` の不変条件）
    private var positions = [Int](repeating: 0, count: padCount)

    /// **いま鳴っているか**。`positions` から独立させた片割れ —
    /// 以前は `-1` を「停止」の印に兼用していたので、止めると**位置ごと捨てて**
    /// いた（次に叩くと頭から鳴っていた）。分けたことで一時停止に位置が残る
    private var playing = [Bool](repeating: false, count: padCount)

    /// **いまエンジンが render を回しているレート**。
    ///
    /// ⚠️ **デバイスのレートではない**（実測 2026-08-06、mako「音が間延びしてる」）。
    /// `init` で出力バスを 44.1kHz に固定していて、`InstrumentRack` は
    /// `format: nil` で繋ぐので、**エンジンはこのバスの形式で render を回す**。
    /// 一方でホストは `engine.outputNode` のレート（Zenith 2 なら 192kHz）を
    /// 渡してきていた — 食い違ったぶんがそのまま速度のずれになり、
    /// **192k 素材だけが偶然正しく鳴る**状態になっていた。
    ///
    /// 真の値は `outputBus.format.sampleRate`。ここが唯一の源
    private var engineRate: Double = 44100

    private let lock = NSLock()

    private var outputBus: AUAudioUnitBus
    private var busArray: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }

    override var outputBusses: AUAudioUnitBusArray { busArray }

    /// **エンジンのレートを取り直す**（ホストから合図をもらったとき）。
    ///
    /// ⚠️ 引数を取らないのが肝（2026-08-06 の設計変更）。以前はホストが
    /// `engine.outputNode` のレートを渡していたが、**それは render が回る
    /// レートではない** — 真の値は自分の出力バスにある（`engineRate` の説明）。
    /// ホストは「変わったかもしれない」とだけ言い、値は自分で読む。
    ///
    /// ⚠️ `engine.stop()` → `start()` では `allocateRenderResources` が
    /// 呼ばれ直さないので、この合図が要る
    func refreshEngineRate() {
        applyEngineRate(outputBus.format.sampleRate)
    }

    /// レートが変わったら**全部作り直す**。
    /// 作り直しが終わるまで、そのパッドは「まだ無い」= 鳴らない
    private func applyEngineRate(_ rate: Double) {
        guard rate > 0 else { return }
        lock.lock()
        let changed = engineRate != rate
        if changed {
            engineRate = rate
            // ⚠️ **不変条件が破れている間は鳴らさない**。古いレートのバッファを
            // 鳴らすのは「間違った音程で鳴らす」こと。無音の方が正しい
            for pad in 0..<Self.padCount {
                prepared[pad] = nil
                positions[pad] = 0
                playing[pad] = false
            }
        }
        lock.unlock()
        guard changed else { return }
        NSLog("sampler: エンジン %.0f Hz — 全パッドを作り直す（それまで鳴らない）", rate)
        reprepareAll(to: rate)
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        // ⚠️ **ここが唯一の源**。デバイスのレートと食い違うことがある
        // （エンジンが SRC を挟むため）ので、両方をログに出して突き合わせられるようにする
        applyEngineRate(outputBus.format.sampleRate)
        NSLog("sampler: 出力バス %.0f Hz で render が回る", outputBus.format.sampleRate)
    }

    // MARK: - 音の読み込み

    /// 音声ファイルをスロットへ読み込む（**メインスレッドから。RT では絶対に呼ばない**）。
    ///
    /// **読み込んだ時点でエンジンのレートへ変換して持つ**（不変条件。`prepared`）。
    /// 変換は `AVAudioConverter` — 帯域制限のあるまともな SRC なので、
    /// 192k 素材を 48k で鳴らしても折り返さない（以前の線形補間は折り返していた）。
    /// モノラル化も変換器に任せる（出力は左右へ同じものを流す）
    func loadSample(slot: Int, url: URL) throws {
        guard (0..<Self.padCount).contains(slot) else { return }
        lock.lock()
        let rate = engineRate
        lock.unlock()

        let (frames, info) = try Self.prepare(url: url, to: rate)
        install(slot: slot, frames: frames, rate: rate, url: url, info: info)
        NSLog(
            "sampler: pad %d に %@（元 %.0f Hz / %d ch / %.2f 秒）→ %.0f Hz へ変換して %d サンプル",
            slot + 1, url.lastPathComponent, info.sourceRate, info.sourceChannels,
            info.sourceDuration, rate, frames.count)
        onSamplesChanged?()  // ここが音の節目 — ホストに保存させる
    }

    /// 変換済みバッファを席へ据える。
    ///
    /// ⚠️ **古い音の解放を lock の外へ出す**。差し替えは直前の配列
    /// （6 分の現場録音なら数十〜数百 MB）をその場で解放する — 解放は
    /// `free(3)` まで降りるので、**待っているレンダースレッドがそのぶん止まる**。
    /// 参照を 1 本持ち上げておけば、実際の解放は `unlock` の後になる
    private func install(
        slot: Int, frames: [Float], rate: Double, url: URL, info: SampleInfo
    ) {
        // ⚠️ **ロックの外で作る** — 3.7 億フレームを畳む間ロックを持っていたら
        // レンダースレッドがそのぶん止まる
        let envelope = PeakEnvelope.make(frames)
        let previous: PreparedSample?
        lock.lock()
        previous = prepared[slot]
        // ⚠️ **据える直前にレートを確かめる**。変換中にデバイスが変わっていたら、
        // これは既に古い — 据えたら不変条件が破れる
        if rate == engineRate {
            prepared[slot] = PreparedSample(
                frames: frames, rate: rate, envelope: envelope)
        }
        // 差し替えたら頭出しして止める（古い位置で新しい音を読まない）
        positions[slot] = 0
        playing[slot] = false
        lock.unlock()
        withExtendedLifetime(previous) {}  // ここまで生かす = 解放は lock の外

        sampleNames[slot] = url.deletingPathExtension().lastPathComponent
        sampleURLs[slot] = url  // 復元に要る（`fullState` が持つのはこちら）
        sampleInfos[slot] = info
    }

    /// 全席を新しいレートへ作り直す。
    /// **バックグラウンドで回す** — 変換は数百 MB を触るので main も RT も塞げない
    private func reprepareAll(to rate: Double) {
        let urls = sampleURLs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (slot, url) in urls.enumerated() {
                guard let self, let url else { continue }
                // 途中でまたレートが変わったら、この作り直しは無駄なのでやめる
                self.lock.lock()
                let current = self.engineRate
                self.lock.unlock()
                guard current == rate else { return }

                do {
                    let (frames, info) = try Self.prepare(url: url, to: rate)
                    self.install(slot: slot, frames: frames, rate: rate, url: url, info: info)
                } catch {
                    NSLog(
                        "sampler: ⚠️ pad %d の作り直しに失敗 — %@（%@）",
                        slot + 1, url.lastPathComponent, error.localizedDescription)
                }
            }
            NSLog("sampler: %.0f Hz への作り直しが終わった", rate)
        }
    }

    /// **ファイルを `rate` の mono Float32 へ変換する**（オフライン専用）。
    ///
    /// ⚠️ **RT スレッドから絶対に呼ばない**。ファイル I/O と数百 MB の確保をする。
    ///
    /// ⚠️ `AVAudioConverter.convert(to:from:)` の**一発版はレート変換に使えない**
    /// （同レートのフォーマット変換専用で、レートが違うと落ちる）。
    /// ブロック版をループで回す
    private static func prepare(url: URL, to rate: Double) throws -> ([Float], SampleInfo) {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        let sourceFrames = AVAudioFrameCount(file.length)

        // ⚠️ **ビット深度はディスク上の形式から取る**。`processingFormat` は
        // 常にデコード後の Float32 なので、どのファイルでも 32 と答えてしまう
        let onDisk = file.fileFormat.streamDescription.pointee
        let bits = Int(onDisk.mBitsPerChannel)  // 圧縮なら 0
        let isFloat = onDisk.mFormatFlags & kAudioFormatFlagIsFloat != 0
        // レートは両者一致するはずだが、食い違うならディスク上の値が正
        let sourceRate = file.fileFormat.sampleRate > 0
            ? file.fileFormat.sampleRate : source.sampleRate
        if abs(file.fileFormat.sampleRate - source.sampleRate) > 1 {
            NSLog(
                "sampler: ⚠️ %@ のレートが食い違う — file %.0f / processing %.0f（file 側を採る）",
                url.lastPathComponent, file.fileFormat.sampleRate, source.sampleRate)
        }

        var info = SampleInfo(
            sourceRate: sourceRate,
            sourceChannels: Int(source.channelCount),
            sourceDuration: sourceRate > 0 ? Double(file.length) / sourceRate : 0,
            sourceFrames: Int(file.length),
            fileType: url.pathExtension.lowercased(),
            sourceBits: bits,
            sourceIsFloat: isFloat,
            preparedFrames: 0,
            preparedRate: rate)
        guard sourceFrames > 0 else { return ([], info) }

        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: sourceFrames) else {
            throw SamplerError.bufferAllocation
        }
        try file.read(into: input)

        // ⚠️ **同レートなら変換器を通さない**（mako 指示 2026-08-06）。
        // 192k 素材を 192k のバスへ載せるのに `AVAudioConverter` を挟むのは
        // 無駄なうえ、無害とも限らない（実装依存の遅延やゲイン差が入りうる）。
        // ここで要るのはチャンネルの畳み込みだけ
        if source.sampleRate == rate {
            var mono = [Float](repeating: 0, count: Int(input.frameLength))
            if let channels = input.floatChannelData {
                let count = Int(source.channelCount)
                for frame in 0..<Int(input.frameLength) {
                    var sum: Float = 0
                    for channel in 0..<count { sum += channels[channel][frame] }
                    mono[frame] = sum / Float(count)
                }
            }
            info.preparedFrames = mono.count
            return (mono, info)
        }

        // 変換先は **mono Float32 / エンジンのレート**。チャンネルの畳み込みも
        // 変換器に任せる（自前で足して割るより、レイアウトに沿った混ぜ方をする）
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target)
        else { throw SamplerError.converterUnavailable }

        // 出力の見積もりは切り上げ + 余白（変換器は端数を返すことがある）
        let ratio = rate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(sourceFrames) * ratio).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SamplerError.bufferAllocation
        }

        var out = [Float]()
        out.reserveCapacity(Int(capacity))
        var fed = false
        var failure: NSError?

        while true {
            output.frameLength = 0
            let status = converter.convert(to: output, error: &failure) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return input
            }
            if let failure { throw failure }
            if output.frameLength > 0, let channel = output.floatChannelData {
                out.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channel[0], count: Int(output.frameLength)))
            }
            // `.haveData` でも 0 フレームなら進んでいない — 無限ループを避ける
            guard status == .haveData, output.frameLength > 0 else { break }
        }

        info.preparedFrames = out.count
        return (out, info)
    }

    enum SamplerError: Error {
        case bufferAllocation
        case converterUnavailable
    }

    /// スロットを空にする
    func clearSample(slot: Int) {
        guard (0..<Self.padCount).contains(slot) else { return }
        let previous: PreparedSample?  // 解放は lock の外で（`install` と同じ理由）
        lock.lock()
        previous = prepared[slot]
        prepared[slot] = nil
        positions[slot] = 0
        playing[slot] = false
        lock.unlock()
        withExtendedLifetime(previous) {}
        sampleNames[slot] = nil
        sampleURLs[slot] = nil
        sampleInfos[slot] = nil
        onSamplesChanged?()
    }

    // MARK: - 保存と復元

    private static let urlsKey = "club.chronista.ladyland.sampler.urls"
    private static let gainsKey = "club.chronista.ladyland.sampler.gains"

    /// **他のプラグインと同じ `fullState` の経路に乗る**（mako 指摘 2026-08-06
    /// 「他のプラグイン同様に設定の永続化と復元がいるね」）。
    ///
    /// ラックの保存は `InstrumentRack` が `fullState` をキャッシュして Snapshot へ
    /// 書くので、ここを実装するだけで**常時保存にも音色ドラフトにも乗る**。
    ///
    /// ⚠️ **音そのものは載せない — URL と音量だけ**。数十 MB の PCM を Snapshot に
    /// 入れると保存のたびに重くなるし、元ファイルを差し替えたら次の読み込みで
    /// 反映されるのが自然（サンプラーは「元の音を指す」道具）
    override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            lock.lock()
            let savedGains = gains.map { Double($0) }
            lock.unlock()
            state[Self.urlsKey] = sampleURLs.map { $0?.absoluteString ?? "" }
            state[Self.gainsKey] = savedGains
            return state
        }
        set {
            super.fullState = newValue
            guard let newValue else { return }

            if let restored = newValue[Self.gainsKey] as? [Double] {
                lock.lock()
                for (slot, value) in restored.enumerated() where slot < Self.padCount {
                    gains[slot] = Float(value)
                }
                lock.unlock()
            }

            guard let urls = newValue[Self.urlsKey] as? [String] else { return }
            for (slot, text) in urls.enumerated() where slot < Self.padCount {
                guard !text.isEmpty, let url = URL(string: text) else { continue }
                // ⚠️ **1 つ失敗しても他を巻き込まない** — ファイルが移動・削除
                // されているのは普通に起きる。その席だけ空で立ち上がる
                do {
                    try loadSample(slot: slot, url: url)
                } catch {
                    NSLog(
                        "sampler: ⚠️ pad %d の復元に失敗 — %@（%@）",
                        slot + 1, url.lastPathComponent, error.localizedDescription)
                }
            }
        }
    }

    /// 音量を読む（UI 表示用）
    func gain(slot: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return (0..<Self.padCount).contains(slot) ? gains[slot] : 0
    }

    /// **席の準備状態**（mako 要望 2026-08-06「なぜ鳴らないかが画面で分かること」）。
    ///
    /// 3 値の形は **club-nostos（chronista-club の Rust crate）の
    /// `Outcome<Done, Reborn, Failed>`** から語彙だけ借りた
    /// （パッケージ化も依存の追加もしていない）。
    ///
    /// 借りたのは **`Reborn`** — 「終わっていないが、変化した。**ここから
    /// 再開せよ**」という `Result` に無い第三の腕で、**再開点を値として運ぶ**のが肝。
    ///
    /// ここにそのまま当てはまった。以前は「変換中にレートが変わったら捨てる」
    /// と書いていたが、**それは失敗ではなく「新しいレートからやり直し」**。
    /// 目標レートをペイロードで運べば、その区別が型で見えるし、
    /// 画面が「何 Hz へ」と言える
    enum PadReadiness: Equatable {
        /// 空 — 音が入っていない
        case empty
        /// **このレートへ作り直し中**（`Reborn` に当たる。再開点 = 目標レート）
        case preparing(targetRate: Double)
        /// 鳴らせる（エンジンのレートに対応済み = `prepared` の不変条件が成立）
        case ready
    }

    /// 1 席ぶんの見た目（画面が毎フレーム読むもの）
    struct PadState: Equatable {
        var gain: Float = 0
        var loaded = false
        /// **再生位置 0...1**。⚠️ 止めても残る（`nil` にしない）— 一時停止した
        /// 位置がカードと 3D の両方で見えることが、この変更の効き目
        var position: Double = 0
        /// いま鳴っているか。**位置とは別**（一時停止 = 位置あり・非再生）
        var isPlaying = false
        /// **なぜ鳴らないか**が分かる 3 値。`loaded` は `readiness == .ready` と同値
        var readiness: PadReadiness = .empty
    }

    /// 8 席ぶんを **ロック 1 回**でまとめて読む。
    ///
    /// ⚠️ 以前は画面が `gain` / `hasSample` / `progress` を席ごとに呼んでいて、
    /// 60fps × 8 席 × 3 = **毎秒 1440 回**ロックを取っていた。取るのは SceneKit の
    /// レンダースレッドだが、**待たされるのはオーディオのレンダースレッド**
    /// （同じ lock）— 取る回数がそのまま音の詰まりやすさになる
    /// **席ごとの波形包絡**（`nil` = まだ無い）。
    ///
    /// ⚠️ **`padStates()` に混ぜない。** あちらは 60fps で呼ばれるが、包絡は
    /// **変換されたときにしか変わらない**。毎フレーム 8 席ぶんの配列
    /// （2048 × 2 × 8 = 32768 要素）をコピーすることになる。
    ///
    /// 呼ぶ側は**素材が変わったときだけ**取り直す（`SampleInfo` の変化が合図）
    func envelope(pad: Int) -> PeakEnvelope? {
        guard (0..<Self.padCount).contains(pad) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return prepared[pad]?.envelope
    }

    /// **再生位置を動かす**（波形のクリック / ドラッグ）。
    ///
    /// ⚠️ **再生状態を変えない。** 止まっているなら止まったまま、鳴っているなら
    /// そのまま続ける — LED も変わらない（`playing` に触らない）。
    /// 「頭出ししたら鳴り出した」は演奏中に事故になる。
    ///
    /// ⚠️ **render に新しい判定を足していない** — `positions` は render も読むが、
    /// 既存のロックの内側で書き換えるだけ。render 側のコードは 1 行も変えていない
    func seek(pad: Int, to progress: Double) {
        guard (0..<Self.padCount).contains(pad) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let count = prepared[pad]?.frames.count, count > 0 else { return }
        // ⚠️ **端で壊れない** — 0 未満と末尾以上を丸める。
        // `count` ちょうどだと render の `position >= count` に即当たって
        // 頭へ巻き戻るので、最後のフレームで止める
        let clamped = min(max(progress, 0), 1)
        positions[pad] = min(count - 1, Int(Double(count) * clamped))
    }

    func padStates() -> [PadState] {
        // 入れ物は lock の外で確保する（`drainEvents()` と同じ理由）
        var states = [PadState](repeating: PadState(), count: Self.padCount)
        lock.lock()
        for pad in 0..<Self.padCount {
            let count = prepared[pad]?.frames.count ?? 0
            states[pad].gain = gains[pad]
            // **位置は止めても残る**ので、鳴っているかとは別に持つ
            states[pad].position =
                count > 0 ? min(1, Double(positions[pad]) / Double(count)) : 0
            states[pad].isPlaying = playing[pad]
            // **「まだ無い」は loaded ではない** — 作り直し中は鳴らないので、
            // 画面もそう見せる（`prepared` の不変条件）。
            // ⚠️ ただし**空と作り直し中を同じ顔にしない** — デバイス切替直後に
            // 「なぜ鳴らないか」が分からなくなる
            states[pad].loaded = count > 0
            states[pad].readiness =
                count > 0
                ? .ready
                : (sampleURLs[pad] != nil ? .preparing(targetRate: engineRate) : .empty)
        }
        lock.unlock()
        return states
    }

    // MARK: - MIDI

    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        { [weak self] _, _, count, bytes in
            guard let self, count > 0 else { return }
            let kind = bytes[0] & 0xF0
            let data1 = count > 1 ? bytes[1] : 0
            let data2 = count > 2 ? bytes[2] : 0
            switch kind {
            case 0x90 where data2 > 0:
                // **実機の帯を第一に見る**（PROG 3 = Note 36-43、実測 2026-08-06）。
                // 焼いた後の ladyland 規約（`Lpd8DefaultPadNotes`）も引き続き受ける
                if let pad = Self.padIndex(forNote: Int(data1)) {
                    self.trigger(pad: pad)
                } else if let pad = Lpd8DefaultPadNotes.index(of: data1) {
                    self.trigger(pad: pad)
                }
            case 0xB0 where data1 == 123 || data1 == 120:
                // ⚠️ **他の 0xB0 より先に判定する** — 下の枝が 0xB0 を全部拾うので、
                // 後ろに置くと到達しない
                self.stopAll()
            case 0xB0:
                // ⚠️ **パッドは Note とは限らない**（mako 2026-08-06「基本は Pad は、
                // CC モードにしてる想定で」）。LPD8 は本体ボタンで Note / CC / PC を
                // 切り替えるので、**両方拾えばモードに依存しない**。
                //
                // **実機の帯を第一に見る**（CC49-56 パッド / CC57-64 ノブ）。
                // その後に ladyland の番号規約（焼いた場合の 12-48 / 79-117）を見る —
                // どちらの設定でも動くように両方受ける
                let cc = Int(data1)
                if Self.volumeCCs.contains(cc) {
                    self.setGain(
                        slot: cc - Self.volumeCCs.lowerBound, value: Float(data2) / 127)
                } else if let slot = Lpd8DefaultKnobCCs.index(of: data1) {
                    // 焼いた後（PROG ごとの帯）。**位置で引く**ので、どの PROG の
                    // ノブでも位置 0-7 が同じスロットの音量を動かす
                    self.setGain(slot: slot, value: Float(data2) / 127)
                } else if data2 > 0, Self.padTriggerCCs.contains(cc) {
                    // ⚠️ **CC モードのパッドは音を出さない — エフェクトを切り替える**
                    // （mako 裁定 2026-08-06）。実機の PAD/CC ボタンで役割が変わるので、
                    // **同じ 8 パッドが 2 面を持つ**: Note = 再生/STOP、CC = FX
                    self.toggleEffect(cc - Self.padTriggerCCs.lowerBound)
                } else if data2 > 0, let pad = Lpd8DefaultPadCCs.index(of: data1) {
                    self.toggleEffect(pad)
                }
            default:
                break
            }
        }
    }

    /// パッドを叩く。**頭から鳴らし直す**（連打で重ならない — ワンショットの作法）
    /// パッドを叩く。**鳴っていれば止める**（mako 裁定 2026-08-06「Note の方で、
    /// 再生/STOP させて」）。
    ///
    /// 当初は「連打で重ならない = 頭から鳴らし直す」ワンショットの作法にしていたが、
    /// **長尺の素材**（現場録音は 6 分ある）では止める手が要る。短い打楽器なら
    /// 鳴り終わっているので、叩けばそのまま頭から鳴る — どちらの使い方も壊れない
    private func trigger(pad: Int) {
        lock.lock()
        defer { lock.unlock() }
        // ⚠️ **空だったことを言う**（mako 2026-08-06「動いてない？」）。
        // 叩いても無音のとき、届いていないのか席が空なのかを**外から区別できない**。
        //
        // ⚠️ **言うのは控えるところまで** — ここは CoreMIDI の高優先度スレッドで、
        // しかも lock を握っている（`padEvents` の説明）。文字にするのは
        // `drainEvents()` を呼ぶ側
        // **「まだ無い」もここで弾かれる**（作り直し中 = 不変条件が破れている）。
        // 古いレートのバッファを鳴らすくらいなら鳴らさない
        guard let sample = prepared[pad], !sample.frames.isEmpty else {
            padEvents[pad] = PadEvent.empty.rawValue
            return
        }
        // **鳴っていれば止めるだけ — 位置は残す**（Play/Pause）
        if playing[pad] {
            playing[pad] = false
            padEvents[pad] = PadEvent.paused.rawValue
            return
        }
        if gains[pad] < 0.02 {
            padEvents[pad] = PadEvent.silent.rawValue
            padEventGains[pad] = gains[pad]
        }
        // 末尾に居るなら頭から（`render` が鳴り終わりで戻すが、素材を
        // 差し替えて短くなった場合など、範囲外に取り残されることがある）
        if positions[pad] >= sample.frames.count { positions[pad] = 0 }
        playing[pad] = true
    }

    /// 音量を変える（MIDI からも画面からも）
    func setGain(slot: Int, value: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard (0..<Self.padCount).contains(slot) else { return }
        gains[slot] = value
    }

    /// 全席を止める。**ホストが繋ぎ替える前にも呼ぶ** — 鳴らしたまま
    /// バスのフォーマットを変えると、古いレートの音が一瞬漏れる
    func stopAll() {
        lock.lock()
        // ⚠️ **頭出し + 停止**。Play/Pause にするとパッドから「頭に戻す」手段が
        // 無くなるので、All Notes Off（CC123/120）に巻き戻しを兼ねさせる
        for i in positions.indices {
            positions[i] = 0
            playing[i] = false
        }
        lock.unlock()
    }

    // MARK: - レンダー

    override var internalRenderBlock: AUInternalRenderBlock {
        { [weak self] _, _, frameCount, _, outputData, _, _ in
            guard let self else { return kAudioUnitErr_NoConnection }
            // ⚠️ **入口で時刻を取る** — ロックの待ち時間も込みで測りたい。
            // 詰まるとしたらそこなので、抜いてしまうと肝心なものが見えない
            let start = RenderMetering.enabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
            return self.render(
                frameCount: frameCount, outputData: outputData, startNs: start)
        }
    }

    private func render(
        frameCount: AUAudioFrameCount, outputData: UnsafeMutablePointer<AudioBufferList>,
        startNs: UInt64
    ) -> AUAudioUnitStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in buffers { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }

        lock.lock()
        // ⚠️ 控えるのは**ロックを持ったまま**。別に取り直すと 1 ブロックにつき
        // ロック 2 回になる（RT 経路でそれは払いたくない）
        defer {
            if startNs != 0 { recordRenderLocked(startNs: startNs, frameCount: frameCount) }
            lock.unlock()
        }

        for pad in 0..<Self.padCount {
            // **止まっている席と「まだ無い」席は飛ばす**
            // （後者は作り直し中。`prepared` の不変条件）
            guard playing[pad], let sample = prepared[pad]?.frames else { continue }
            var position = positions[pad]
            let gain = gains[pad]
            // ⚠️ **歩幅は 1**。バッファは既にエンジンのレートへ変換済みなので、
            // レート比も線形補間も要らない — **わざと残していない**。
            // 残すと不変条件が破れた時に、静かに間違った音が出る逃げ道になる
            for frame in 0..<Int(frameCount) {
                guard position >= 0, position < sample.count else {
                    // ⚠️ **鳴り終わったら頭へ戻して停止**。末尾で一時停止した
                    // ままにすると、次に叩いても何も起きない席ができる
                    position = 0
                    playing[pad] = false
                    break
                }
                let value = sample[position] * gain
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                        continue
                    }
                    data[frame] += value
                }
                position += 1
            }
            positions[pad] = position
        }
        return noErr
    }

    // MARK: - 画面

    /// **自作 AU に画面を持たせる**。既存の「プラグイン画面を開く」経路
    /// （`PluginEditorWindows`）がそのまま使えるので、他のプラグインと同じ
    /// 操作でファイルを割り当てられる
    override func requestViewController(
        completionHandler: @escaping (NSViewController?) -> Void
    ) {
        // ⚠️ **ここでログを出さない**（mako 苦情 2026-08-07「定期のログは拾いたく
        // ないし増やしたくはない」）。要求も成功も「今も正常」でしかなく、
        // **画面を開くたびに 2 行**流れて本物の事件を押し流していた。
        // 失敗する経路が無いので、黙っていて困らない
        Task { @MainActor in
            let controller = NSHostingController(
                rootView: ThemedRoot { LadySamplerView(sampler: self) })
            // 3D の地形（200pt）を足したぶん縦を広げる
            // ⚠️ **横長**（mako 要望 2026-08-07「まずはよこ長レイアウトにしよう」）。
            // **LPD8 は 4 列 × 2 段の横長**なので、画面もその形の方が実機に忠実。
            //
            // ⚠️ **ノート PC に収まること** — 会場で外部モニターが無い可能性がある。
            // MacBook Air 13" の可視領域は 1470×930（`WindowPlacementTests` の
            // 実測値）なので、900×560 なら余裕で入る
            controller.preferredContentSize = NSSize(width: 900, height: 560)
            completionHandler(controller)
        }
    }

    // MARK: - 登録

    static func register() {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        description.componentSubType = componentSubType
        description.componentManufacturer = componentManufacturer
        description.componentFlags = 0
        description.componentFlagsMask = 0
        AUAudioUnit.registerSubclass(
            LadySampler.self, as: description, name: displayName, version: 1)
    }
}

// MARK: - 計測

extension LadySampler: RenderMetered {
    var meteredName: String { "sampler" }

    /// 控えを読んで**即クリア**する（`padEvents` と同じ作法）。
    /// 呼ばれるのは `InstrumentRack` の 0.5 秒タイマー = main
    func drainRenderStats() -> RenderStats? {
        // ⚠️ **実経過を測る**（`Timer` の 0.5 秒を信じない）。
        // ここがずれると実測レートがそのまま嘘になる
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        lock.lock()
        let calls = renderCalls
        let total = renderTotalNs
        let peak = renderMaxNs
        let frameCount = renderFrameCount
        let frames = renderFrames
        let rate = engineRate
        let since = renderDrainedAt
        renderCalls = 0
        renderTotalNs = 0
        renderMaxNs = 0
        renderFrames = 0
        renderDrainedAt = now
        lock.unlock()

        guard calls > 0 else { return nil }
        return RenderStats(
            calls: calls, totalNs: total, maxNs: peak,
            frameCount: frameCount, sampleRate: rate,
            frames: frames,
            // 初回は基準が無いので実測しない（0 = measuredRate が nil になる）
            elapsedNs: since > 0 ? now - since : 0)
    }
}
