//! FFT: CPU（Accelerate/vDSP）vs GPU（Metal/MPSGraph）の実測比較。
//!
//! なぜ要るか: SIMD-on-GPU 系の技術（VectorWare/rust-gpu）は今の Ladyland
//! （Swift/Metal）には届かない（rust-gpu は SPIR-V/Vulkan 専用、Metal 未対応）。
//! Metal ネイティブ（MPSGraph の FFT オペレータ）で自分たちの規模を測るのが
//! 唯一の確実な道。単発 FFT は dispatch オーバーヘッドで GPU が負けやすく、
//! 「同時に何本並ぶか」で境目が変わるはず——3D field の per-entity 解析
//! （design/04、エンティティごとに音源をバインドする案）はまさにこの形なので、
//! 並列本数を横軸にして測る。
//!
//! 使い方:
//!   swift run RigBench fft-backend                  # デフォルトの N 列
//!   swift run RigBench fft-backend 1,4,16,64,256     # N を指定

import Accelerate
import Foundation
import Metal
import MetalPerformanceShadersGraph

struct FftBackendBench: Bench {
    let name = "fft-backend"
    let summary = "FFT: CPU(vDSP) vs GPU(MPSGraph) を並列本数ごとに実測比較"

    /// vDSP_fft_zrip は 2 のべき乗長のみ対応。オーディオ解析の典型窓長
    private let frameSize = 2048
    private let repeats = 5

    func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        let batchSizes: [Int]
        if let arg = arguments.first {
            batchSizes = arg.split(separator: ",").compactMap { Int($0) }
        } else {
            batchSizes = [1, 4, 16, 64, 256, 1024]
        }
        guard !batchSizes.isEmpty else { throw BenchError("N の指定が読めない: \(arguments)") }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchError("Metal device が取れない")
        }
        guard let queue = device.makeCommandQueue() else {
            throw BenchError("MTLCommandQueue が作れない")
        }
        print("Metal device: \(device.name)")
        print("frame size: \(frameSize) samples / repeats: \(repeats)\n")

        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let cpuSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw BenchError("vDSP_create_fftsetup 失敗")
        }
        defer { vDSP_destroy_fftsetup(cpuSetup) }

        let gpu = try GpuFft(device: device, queue: queue, frameSize: frameSize)

        try sanityCheck(cpuSetup: cpuSetup, log2n: log2n, gpu: gpu)

        print("     N │   CPU(vDSP)      │   GPU(MPSGraph)   │  speedup")
        print("───────┼──────────────────┼───────────────────┼──────────")
        for n in batchSizes {
            let buffers = (0..<n).map { makeTestBuffer(seed: $0) }

            let cpuMsPerPass = try cpuElapsedMs(buffers: buffers, setup: cpuSetup, log2n: log2n)
            let gpuMsPerPass = try gpu.elapsedMs(buffers: buffers, repeats: repeats)

            let speedup = cpuMsPerPass / gpuMsPerPass
            print(
                String(
                    format: "%6d │ %8.3f ms/pass │ %8.3f ms/pass  │  %.2fx",
                    n, cpuMsPerPass, gpuMsPerPass, speedup))
        }

        print("\n※ GPU 側は CPU→GPU 転送・実行・読み戻しまで全部込みの壁時計。")
        print("  N が小さいうちは dispatch オーバーヘッドで GPU が不利になりやすい——")
        print("  どこで逆転するかがそのまま「同時何エンティティから GPU に価値が出るか」の目安。")
    }

    /// 既知の周波数ビンに立つサイン波で、両バックエンドのピーク位置が一致するかを見る
    /// （速度だけでなく「ちゃんと動いている」ことの最低限の担保）。
    private func sanityCheck(cpuSetup: FFTSetup, log2n: vDSP_Length, gpu: GpuFft) throws {
        let testBin = 100
        let n = frameSize
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = sin(2.0 * Float.pi * Float(testBin) * Float(i) / Float(n))
        }

        let cpuMagnitudes = try cpuMagnitudes(samples: samples, setup: cpuSetup, log2n: log2n)
        let cpuPeak = argmax(cpuMagnitudes)
        guard cpuPeak == testBin else {
            throw BenchError("CPU FFT のピークが bin \(cpuPeak)（期待 \(testBin)）— 実装がおかしい")
        }

        let gpuMagnitudes = try gpu.magnitudesSquared(for: [samples])[0]
        let gpuPeak = argmax(gpuMagnitudes)
        guard gpuPeak == testBin else {
            throw BenchError("GPU FFT のピークが bin \(gpuPeak)（期待 \(testBin)）— 実装がおかしい")
        }

        print("整合性チェック: CPU/GPU とも bin \(testBin) にピーク ✓\n")
    }

    private func makeTestBuffer(seed: Int) -> [Float] {
        // 実際の音源ごとの解析を模して、本数ごとに周波数・位相をずらす
        let bin = 20 + (seed % 200)
        let phase = Float(seed) * 0.37
        return (0..<frameSize).map { i in
            sin(2.0 * Float.pi * Float(bin) * Float(i) / Float(frameSize) + phase)
        }
    }

    private func cpuMagnitudes(samples: [Float], setup: FFTSetup, log2n: vDSP_Length) throws -> [Float] {
        let halfN = samples.count / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBytes { rawPtr in
                    let complexPtr = rawPtr.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &split, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }
        return magnitudes
    }

    private func cpuElapsedMs(buffers: [[Float]], setup: FFTSetup, log2n: vDSP_Length) throws -> Double {
        var best = Double.infinity
        for _ in 0..<repeats {
            let start = DispatchTime.now()
            for buffer in buffers {
                _ = try cpuMagnitudes(samples: buffer, setup: setup, log2n: log2n)
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsedMs)
        }
        return best
    }

    private func argmax(_ values: [Float]) -> Int {
        var bestIndex = 0
        var bestValue = -Float.infinity
        for (i, v) in values.enumerated() where v > bestValue {
            bestValue = v
            bestIndex = i
        }
        return bestIndex
    }
}

