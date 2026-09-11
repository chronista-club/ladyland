//! LPD8 mk2 の LED フィードバック常駐エンジン（design/06 §8、spec/04 interaction 層）。
//!
//! パッド LED を表示器として使う: flash（選択変化の一瞬）> 音量輝度 > 基本色。
//! 実測（RigBench lpd8-led-rate、M5）でサービスタイム ≈107ms/frame ≈ 9-10fps が
//! デバイス側上限と判明したため、固定 Hz ではなく **completion-gated** で送る:
//!
//!   in-flight は常に 1 フレームのみ。完了コールバックが「次を送っていい合図」。
//!   デバイス自身のペースに自動追従し、キュー滞留（= 見た目のラグ）が
//!   構造的に発生しない（TCP のフロー制御と同じ閉ループ）。
//!
//! さらに shadow（最後に送ったワイヤフレーム）との差分で無変化 tick の送信を
//! 抑止する。比較は量子化後のワイヤ値 — メーターの微小な揺れは送信 0 になる。
//! 0x06 の LED 上書きは挿し直しまで実機に残るため、終了時は全消灯を送る。

import CoreMIDI
import Foundation
import Lpd8Kit

/// LED フレームの送信抽象（テストは fake を注入する）
@MainActor
protocol LedSender: AnyObject {
    /// フレームを送る。宛先が無ければ false。onComplete は MainActor で呼ぶこと
    func send(_ frame: [UInt8], onComplete: @escaping @MainActor () -> Void) -> Bool
    /// 宛先キャッシュを破棄する（挿抜時）
    func invalidate()
}

/// 実機送信（Lpd8Kit.MIDISysExSender、宛先は遅延解決してキャッシュ)
@MainActor
final class CoreMIDILedSender: LedSender {
    private var client: MIDIClientRef?
    private var dest: MIDIEndpointRef?

    func send(_ frame: [UInt8], onComplete: @escaping @MainActor () -> Void) -> Bool {
        if client == nil {
            client = try? MIDISysExSender.makeClient("ladyland-led")
        }
        if dest == nil {
            dest = try? MIDISysExSender.destination(matching: "LPD8")
        }
        guard let dest else { return false }
        MIDISysExSender.send(frame, to: dest) { _ in
            Task { @MainActor in onComplete() }
        }
        return true
    }

    func invalidate() {
        dest = nil
    }
}

/// **サンプラー席の再生状態**（LED の色分け用。mako 要望 2026-08-06
/// 「再生中か再生中じゃないかは、Pad の色も合わせたい」）。
///
/// ⚠️ `LadySampler.PadState` をそのまま持ち込まない — LED は音の実装を
/// 知る必要がなく、**必要なのは 3 値だけ**。境界を薄く保つ
enum PadPlayState: Equatable {
    /// 頭で停止 / 空 — 基本色のまま
    case idle
    /// 鳴っている
    case playing
    /// 止めたが位置が残っている。
    /// ⚠️ **LED では光らない**（`LedCompositor.base` の二値化）。型として
    /// 残してあるのは、画面側が 3 状態を必要とするため — 境界の型は崩さない
    case paused
}

/// 合成器 — 純関数（テスト対象）。優先度: flash > 音量輝度 × 基本色
enum LedCompositor {
    /// **再生中** — 画面（`SamplerFieldView` の球）と同じ水色。
    /// hue 0.52 / sat 0.75 / bright 1.0 を 8bit に落としたもの
    static let playingColor = Rgb8(64, 232, 255)

    /// **基本色に再生状態を重ねる**（純関数 — テスト対象）。
    ///
    /// ⚠️ **二値**（mako 裁定 2026-08-06「再生中だけ光る」）。
    /// 一時停止は**光らせない** — ステージで目に入る情報を 1 つに絞る判断で、
    /// 実機の LED は「**いま鳴っている席はどれか**」だけを言う。
    /// 一時停止は画面（カードのバーとバッジ）で読めるので情報は失われない。
    ///
    /// ⚠️ **明滅も進捗による輝度変化も入れない**。実測上限が 9-10fps
    /// （`RigBench lpd8-led-rate`）なので、動かすと帯域を食い切るうえ、
    /// shadow 差分が効かなくなって**毎 tick 送信**になる。
    /// **状態が変わったときだけフレームが飛ぶ**のが正しい。
    ///
    /// 状態が足りない（プロバイダ未接続 = 空配列）ときは**基本色のまま**返す
    static func base(_ base: [Rgb8], playStates: [PadPlayState]) -> [Rgb8] {
        guard !playStates.isEmpty else { return base }
        return base.enumerated().map { index, color in
            switch index < playStates.count ? playStates[index] : .idle {
            case .playing: return playingColor
            // ⚠️ **一時停止も基本色**。二値なのでワイヤ上は「頭で停止」と
            // 区別が付かない = 遷移してもフレームが飛ばない（それが狙い）
            case .idle, .paused: return color
            }
        }
    }
    /// レベルの量子化段数。粗くするほどメーター揺れの送信が減る
    static let levelSteps = 15

    /// 輝度の下限（0 だと無音時に基本色が消えて「死んで見える」)
    static let brightnessFloor = 0.25

    static func compose(base: [Rgb8], flashPad: Int?, level: Float) -> [Rgb8] {
        let quantized = min(levelSteps, max(0, Int(level * Float(levelSteps))))
        let scale = brightnessFloor + (1 - brightnessFloor) * Double(quantized) / Double(levelSteps)
        var out = base.map { scaled($0, by: scale) }
        if let flashPad, out.indices.contains(flashPad) {
            // flash 中: 対象パッドは白、他は減光して視線を集める
            out = out.enumerated().map { index, color in
                index == flashPad ? Rgb8(255, 255, 255) : scaled(color, by: 0.3)
            }
        }
        return out
    }

