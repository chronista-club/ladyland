//! audio-latency — 出音レイテンシの予算と実測
//! （design/06 §7「レイテンシ実測（鍵盤 → ladyland → L6max 出音）」の持ち越し）。
//!
//! 2 段構え:
//!
//! 1. **予算**（機材に音を出さない）: 出力デバイスが CoreAudio に申告している
//!    バッファ長・固有遅延・安全余裕を frames で読み、ms に直す。
//!    「Mac を出るまでに最低これだけかかる」の数字
//! 2. **実測** `--loopback`: 同じデバイスの出力へクリックを出し、入力に返ってくる
//!    までの往復を測る。L6max なら Mac → USB → CH7 → MASTER → USB → Mac。
//!    片道は分けられないが、**往復 − 入力側の予算 ≈ 出音まで**として読む
//!
//! 使い方:
//!   swift run RigBench audio-latency                 # L6max の予算（無ければ OS 既定）
//!   swift run RigBench audio-latency Zenith          # 名前の部分一致で選ぶ
//!   swift run RigBench audio-latency --loopback      # 往復を 8 回測って中央値
//!
//! ⚠️ ループバックの前提（L6max）: `USB 1/2` キー点灯・CH7 のレベルが上がっている・
//! USB Audio Interface が Multi Track（MASTER が入力 13/14 に返る）か Stereo Mix。
//! ターミナルにマイク権限が要る（初回はダイアログ）。

import AVFoundation
import CoreAudio
import Foundation

struct AudioLatency: Bench {
    let name = "audio-latency"
    let summary = "出力デバイスのレイテンシ予算（バッファ+固有+安全余裕）。--loopback で往復を実測"

    private static let trials = 8
    private static let defaultFragment = "L6max"

    func run() throws {
        let args = Array(CommandLine.arguments.dropFirst(2))
        let fragment = args.first { !$0.hasPrefix("--") } ?? Self.defaultFragment
        let loopback = args.contains("--loopback")

        guard let device = Device.find(nameContains: fragment) ?? Device.defaultOutput() else {
            throw BenchError("出力デバイスが見つからない")
        }
        print("device: \(device.name)\(device.name.contains(fragment) ? "" : "（'\(fragment)' 不在 → OS 既定）")")

        let out = Device.budget(of: device.id, scope: kAudioDevicePropertyScopeOutput)
        printBudget("出力", out)

        guard loopback else {
            print("\n往復を測るには --loopback（クリックが鳴る。L6max は USB 1/2 点灯・CH7 を上げておく）")
            return
        }

        let inp = Device.budget(of: device.id, scope: kAudioDevicePropertyScopeInput)
        printBudget("入力", inp)
        try measureLoopback(device: device, inputBudgetMs: inp.totalMs)
    }

    private func printBudget(_ label: String, _ b: LatencyBudget) {
        print(String(
            format: "%@ %.0f Hz: buffer %d + device %d + safety %d + stream %d = %d frames = %.2f ms",
            label, b.sampleRate, b.bufferFrames, b.deviceLatencyFrames, b.safetyOffsetFrames,
            b.streamLatencyFrames, b.totalFrames, b.totalMs))
    }

    // MARK: - ループバック

    private func measureLoopback(device: Device, inputBudgetMs: Double) throws {
        // マイク権限（TCC）。未決定ならここでダイアログが出る — 拒否/未決定のまま
        // 走ると入力が無音になり「検出なし」だけが並ぶので、先に確かめる
        guard Self.ensureMicrophoneAccess() else {
            throw BenchError("マイク権限が無い — システム設定 → プライバシー → マイク でターミナルを許可")
        }

        let engine = AVAudioEngine()
        guard Device.set(device.id, on: engine.outputNode), Device.set(device.id, on: engine.inputNode)
        else { throw BenchError("\(device.name) を入出力に設定できない（入力の無いデバイス？）") }
        // デバイスを差し替えてから prepare し、その後で format を読む
        // （切替直後の読みが既定マイクの 1ch を返したことがある）
        engine.prepare()

        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        let outFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outFormat.sampleRate
        guard rate > 0, inFormat.channelCount > 0 else {
            throw BenchError("フォーマット不明（in \(inFormat), out \(outFormat)）")
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        let playFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let capture = Capture()
        engine.inputNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, when in
            capture.append(buffer, at: when)
        }

        try engine.start()
        player.play()
        defer { engine.stop() }

        // ノイズ床（0.3 秒）→ 閾値
        Thread.sleep(forTimeInterval: 0.3)
        let noise = capture.drainPeak()
        let threshold = Onset.threshold(noisePeak: noise)
        print(String(format: "\n入力 %d ch、ノイズ床 %.4f → 閾値 %.3f", inFormat.channelCount, noise, threshold))

        let click = Self.clickBuffer(format: playFormat)
        var trips: [Double] = []
        var channelHits: [Int: Int] = [:]

        for trial in 1...Self.trials {
            let playAt = HostClock.now() + 0.1
            capture.arm(threshold: threshold, notBefore: playAt)
            player.scheduleBuffer(click, at: AVAudioTime(hostTime: HostClock.ticks(playAt)))
            Thread.sleep(forTimeInterval: 0.5)
            if let hit = capture.hit {
                let seconds = Onset.roundTripSeconds(
                    playAt: playAt, captureBufferAt: hit.bufferAt, onsetIndex: hit.index, sampleRate: rate)
                trips.append(seconds * 1000)
                channelHits[hit.channel, default: 0] += 1
                print(String(format: "  #%d  %.2f ms  (ch %d)", trial, seconds * 1000, hit.channel + 1))
            } else {
                print("  #\(trial)  検出なし")
            }
        }

        guard let median = Onset.median(trips), let worst = trips.max() else {
            print("\n一度も返ってこなかった — 経路（USB 1/2 点灯・CH7 レベル・USB Audio モード）とマイク権限を確認")
            return
        }
        let channels = channelHits.keys.sorted().map { "\($0 + 1)" }.joined(separator: ",")
        print(String(
            format: "\n往復 中央値 %.2f ms / 最大 %.2f ms（%d/%d 回、入力 ch %@）",
            median, worst, trips.count, Self.trials, channels))
        print(String(format: "出音まで ≈ 往復 − 入力予算 %.2f = %.2f ms", inputBudgetMs, median - inputBudgetMs))
    }

