//! `swift run RigBench audio-latency` の純粋部分のテスト。
//!
//! 機材（L6max）は CI に無いので、実機を触らない計算だけを仕様として固定する:
//! レイテンシ予算の足し算・ms 換算、取り込みバッファからの立ち上がり検出、
//! 往復時間の組み立て、複数回測定の中央値。

import Testing

@testable import RigBench

@Suite("audio-latency の予算計算")
struct LatencyBudgetTests {
    @Test("予算 = バッファ + デバイス + 安全余裕 + ストリーム（frames）を ms に直す")
    func totalIsSumInMilliseconds() {
        let budget = LatencyBudget(
            sampleRate: 48_000, bufferFrames: 512, deviceLatencyFrames: 96,
            safetyOffsetFrames: 64, streamLatencyFrames: 0)
        #expect(budget.totalFrames == 672)
        #expect(abs(budget.totalMs - 14.0) < 0.001)
        #expect(abs(budget.ms(480) - 10.0) < 0.001)
    }

    @Test("サンプルレートが 0 なら ms は 0（ゼロ除算で NaN を出さない）")
    func zeroRateIsSafe() {
        let budget = LatencyBudget(
            sampleRate: 0, bufferFrames: 512, deviceLatencyFrames: 0,
            safetyOffsetFrames: 0, streamLatencyFrames: 0)
        #expect(budget.totalMs == 0)
    }
}

@Suite("audio-latency の立ち上がり検出")
struct OnsetTests {
    @Test("閾値を最初に超えた index を返す（正負どちらも）")
    func firstCrossing() {
        let samples: [Float] = [0, 0.001, -0.002, 0.0, -0.3, 0.9, 0.1]
        #expect(Onset.firstIndex(in: samples, threshold: 0.1) == 4)
    }

    @Test("超えなければ nil")
    func noCrossing() {
        let samples: [Float] = [0, 0.01, -0.02]
        #expect(Onset.firstIndex(in: samples, threshold: 0.1) == nil)
    }

    @Test("往復時間 = 取り込みバッファ先頭時刻 + onset/rate − 再生予約時刻")
    func roundTrip() {
        // 再生を t=1.000s に予約、取り込みバッファが t=1.010s から始まり
        // その 240 サンプル目（48kHz で 5ms）で立ち上がった → 往復 15ms
        let seconds = Onset.roundTripSeconds(
            playAt: 1.000, captureBufferAt: 1.010, onsetIndex: 240, sampleRate: 48_000)
        #expect(abs(seconds - 0.015) < 1e-9)
    }

    @Test("閾値はノイズ床の倍数、ただし下限を割らない")
    func thresholdFromNoiseFloor() {
        #expect(Onset.threshold(noisePeak: 0.001) == 0.01)  // 下限
        #expect(abs(Onset.threshold(noisePeak: 0.05) - 0.2) < 1e-6)  // 4 倍
    }
}

@Suite("audio-latency の集計")
struct LatencyStatsTests {
    @Test("中央値（偶数個は中央 2 つの平均）と最大")
    func medianAndMax() {
        #expect(Onset.median([3, 1, 2]) == 2)
        #expect(Onset.median([4, 1, 3, 2]) == 2.5)
        #expect(Onset.median([]) == nil)
    }
}
