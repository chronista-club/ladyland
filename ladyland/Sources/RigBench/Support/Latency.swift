//! audio-latency ベンチの純粋部分（テスト対象。機材に触らない）。
//!
//! 予算（CoreAudio が申告する frames の足し算）と、ループバック実測の
//! 立ち上がり検出・往復時間の組み立て・集計。

import Foundation

/// 出力デバイスが申告するレイテンシ予算（frames）。
/// **鍵盤 → ladyland → 出音**のうち Mac 側で決まる分の見積もり —
/// 実測（ループバック）と並べて「どこで食っているか」を読む
struct LatencyBudget {
    var sampleRate: Double
    /// kAudioDevicePropertyBufferFrameSize — render 1 回ぶん
    var bufferFrames: Int
    /// kAudioDevicePropertyLatency（出力スコープ）— デバイス固有の固定遅延
    var deviceLatencyFrames: Int
    /// kAudioDevicePropertySafetyOffset — HAL が確保する安全余裕
    var safetyOffsetFrames: Int
    /// kAudioStreamPropertyLatency — ストリーム固有分（0 のことが多い）
    var streamLatencyFrames: Int

    var totalFrames: Int {
        bufferFrames + deviceLatencyFrames + safetyOffsetFrames + streamLatencyFrames
    }

    func ms(_ frames: Int) -> Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate * 1000
    }

    var totalMs: Double { ms(totalFrames) }
}

enum Onset {
    /// 閾値の下限（無音でも ADC ノイズで 1e-3 程度は揺れる）
    static let thresholdFloor: Float = 0.01
    /// ノイズ床に対する倍率
    static let thresholdRatio: Float = 4

    /// `|x| >= threshold` となる最初の index
    static func firstIndex(in samples: [Float], threshold: Float) -> Int? {
        samples.firstIndex { abs($0) >= threshold }
    }

    static func firstIndex(in samples: UnsafeBufferPointer<Float>, threshold: Float) -> Int? {
        samples.firstIndex { abs($0) >= threshold }
    }

    /// 無音区間のピークから閾値を決める
    static func threshold(noisePeak: Float) -> Float {
        max(thresholdFloor, noisePeak * thresholdRatio)
    }

    /// 往復時間 [s]。取り込みバッファの先頭時刻に onset の位置を足し、再生予約時刻を引く
    static func roundTripSeconds(
        playAt: Double, captureBufferAt: Double, onsetIndex: Int, sampleRate: Double
    ) -> Double {
        captureBufferAt + Double(onsetIndex) / sampleRate - playAt
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
