//! Lady Sampler の画面（mako 要望 2026-08-05）。
//!
//! **AU が自分で持つ画面**（`requestViewController`）なので、既存の
//! 「プラグイン画面を開く」経路がそのまま使える — 他のプラグインと同じ操作で
//! ファイルを割り当てられる。
//!
//! ⚠️ `LadySampler` は `AUAudioUnit` のサブクラスで `ObservableObject` では
//! ないので、**画面側が状態を持って同期する**。読み込み・音量変更のたびに
//! こちらの `@State` を更新する（AU 側は真の値、こちらは映し身）。

import Combine
import CreoUI
import SwiftUI
import UniformTypeIdentifiers

struct LadySamplerView: View {
    @Environment(\.creoTheme) private var theme
    let sampler: LadySampler

    /// AU の状態の映し身（AU は ObservableObject ではないので画面が持つ）
    @State private var names = [String?](repeating: nil, count: LadySampler.padCount)
    @State private var gains = [Float](repeating: 0.8, count: LadySampler.padCount)
    @State private var effects = [Bool](repeating: false, count: LadySampler.effectCount)
    /// 元データの素性（mako 要望 2026-08-06「元のデータの情報表示できる？」）
    @State private var infos = [LadySampler.SampleInfo?](
        repeating: nil, count: LadySampler.padCount)
    /// 席ごとの再生位置 0...1（**一時停止しても残る**）
    @State private var positions = [Double](repeating: 0, count: LadySampler.padCount)
    /// 席ごとの再生中フラグ
    @State private var playingPads = [Bool](repeating: false, count: LadySampler.padCount)

    /// 席ごとの準備状態（空 / 作り直し中 / 鳴らせる）。
    /// **空と作り直し中を同じ顔にしない**のが目的
    @State private var readiness = [LadySampler.PadReadiness](
        repeating: .empty, count: LadySampler.padCount)

    /// 後段 4 段の並び（`InstrumentRack.samplerEffects` と同じ順）
    static let effectNames = ["Delay", "Reverb", "Drive", "Filter"]

    /// ⚠️ 実機のパッドで切り替わるので、**画面は定期的に AU を見にいく**
    /// （AU は変更を通知しない）。
    ///
    /// ⚠️ **再生中だけ速める**（2026-08-06）。0.2 秒刻みだと再生カーソルが飛ぶ
    /// （3 秒の素材で 16 段階、1 秒なら 5 段階）ので、鳴っている席が 1 つでも
    /// あれば 20Hz にする。**止まっている間は 0.2 秒のまま** — 常時 20Hz にすると
    /// 何も動いていない時間までロックを取り続けることになる。
    ///
    /// ⚠️ 速めても**読みは `padStates()` の 1 回**。20Hz × 1 回 = 毎秒 20 回で、
    /// `180f7d9` で潰した 1440 回/秒とは桁が違う。だが**席ごとのアクセサを
    /// 生やせば一瞬でその形に戻る**ので、読みは 1 回に保つこと
    static let idleInterval = 0.2
    static let playingInterval = 0.05

    /// いまのポーリング間隔（再生中かどうかで決まる。純関数 — テスト対象）
    static func pollInterval(anyPlaying: Bool) -> Double {
        anyPlaying ? playingInterval : idleInterval
    }