    private static func scaled(_ c: Rgb8, by factor: Double) -> Rgb8 {
        Rgb8(
            UInt8(Double(c.r) * factor),
            UInt8(Double(c.g) * factor),
            UInt8(Double(c.b) * factor)
        )
    }
}

@MainActor
final class LedBus {
    static let allOffFrame = Lpd8SysEx.ledFrame(Array(repeating: .off, count: 8))

    /// flash の表示時間（≈ 実機 3-4 フレーム分）
    static let flashDurationNs: UInt64 = 400_000_000

    /// watchdog: in-flight がこれを超えたら完了が消えたとみなす（抜線対策）
    static let inFlightTimeoutNs: UInt64 = 1_000_000_000

    private let sender: LedSender

    /// 最後に送り切ったワイヤフレーム（nil = 実機の状態が不明 → 必ず送る）
    private(set) var shadow: [UInt8]?
    private(set) var inFlight = false
    private var sentAtNs: UInt64 = 0

    /// 基本色レイヤ（KeyScale PR で音階の色に置き換わる。それまでは静かな青）
    private var base: [Rgb8] = Array(repeating: Rgb8(0, 24, 48), count: 8)
    private var flashPad: Int?
    private var flashUntilNs: UInt64 = 0
    private var levelProvider: () -> Float = { 0 }

    /// サンプラー席の再生状態。**未接続なら空**を返し、基本色のまま出る
    /// （degrade gracefully — 繋がっていなければ今までどおりの見た目）
    private var playStateProvider: () -> [PadPlayState] = { [] }

    /// キルスイッチ（永続化、design/06 §8「ステージの非常口」）
    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                shadow = nil
                pump()
            } else {
                forceAllOff()
            }
        }
    }

    /// エディタの GET/SET 中は SysEx を混線させない
    private(set) var suspended = false

    private var timer: Timer?

    init(sender: LedSender? = nil) {
        self.sender = sender ?? CoreMIDILedSender()
    }

    func configure(levelProvider: @escaping () -> Float) {
        self.levelProvider = levelProvider
    }

    /// 再生状態の供給元を注ぐ（`levelProvider` と同じ形）
    func configure(playStateProvider: @escaping () -> [PadPlayState]) {
        self.playStateProvider = playStateProvider
    }

    /// tick 開始（≈9Hz — 実測上限に合わせた巡回。送るかは差分次第）
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.11, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 選択スロットの変化を一瞬の白 flash で映す（イベント駆動 — 即 pump）
    func flashSelection(_ padIndex: Int) {
        guard (0..<8).contains(padIndex) else { return }
        flashPad = padIndex
        flashUntilNs = DispatchTime.now().uptimeNanoseconds + Self.flashDurationNs
        pump()
    }

    /// 基本色レイヤの差し替え（KeyScale などから）
    func setBase(_ colors: [Rgb8]) {
        guard colors.count == 8 else { return }
        base = colors
        pump()
    }

    /// 挿抜時: 宛先とワイヤ状態を捨てて全再描画（MIDIInput.onSetupChanged から）
    func reconnect() {
        sender.invalidate()
        shadow = nil
        inFlight = false
        pump()
    }

    func suspend() {
        suspended = true
    }

    func resume() {
        suspended = false
        shadow = nil  // エディタ操作中に実機側が変わったかもしれない
        pump()
    }

    /// 終了時: 全消灯を 1 発（0x06 上書きは挿し直しまで残るため、
    /// 中途半端な表示を実機に置き去りにしない）
    func shutdown() {
        timer?.invalidate()
        timer = nil
        _ = sender.send(Self.allOffFrame) {}
    }

    // MARK: - 内部

    func tick(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        if let _ = flashPad, nowNs > flashUntilNs {
            flashPad = nil
        }
        // watchdog: 送信中の抜線などで完了が来ない場合に自己回復する
        if inFlight, nowNs - sentAtNs > Self.inFlightTimeoutNs {
            inFlight = false
            sender.invalidate()
            shadow = nil
        }
        pump()
    }

    /// completion-gated 送信の心臓部。
    /// 送るのは「有効・非サスペンド・in-flight なし・差分あり」の時だけ
    func pump() {
        guard enabled, !suspended, !inFlight else { return }
        // ⚠️ **ここで論理席順 → 実機セル順へ並べ替える**（`swapPadRows`）。
        // `base`（KeyScale）も `playStates`（サンプラー）も `flashPad` も
        // **全部が論理席順**（上段が先）なので、変換は 1 か所・最後だけでいい
        let frame = Lpd8SysEx.ledFrame(
            Lpd8SysEx.swapPadRows(
                LedCompositor.compose(
                    base: LedCompositor.base(base, playStates: playStateProvider()),
                    flashPad: flashPad, level: levelProvider()))
        )
        guard frame != shadow else { return }
        let accepted = sender.send(frame) { [weak self] in
            guard let self else { return }
            self.inFlight = false
            self.shadow = frame
            self.pump()  // 完了 = 次を送っていい合図（中間状態は合流して消える）
        }
        if accepted {
            inFlight = true
            sentAtNs = DispatchTime.now().uptimeNanoseconds
        }
    }

    private func forceAllOff() {
        // キルスイッチはゲートを通さず即消灯（in-flight 中でも上書きでよい —
        // 56B なので後勝ちで確実に消える）
        _ = sender.send(Self.allOffFrame) { [weak self] in
            self?.inFlight = false
        }
        shadow = Self.allOffFrame
    }
}