/// MPSGraph 側の FFT パイプライン。グラフは形状（N, frameSize）ごとに初回コンパイルが
/// 走る（重い）ので、N ごとに 1 回だけ組んでキャッシュし、計測はその後の
/// `run` 呼び出し（入力転送・実行・読み戻し）だけを対象にする。
/// そうしないと「グラフを毎回組み直すコスト」が GPU 側にだけ乗って不公平な比較になる。
private final class GpuFft {
    private struct CompiledGraph {
        let graph: MPSGraph
        let placeholder: MPSGraphTensor
        let output: MPSGraphTensor
    }

    private let queue: MTLCommandQueue
    private let graphDevice: MPSGraphDevice
    private let frameSize: Int
    private let halfSpectrum: Int
    private var cache: [Int: CompiledGraph] = [:]

    init(device: MTLDevice, queue: MTLCommandQueue, frameSize: Int) throws {
        self.queue = queue
        self.graphDevice = MPSGraphDevice(mtlDevice: device)
        self.frameSize = frameSize
        self.halfSpectrum = frameSize / 2 + 1
    }

    /// N 本分の magnitude-squared スペクトラムを 1 回の GPU 実行で返す（ベンチ用ではなく検証用）。
    func magnitudesSquared(for buffers: [[Float]]) throws -> [[Float]] {
        let (_, flat) = try run(buffers: buffers)
        return unflatten(flat, count: buffers.count)
    }

    /// `repeats` 回計測して最速値（ms/pass）を返す。1 回目はグラフコンパイルを
    /// 含むのでウォームアップとして捨てる。
    func elapsedMs(buffers: [[Float]], repeats: Int) throws -> Double {
        _ = try run(buffers: buffers) // warm-up

        var best = Double.infinity
        for _ in 0..<repeats {
            let (elapsedMs, _) = try run(buffers: buffers)
            best = min(best, elapsedMs)
        }
        return best
    }

    private func compiledGraph(for n: Int) -> CompiledGraph {
        if let cached = cache[n] { return cached }

        let graph = MPSGraph()
        let shape: [NSNumber] = [NSNumber(value: n), NSNumber(value: frameSize)]
        let placeholder = graph.placeholder(shape: shape, dataType: .float32, name: nil)
        let fftDescriptor = MPSGraphFFTDescriptor()
        fftDescriptor.scalingMode = .none
        let spectrum = graph.realToHermiteanFFT(placeholder, axes: [1], descriptor: fftDescriptor, name: nil)
        // graph.absoluteSquare(tensor:) は複素数入力に対して複素数型のまま
        // （虚部ゼロ）を返す（実測確認済み）。float32 として読み戻すと
        // 8 バイト単位を 4 バイトずつ読むことになり、値が半分の位置にずれて
        // 周波数が 2 倍に化ける。real/imag を取り出して手動で二乗和を取る。
        let real = graph.realPartOfTensor(tensor: spectrum, name: nil)
        let imag = graph.imaginaryPartOfTensor(tensor: spectrum, name: nil)
        let magnitudeSquared = graph.addition(
            graph.multiplication(real, real, name: nil),
            graph.multiplication(imag, imag, name: nil),
            name: nil)

        let compiled = CompiledGraph(graph: graph, placeholder: placeholder, output: magnitudeSquared)
        cache[n] = compiled
        return compiled
    }

    private func run(buffers: [[Float]]) throws -> (elapsedMs: Double, flat: [Float]) {
        let n = buffers.count
        let compiled = compiledGraph(for: n) // キャッシュ済みなら計測に乗らない

        let start = DispatchTime.now()

        var flatInput = [Float](repeating: 0, count: n * frameSize)
        for (i, buffer) in buffers.enumerated() {
            flatInput.replaceSubrange(i * frameSize..<(i + 1) * frameSize, with: buffer)
        }
        let shape: [NSNumber] = [NSNumber(value: n), NSNumber(value: frameSize)]
        let inputData = flatInput.withUnsafeBufferPointer { ptr in
            MPSGraphTensorData(
                device: graphDevice,
                data: Data(buffer: ptr),
                shape: shape,
                dataType: .float32)
        }

        let results = compiled.graph.run(
            with: queue,
            feeds: [compiled.placeholder: inputData],
            targetTensors: [compiled.output],
            targetOperations: nil)

        guard let output = results[compiled.output] else {
            throw BenchError("GPU FFT の結果が取れない")
        }
        var flatOutput = [Float](repeating: 0, count: n * halfSpectrum)
        output.mpsndarray().readBytes(&flatOutput, strideBytes: nil)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return (elapsedMs, flatOutput)
    }

    private func unflatten(_ flat: [Float], count: Int) -> [[Float]] {
        (0..<count).map { i in
            Array(flat[(i * halfSpectrum)..<((i + 1) * halfSpectrum)])
        }
    }
}