    @State private var interval = LadySamplerView.idleInterval
    private var poll: AnyPublisher<Date, Never> {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .eraseToAnyPublisher()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            // ⚠️ **余りを全部取る**（mako 要望 2026-08-07「開いたところに
            // 今のビューを当ててください」）。`frame(height: 200)` を外した —
            // 固定していたせいで、横長にしたときに**画面の半分以上が空白**だった
            SamplerFieldView(sampler: sampler)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceBgSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CreoUITokens.radiusM))

            // **CC モードのパッド 1-4 が後段の 4 段**（mako 裁定 2026-08-06）。
            // 実機の PAD/CC ボタンで役割が変わるので、**同じ 8 パッドが 2 面**を持つ
            HStack(spacing: CreoUITokens.spacingS) {
                Text("FX")
                    .font(LadylandFont.captionNumber)
                    .foregroundColor(theme.textTertiary)
                ForEach(0..<LadySampler.effectCount, id: \.self) { index in
                    let on = index < effects.count && effects[index]
                    Text(Self.effectNames[index])
                        .font(on ? LadylandFont.chipBold : LadylandFont.chip)
                        .foregroundColor(on ? theme.brandPrimary : theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? theme.brandPrimarySubtle : Color.clear)
                        )
                }
                Spacer(minLength: 0)
            }
            .help("CC モードのパッド 1-4 で切り替わる（Note モードは再生 / STOP）")

            // **全体の進み具合**（mako 要望「デバイス切替直後になぜ鳴らないかが
            // 画面だけで分かること」）。再変換中だけ現れる — 平時は何も出ない
            if let banner = repreparingBanner {
                HStack(spacing: CreoUITokens.spacingS) {
                    ProgressView().controlSize(.small)
                    Text(banner)
                        .font(LadylandFont.caption)
                        .foregroundColor(theme.semanticWarningText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, CreoUITokens.spacingS)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                        .fill(theme.semanticWarningSubtle))
            }

            Divider()

            // ⚠️ **下端に FIX**（mako 要望 2026-08-07「2x4 は下に FIX」）。
            // 高さは中身なりで**余りを取らない** — 余りは上の 3D が全部取る
            padGrid
        }
        .padding(CreoUITokens.spacingM)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceBgBase)
        .onAppear { sync() }
        .onReceive(poll) { _ in sync() }
    }

    /// **8 席を実機と同じ 2 段 × 4 列で**（mako 要望 2026-08-07
    /// 「bottom に、２x４の Card を配置して」）。
    ///
    /// ⚠️ **上段が pad 1-4、下段が pad 5-8**（`Lpd8DefaultPadNotes` の 44-47 が
    /// 上段 = index 0-3）。`SamplerFieldView` の 3D と**同じ向き**にする —
    /// 同じ画面の中で 2 つの並びが違うのが最悪。
    ///
    /// ## ⚠️ 幅で列数を変える
    ///
    /// **この View は 2 か所に出る**:
    ///
    /// | どこ | 幅 |
    /// |---|---|
    /// | プラグイン窓（`requestViewController`） | **900pt** = 4 列 |
    /// | Main 右列のインラインペイン（`FocusPaneView(hosted:)`） | **470pt** = 2 列 |
    ///
    /// 4 列固定にすると狭い方で 1 枚 110pt になり、素性（rate / bit / 長さ）が
    /// 読めなくなる。⚠️ **並びの順序は変えない**ので、折り返しても
    /// **左上が pad 1** で、上の行が若い番号であることは保たれる
    private var padGrid: some View {
        // ⚠️ **列数から行数が決まる。** ここを 4 行固定にしていたのが
        // 2026-08-07 の実機バグ — 4 列（2 行）でも 4 行ぶんの高さ（528pt）を
        // 要求し続けて、**560pt の窓では 3D フィールドの取り分が 0 になった**
        let columns = Self.columns(forWidth: gridWidth)
        return VStack(spacing: CreoUITokens.spacingS) {
            ForEach(0..<(LadySampler.padCount / columns), id: \.self) { row in
                HStack(alignment: .top, spacing: CreoUITokens.spacingS) {
                    ForEach(0..<columns, id: \.self) { column in
                        self.row(row * columns + column)
                    }
                }
            }
        }
        // ⚠️ **`GeometryReader` で包まない** — あれは与えられた空間を
        // 全部取るので、**自然な高さが失われる**。幅だけを測って読む
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: GridWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(GridWidthKey.self) { gridWidth = $0 }
    }

    /// 測った幅（`GeometryReader` は縦を奪うので、幅だけ preference で受ける）
    private struct GridWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// **幅から列数を決める** — 純関数（テスト対象）。
    ///
    /// ⚠️ **行数はここから導く**（`padCount / columns`）。別々に持っていたのが
    /// 実機バグの原因で、4 列なのに 4 行ぶんの高さを取っていた
    static func columns(forWidth width: CGFloat) -> Int {
        width >= wideThreshold ? 4 : 2
    }

    /// これ以上あれば 4 列（実機と同じ 2 段 × 4 列）。
    /// ⚠️ 900pt の窓なら余裕で超え、470pt のインラインペインでは下回る
    static let wideThreshold: CGFloat = 700

    /// **1 席 = 1 カード**（mako 要望 2026-08-06「サンプルを Card っぽく」）。
    ///
    /// 行の羅列だと素性（rate / bit / ch / 長さ / メモリ）が横に伸びて読めない。
    /// カードなら**席ごとの塊**として目に入る — 実機のパッドが 8 個の塊なのと
    /// 同じ形になる。
    ///
    /// ⚠️ 角丸は自前で書かず `CreoCard` / `CreoBadge` を使う（テーマに追従する）
    private func row(_ pad: Int) -> some View {
        CreoCard(variant: names[pad] == nil ? .outlined : .default, padding: .s) {
            VStack(alignment: .leading, spacing: 4) {
                // ── 上段: 番号・ノブ・名前・状態 ──────────────────
                HStack(spacing: CreoUITokens.spacingS) {
                    Text("\(pad + 1)")
                        .font(LadylandFont.captionNumber)
                        .foregroundColor(theme.textTertiary)
                        .frame(width: 14, alignment: .trailing)

                    // どのノブが効くかを出す（実機を見ながら合わせられる）。
                    // **位置で引く**ので、PROG が変わっても K1-K8 の対応は変わらない
                    CreoBadge("K\(pad + 1)", variant: .neutral, size: .s, shape: .square)
                        .help("LPD8 の \(pad + 1) 番目のノブ（どの PROG でも同じ位置が効く）")

                    // **未割り当ては `‐`**（mako 裁定 2026-08-06。ノブ HUD と同じ規則）。
                    // ⚠️ 「クリックで割り当てられる」ことが分からなくなるので、
                    // その情報はツールチップへ逃がす（演奏中は静かな方がいい）
                    Button(names[pad] ?? "‐") { choose(pad) }
                        .buttonStyle(.borderless)
                        .font(LadylandFont.caption)
                        .foregroundColor(
                            names[pad] == nil ? theme.textTertiary : theme.textPrimary)
                        .lineLimit(1)
                        .help(
                            names[pad] == nil
                                ? "未割り当て — クリックで音声ファイルを選ぶ"
                                : "クリックで音声ファイルを選ぶ")

                    Spacer(minLength: 0)
                    readinessBadge(pad)

                    if names[pad] != nil {
                        Button {
                            sampler.clearSample(slot: pad)
                            sync()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("この枠を空にする")
                    }
                }

                // ── 中段: 元データの素性 ────────────────────────
                // 「間延びしている」は**元レートと対応済みレートの比**でしか
                // 判断できないので、**元 → 変換後**の順で並べる（既存の作法）
                if let info = infos[pad] {
                    HStack(spacing: CreoUITokens.spacingS) {
                        Text(sourceLine(pad, info))
                            .font(LadylandFont.chip)
                            .foregroundColor(
                                info.wasResampled
                                    ? theme.semanticWarningText : theme.textSecondary)
                        Spacer(minLength: 0)
                        // **席ごとのメモリ**。mako がメモリ許容を裁定した以上、
                        // 8 席で 2.2GB になりうることが席単位で見えている必要がある
                        Text(memoryLabel(info))
                            .font(LadylandFont.chip)
                            .foregroundColor(theme.textTertiary)
                    }
                    .help(detailLine(info))
                }

                // ── 波形（全長） + 再生カーソル ──────────────────
                // ⚠️ **押した / 引いた位置へ飛ぶ**が、**再生状態は変えない**
                // （`LadySampler.seek`）。「頭出ししたら鳴り出した」は事故になる
                WaveformView(
                    envelope: envelopes[pad],
                    progress: positions[pad],
                    isPlaying: playingPads[pad],
                    onSeek: { sampler.seek(pad: pad, to: $0) }
                )
                .frame(height: 32)
                .background(theme.surfaceBgSubtle)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .disabled(names[pad] == nil)

                // ── 進捗: **一時停止した位置がここで見える** ────────
                // （mako 要望 2026-08-06 の Play/Pause。止めた位置から再開するので、
                // 「どこで止まっているか」が見えないと次の一手が読めない）
                if positions[pad] > 0 || playingPads[pad] {
                    HStack(spacing: CreoUITokens.spacingS) {
                        CreoProgress(value: positions[pad])
                        // ⚠️ **バーだけでは「何秒のところか」が読めない**。
                        // 現場録音は 6 分あるので目視では位置が分からない。
                        // **一時停止中にこそ効く** —「1:12 で止めた」が読める
                        if let info = infos[pad] {
                            Text(elapsedLabel(pad, info))
                                .font(LadylandFont.chip)
                                .foregroundColor(
                                    playingPads[pad] ? theme.brandPrimary : theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    .help(playingPads[pad] ? "再生中" : "一時停止中 — 叩くとここから再開")
                }

                // ── 下段: 音量 ────────────────────────────────
                Slider(
                    value: Binding(
                        get: { Double(gains[pad]) },
                        set: {
                            gains[pad] = Float($0)
                            sampler.setGain(slot: pad, value: Float($0))
                        }
                    ), in: 0...1
                )
                .controlSize(.small)
                .disabled(names[pad] == nil)
            }
            // **未割り当てはグレーの地**（ノブ HUD と同じ規則）。
            // `.outlined` の枠と重ねて「置ける場所」だと言う
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(names[pad] == nil ? theme.surfaceBgSubtle : Color.clear))
        // **ドラッグ＆ドロップ**でも置ける（Finder から放り込む方が速い）
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in load(pad: pad, url: url) }
            }
            return true
        }
    }

    /// 席に出すバッジ。**平時は何も出さない**（鳴らせるのが普通の状態なので、
    /// そこに印を付けると 8 枚全部が賑やかになって異常が埋もれる）
    enum PadBadge: Equatable {
        case none
        /// 止めたが位置が残っている
        case paused
        /// このレートへ作り直し中
        case preparing(targetRate: Double)
    }

    /// **どのバッジを出すか**（純関数 — テスト対象）。
    ///
    /// ⚠️ **`readiness` だけでは一時停止を表現できない**。あれは `.ready` の
    /// 中の区別（位置が残っていて鳴っていない）なので、`switch` の case に
    /// `where` を足す形にすると**先行する `.ready` に食われて到達しなくなる**
    /// — 実際そうなっていて、一時停止バッジは一度も描画されていなかった。
    /// Swift は `where` 付き case の到達不能を警告しない。
    ///
    /// だから**判定を純関数へ出して 5 状態を全部テストで押さえる**。
    /// 見た目は試せなくても、どれを出すかは固定できる
    static func badge(
        readiness: LadySampler.PadReadiness, position: Double, isPlaying: Bool
    ) -> PadBadge {
        switch readiness {
        case .preparing(let target):
            return .preparing(targetRate: target)
        case .empty:
            return .none
        case .ready:
            // 位置が残っていて鳴っていない = 一時停止（再生中は何も出さない）
            return position > 0 && !isPlaying ? .paused : .none
        }
    }

    @ViewBuilder
    private func readinessBadge(_ pad: Int) -> some View {
        switch Self.badge(
            readiness: readiness[pad], position: positions[pad],
            isPlaying: playingPads[pad])
        {
        case .none:
            EmptyView()
        case .paused:
            // **一時停止**は空とも再生中とも違う顔にする
            CreoBadge("一時停止", variant: .info, size: .s)
        case .preparing(let target):
            // ⚠️ **何 Hz へ**まで言う（`158a985` のペイロードが効くところ）
            CreoBadge("\(Int(target)) Hz へ変換中", variant: .warning, size: .s)
        }
    }

    /// **経過 / 全体**（`0:03.2 / 0:06.0`）。位置は 0...1 なので長さを掛ける
    private func elapsedLabel(_ pad: Int, _ info: LadySampler.SampleInfo) -> String {
        let elapsed = info.sourceDuration * positions[pad]
        return "\(clock(elapsed)) / \(clock(info.sourceDuration))"
    }

    /// `0:03.2` — 分:秒.小数 1 桁。**桁が揺れない**よう秒は 2 桁に固定する
    private func clock(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }

    /// 席ごとのメモリ（mono Float32 の実サイズ）
    private func memoryLabel(_ info: LadySampler.SampleInfo) -> String {
        let mb = Double(info.bytes) / 1_048_576
        return mb >= 10
            ? String(format: "%.0f MB", mb)
            : String(format: "%.1f MB", mb)
    }

    /// ⚠️ **`runModal()` を使ってはいけない**（実測 2026-08-06: パネルが出ず、
    /// ログに読み込みが 1 行も残らなかった）。
    ///
    /// この画面は focus pane（画面中央の常設ペイン）へ `NSHostingController` として
    /// 埋め込まれるので、**自前のウィンドウを持たない**。`runModal()` は
    /// モーダルループの親を必要とするが、それが定まらないまま黙って何も起きない。
    /// 非同期の `begin` なら親を問わずに開く
    private func choose(_ pad: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "パッド \(pad + 1) に割り当てる音を選ぶ"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in load(pad: pad, url: url) }
        }
    }

    private func load(pad: Int, url: URL) {
        do {
            try sampler.loadSample(slot: pad, url: url)
            sync()
        } catch {
            NSLog("sampler: pad %d の読み込みに失敗 — %@", pad + 1, error.localizedDescription)
        }
    }

    /// 再変換中の 1 行。**`.preparing` を数えれば分母分子が出る**し、
    /// ペイロードから「何 Hz へ」が出る（3 値にした効き目がここ）
    private var repreparingBanner: String? {
        var target: Double?
        var preparing = 0
        var occupied = 0
        for state in readiness {
            switch state {
            case .empty: continue
            case .ready: occupied += 1
            case .preparing(let rate):
                preparing += 1
                occupied += 1
                target = rate
            }
        }
        guard preparing > 0, let target else { return nil }
        return "エンジン \(Int(target)) Hz へ再変換中 \(occupied - preparing)/\(occupied)"
    }

    /// 1 行で読める素性。**元 → 対応済み**の順で並べる（比が読めることが目的）
    private func sourceLine(_ pad: Int, _ info: LadySampler.SampleInfo) -> String {
        // 元の素性: レート / ビット深度 / チャンネル数。
        // ⚠️ 圧縮は `formatLabel` が拡張子を返す（`0bit` とは書かない）
        let source = "\(rateLabel(info.sourceRate)) / \(info.formatLabel)"
            + " / \(info.sourceChannels)ch"
        // 状態バッジが「何 Hz へ」を言うので、ここは素性に専念する
        guard case .ready = readiness[pad] else { return source }
        guard info.wasResampled else { return "\(source)・\(fmt(info.sourceDuration))" }
        // SRC がかかった席は**変換先も出す** — ここが食い違いの見えるところ
        return "\(source) → \(rateLabel(info.preparedRate))・\(fmt(info.sourceDuration))"
    }

    /// `44100` → `44.1k` / `192000` → `192k`（端数のあるレートも潰さない）
    private func rateLabel(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded()
            ? String(format: "%.0fk", k)
            : String(format: "%.1fk", k)
    }

    private func detailLine(_ info: LadySampler.SampleInfo) -> String {
        let mb = Double(info.bytes) / 1_048_576
        let source = "元: \(Int(info.sourceRate)) Hz / \(info.formatLabel)"
            + " / \(info.sourceChannels) ch / \(info.sourceFrames) フレーム / .\(info.fileType)"
        let memory = "メモリ: \(Int(info.preparedRate)) Hz mono"
            + " / \(info.preparedFrames) フレーム / \(String(format: "%.1f", mb)) MB"
        let note = info.wasResampled ? "エンジンのレートへ変換済み" : "元のまま（変換不要）"
        return [source, memory, note].joined(separator: "\n")
    }

    private func fmt(_ seconds: Double) -> String {
        seconds >= 60
            ? String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
            : String(format: "%.1fs", seconds)
    }

    /// AU の状態を画面へ写す。
    /// ⚠️ 音量は席ごとに聞かず `padStates()` で **1 回にまとめる** — ロックの
    /// 向こう側でオーディオのレンダースレッドが待っている
    /// 席ごとの波形包絡。
    /// ⚠️ **`padStates()` に混ぜない** — あれは 60fps で呼ばれるが、包絡は
    /// **変換されたときにしか変わらない**（2048 × 2 × 8 席を毎フレーム
    /// コピーすることになる）
    /// 測った grid の幅（列数の判断に使う）
    @State private var gridWidth: CGFloat = 0

    @State private var envelopes = [LadySampler.PeakEnvelope?](
        repeating: nil, count: LadySampler.padCount)

    private func sync() {
        names = sampler.sampleNames
        let states = sampler.padStates()
        gains = states.map(\.gain)
        readiness = states.map(\.readiness)
        positions = states.map(\.position)
        playingPads = states.map(\.isPlaying)
        // 鳴っている席が 1 つでもあれば速める（止まれば戻す）
        let wanted = Self.pollInterval(anyPlaying: playingPads.contains(true))
        if interval != wanted { interval = wanted }
        let nextInfos = sampler.sampleInfos
        // ⚠️ **素材が変わったときだけ包絡を取り直す**。`SampleInfo` が変化の合図 —
        // レートが変わって再変換されれば `preparedRate` が動くので、
        // **包絡も一緒に取り直される**（`PreparedSample` の不変式に乗る）
        if nextInfos != infos {
            for pad in 0..<LadySampler.padCount {
                envelopes[pad] = sampler.envelope(pad: pad)
            }
        }
        infos = nextInfos
        effects = sampler.effectStates()
    }
}