    private static func ensureMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                done.signal()
            }
            _ = done.wait(timeout: .now() + 60)
            return granted
        default: return false
        }
    }

    /// 1kHz を 2ms（クリック）。振幅は控えめ — 卓の CH7 を通るので
    private static func clickBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * 0.002)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = 0.5 * sinf(2 * .pi * 1000 * Float(i) / Float(format.sampleRate))
            }
        }
        return buffer
    }
}

// MARK: - 取り込み側（CoreAudio スレッドから呼ばれる）

private final class Capture: @unchecked Sendable {
    struct Hit {
        var bufferAt: Double
        var index: Int
        var channel: Int
    }

    private let lock = NSLock()
    private var peak: Float = 0
    private var threshold: Float = .greatestFiniteMagnitude
    private var notBefore: Double = .greatestFiniteMagnitude
    private(set) var hit: Hit?

    func arm(threshold: Float, notBefore: Double) {
        lock.lock(); defer { lock.unlock() }
        self.threshold = threshold
        self.notBefore = notBefore
        hit = nil
    }

    func drainPeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = peak
        peak = 0
        return value
    }

    func append(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let data = buffer.floatChannelData, when.isHostTimeValid else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let bufferAt = HostClock.seconds(when.hostTime)

        lock.lock(); defer { lock.unlock() }
        for ch in 0..<channels {
            let samples = UnsafeBufferPointer(start: data[ch], count: frames)
            for s in samples where abs(s) > peak { peak = abs(s) }
            guard hit == nil, bufferAt + Double(frames) / buffer.format.sampleRate >= notBefore,
                  let index = Onset.firstIndex(in: samples, threshold: threshold)
            else { continue }
            hit = Hit(bufferAt: bufferAt, index: index, channel: ch)
        }
    }
}

// MARK: - mach 時刻

private enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    static func now() -> Double { seconds(mach_absolute_time()) }
}

// MARK: - CoreAudio デバイス

private struct Device {
    let id: AudioDeviceID
    let name: String

    static func find(nameContains fragment: String) -> Device? {
        all().first { $0.name.contains(fragment) }
    }

    static func defaultOutput() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != 0, let name = name(of: id)
        else { return nil }
        return Device(id: id, name: name)
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard streams(of: id, scope: kAudioDevicePropertyScopeOutput).count > 0,
                  let name = name(of: id) else { return nil }
            return Device(id: id, name: name)
        }
    }

    static func budget(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> LatencyBudget {
        let stream = streams(of: id, scope: scope).first
        return LatencyBudget(
            sampleRate: double(of: id, selector: kAudioDevicePropertyNominalSampleRate, scope: scope),
            bufferFrames: int(of: id, selector: kAudioDevicePropertyBufferFrameSize, scope: scope),
            deviceLatencyFrames: int(of: id, selector: kAudioDevicePropertyLatency, scope: scope),
            safetyOffsetFrames: int(of: id, selector: kAudioDevicePropertySafetyOffset, scope: scope),
            streamLatencyFrames: stream.map {
                int(of: $0, selector: kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal)
            } ?? 0)
    }

    static func set(_ id: AudioDeviceID, on node: AVAudioIONode) -> Bool {
        guard let unit = node.audioUnit else { return false }
        var deviceID = id
        return AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    private static func streams(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func int(
        of id: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return Int(value)
    }

    private static func double(
        of id: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope
    ) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
