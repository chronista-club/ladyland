//! インストゥルメントラック（design/06 §4）。
//!
//! AVAudioEngine に 8 スロット + ドラムスロットを常駐させる。
//! 全ノードを mainMixer に繋ぎっぱなしにし、MIDI ルーティングだけを切り替える
//! （鳴っていないノードはほぼ無負荷。cortex の「process は選択中+リリース中のみ」
//! に相当する自前スケジューリングは不要 — エンジンが面倒を見る）。
//!
//! 切替作法は cortex から持ち越し（design/06 §5-3）:
//! 旧スロットへ All Notes Off (CC123) + サスティンオフ (CC64=0) を全 16ch に送り、
//! リリースは自然に鳴り終わらせる。

import AVFoundation
import Combine

/// MIDI バイト列の生成 — 純関数（テスト対象）
enum MIDIBytes {
    /// 全 16ch への All Notes Off (CC123) + サスティンオフ (CC64=0)。
    ///
    /// サスティンペダルが踏まれたまま切り替わるとノートオフ後も鳴り続けるため、
    /// CC64=0 を各チャンネルで先に送る（cortex から持ち越した切替作法。design/06 §5-3）。
    static func allNotesOff() -> [[UInt8]] {
        (0..<16).flatMap { channel -> [[UInt8]] in
            let status = UInt8(0xB0 | channel)
            return [[status, 64, 0], [status, 123, 0]]
        }
    }
}

/// **出力バスをデバイスのレートへ追従させるか**（mako 指示 2026-08-06、
/// 実機で 44.1k 素材が 4.35 倍に間延びしたため）。
///
/// ## 既定は on（mako 裁定 2026-08-06「192000 で揃えよう」）
///
/// 端から端まで 192k で、**リアルタイム SRC が 1 つも挟まらない**のが本番の姿。
/// **実機（Zenith 2 / 4ch）で全段が揃ったことを確認済み**:
///
/// ```
/// device[start 前]: 192000 Hz / 4 ch（合流点へ渡す形式: 192000 Hz / 2 ch）
/// format[ロード直後]: AU 192000 / node 192000 / mixer 192000 / device 192000
/// ```
///
/// 鎖の内訳: バッファは読み込み時にオフライン変換（`99dea4a`）→ 出力バス
/// （`a052455`）→ FX 4 段（`9847bac`）→ 合流点（`f781983`）→ 出力。
///
/// ⚠️ **止めるのはロード時と切替時の両方**。片方だけ止めると半分だけ追従して
/// 最悪の状態（申告と実際が食い違ったまま）になる。
///
/// ⚠️ **`=0` は会場での最後の手段**。`init` の 44.1k のまま = バスもバッファも
/// 44.1k で**一貫する**（`99dea4a` の状態）ので、追従で何かあっても確実に鳴る。
/// この退避路は消さないこと。
///
/// ```bash
/// swift run -c release Ladyland                        # on（既定・本番）
/// LADYLAND_BUS_FOLLOW=0 swift run -c release Ladyland  # off（退避路）
/// ```
///
/// ⚠️ `99dea4a` の不変条件（メモリ上のバッファは常にエンジンのレートに対応済み）は
/// **どちらのモードでも成立している**。off では「エンジンのレート」が 44.1k、
/// というだけ
@MainActor
enum BusFollowing {
    /// **既定 on**。`LADYLAND_BUS_FOLLOW=0` でだけ切れる（`RenderMetering` と同じ作法）。
    /// `var` なのはテストが両モードを踏むため（本番では環境変数が唯一の入口）
    static var enabled = ProcessInfo.processInfo.environment["LADYLAND_BUS_FOLLOW"] != "0"

    /// 起動時に 1 行だけ出す（どちらで動いているかを後から辿れるように）
    static var describe: String {
        enabled
            ? "bus-follow: on — 出力バスをデバイスのレートへ追従させる（既定。"
                + "LADYLAND_BUS_FOLLOW=0 で切る）"
            : "bus-follow: off — バスは 44.1kHz 固定（LADYLAND_BUS_FOLLOW=0）"
    }
}

/// 楽器スロット 1 つ分の状態
@MainActor
final class InstrumentSlot: ObservableObject, Identifiable {
    let index: Int

    /// ロード済みの AU ノード（nil = 空スロット）
    @Published private(set) var audioUnit: AVAudioUnit?

    /// 表示名（空スロットは nil）
    @Published private(set) var displayName: String?

    /// スロットのマスター音量 0.0-1.0（↑↓ キーと GUI フェーダーが動かす）
    @Published var gain: Float = 0.8 {
        didSet { applyGain() }
    }

    /// ミュート。gain とは独立 — 解除でフェーダー位置がそのまま戻る。
    /// 主は ROTO MIXER 冊の TOGGLE ボタン（ボタン LED は外から動かせない
    /// 実測 2026-08-12 のため、実機が主・こちらは追従の一方向）。UI からも
    /// 切れるが、実機トグルとズレたらボタン 1 押しで再び一致する
    @Published var mute: Bool = false {
        didSet { applyGain() }
    }

    /// トラックカラー（ROTO 83 色パレットの index。nil = 未設定）。
    /// **席の属性であって楽器の属性ではない** — 差し替えても残る。
    /// Track 面で設定し、タイルのストライプと ROTO の焼き色に出る
    @Published var rotoColor: UInt8?

    /// トラック名（nil = プラグイン名にフォールバック）。
    /// rotoColor と同じく席の属性 — MIXER 冊の席名などの表示名になる
    @Published var customName: String?

    /// 表示に使うトラック名: **トラック名 > プラグイン名** の順（どちらも
    /// 無ければ nil — 呼び手が T 番号に落とす）
    var trackName: String? { customName ?? displayName }

    /// 出力ピークレベル 0.0-1.0（レベルメーター表示用。tap から ~23Hz で更新）
    ///
    /// 選択中でなくても更新される — 切替後のリリース（余韻）も
    /// メーターに見える。減衰は更新時に前値へ 0.7 を掛けて自然に落とす
    @Published private(set) var level: Float = 0

    /// Keystage ノブ → AU パラメータの顔つまみ割当（楽器ごと 2〜4 個が目安。
    /// design/06 §3 物理楽器なみシンプル）
    @Published var knobMappings: [FaceKnobMapping] = []

    /// この席の棚 — 非アクティブな draft たち（design/06 §8 Drafts）。
    /// アクティブ draft は棚に居ない = live のスロット状態そのもの。
    /// 差し替え（load）のたびに現在の姿が暗黙で棚に入るので音色は消えない
    @Published private(set) var drafts: [Draft] = []

    /// fullState の直近キャッシュ。常時保存はこれを読む — **保存のたびに
    /// AU へ fullState を問い合わせない**（fullState 取得はレンダースレッドと
    /// ロックを競合しうる。2026-08-01「パツパツいう」の解剖で、毎秒の
    /// 全 AU query が犯人だった）。再取得は音の節目だけ:
    /// ロード直後 / draft 操作 / プラグイン画面を閉じた時 / 終了時 / 書き出し
    private var cachedState: Data?

    /// AU に fullState を問い合わせてキャッシュを更新する（節目でだけ呼ぶ）
    func refreshStateCache() {
        guard let unit = audioUnit else {
            cachedState = nil
            return
        }
        cachedState = RackStore.encodeState(unit.auAudioUnit.fullState)
    }

    nonisolated var id: Int { index }

    init(index: Int) {
        self.index = index
    }

    fileprivate func attach(_ unit: AVAudioUnit, name: String) {
        audioUnit = unit
        displayName = name
        applyGain()
        installLevelTap(on: unit)
        applyMusicalContext()
    }

    /// **ホストのテンポをプラグインへ渡す**（mako 裁定 2026-08-05）。
    ///
    /// ladyland は AUv3 ホストなのに `musicalContextBlock` を一度も渡して
    /// いなかった。テンポ同期対応のプラグイン（Gadget のディレイ・LFO・
    /// アルペジオ）は**自前の既定 120 BPM で動いていた** — 「同期を切った
    /// 状態」がずっと続いていたことになる。
    ///
    /// ⚠️ このブロックは**レンダースレッドから呼ばれる**。ロックを取ると
    /// 優先度逆転を招くので、**BPM をキャプチャした定数として焼き込み**、
    /// テンポが変わったらブロックごと差し替える（AU 側が差し替えを同期する）
    private var musicalTempo: Double?

    /// テンポを差し替える。nil = 同期を切る（プラグインは自前の既定で動く）
    func setMusicalTempo(_ bpm: Double?) {
        guard musicalTempo != bpm else { return }
        musicalTempo = bpm
        applyMusicalContext()
    }

    private func applyMusicalContext() {
        guard let unit = audioUnit?.auAudioUnit else { return }
        guard let bpm = musicalTempo else {
            unit.musicalContextBlock = nil
            return
        }
        // 拍位置は渡さない（Clock からは「テンポ」しか取れない — 小節の頭が
        // どこかは分からない）。tempo だけでもディレイと LFO は同期する
        unit.musicalContextBlock = {
            currentTempo, timeSignatureNumerator, timeSignatureDenominator,
            currentBeatPosition, sampleOffsetToNextBeat, currentMeasureDownbeatPosition in
            currentTempo?.pointee = bpm
            timeSignatureNumerator?.pointee = 4
            timeSignatureDenominator?.pointee = 4
            currentBeatPosition?.pointee = 0
            sampleOffsetToNextBeat?.pointee = 0
            currentMeasureDownbeatPosition?.pointee = 0
            return true
        }
    }

    /// 中身を取り外して持ち出す（タイル並び替え用）。detach と違い
    /// engine からは外さない — ノードグラフは不変のまま、所属スロットだけ変わる。
    /// タップは必ず外す: installLevelTap のクロージャが旧スロットの self を
    /// 捕まえているため、移した先で張り直す必要がある
    fileprivate func releaseContents() -> SlotContents {
        let contents = SlotContents(
            audioUnit: audioUnit, displayName: displayName,
            gain: gain, mute: mute, rotoColor: rotoColor, customName: customName,
            knobMappings: knobMappings
        )
        audioUnit?.removeTap(onBus: 0)
        audioUnit = nil
        displayName = nil
        level = 0
        knobMappings = []
        return contents
    }

    /// 持ち出した中身を受け入れる（releaseContents と対）。
    /// gain を先に置いてから attach — attach 内の applyGain が正しい値で効く
    fileprivate func adoptContents(_ contents: SlotContents) {
        gain = contents.gain
        mute = contents.mute
        rotoColor = contents.rotoColor
        customName = contents.customName
        knobMappings = contents.knobMappings
        if let unit = contents.audioUnit {
            attach(unit, name: contents.displayName ?? "(unknown)")
        }
    }

    fileprivate func detach() {
        audioUnit?.removeTap(onBus: 0)
        audioUnit = nil
        displayName = nil
        level = 0
        // 割当は楽器に属する — 差し替えたら意味を失う（復元経路では
        // applySnapshot がこの後に上書きする）
        knobMappings = []
    }

    /// アドレスで AU パラメータを引く（顔つまみの適用先）
    func parameter(at address: UInt64) -> AUParameter? {
        audioUnit?.auAudioUnit.parameterTree?.parameter(withAddress: address)
    }

    /// 割当 UI 用の全パラメータ列挙（Gadget 系は数百になりうる → UI 側でページに畳む）
    var parameterList: [AUParameter] {
        audioUnit?.auAudioUnit.parameterTree?.allParameters ?? []
    }

    /// ノード出力にレベル計測タップを張る（mainMixer ではなく各ノード自身の
    /// バスなので、テストやデバッグ計測の tap と衝突しない）
    private func installLevelTap(on unit: AVAudioUnit) {
        unit.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }
            var peak: Float = 0
            for ch in 0..<channels {
                for i in 0..<frames {
                    peak = max(peak, abs(data[ch][i]))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // post-fader 表示: tap はゲイン適用前の生出力なので、表示時に
                // gain を掛ける（フェーダーを下げたらメーターも下がる = DAW の慣習）。
                // attack は即時、release は緩やか（メーターバリスティクス）
                self.level = max(peak * self.gain, self.level * 0.7)
            }
        }
    }

    private func applyGain() {
        // AVAudioUnit は AVAudioMixing に適合しており volume を直接持つ
        (audioUnit as? AVAudioMixing)?.volume = mute ? 0 : gain
    }

    /// MIDI バイト列を送る（ロード済みのときだけ）
    func sendMIDI(_ bytes: [UInt8]) {
        guard let unit = audioUnit, bytes.count >= 1 else { return }
        let status = bytes[0]
        let data1 = bytes.count > 1 ? bytes[1] : 0
        let data2 = bytes.count > 2 ? bytes[2] : 0
        if let instrument = unit as? AVAudioUnitMIDIInstrument {
            instrument.sendMIDIEvent(status, data1: data1, data2: data2)
        }
    }

    /// 全 16ch に All Notes Off (CC123) + サスティンオフ (CC64=0) を送る
    func allNotesOff() {
        for bytes in MIDIBytes.allNotesOff() {
            sendMIDI(bytes)
        }
    }

    /// 現在の状態のスナップショット（空スロットでも棚・席の属性・既定が
    /// あれば残す — 昇格直後の工房（live 空・棚あり）や、空にした席の
    /// 色・名前・既定を再起動で失わないため）。
    /// fullState は**キャッシュを読む** — ここで AU に問い合わせない
    /// （常時保存が毎秒呼ぶ経路。節目の refreshStateCache が鮮度を担保）
    func snapshot() -> SlotSnapshot? {
        guard let unit = audioUnit else {
            guard !drafts.isEmpty || defaultSnapshot != nil || rotoColor != nil
                || customName != nil
            else { return nil }
            // live は空（component 識別 0 = 空印。復元側はロードせず
            // 棚と席の属性だけ戻す）
            var snap = SlotSnapshot(
                index: index, componentType: 0, componentSubType: 0,
                componentManufacturer: 0, name: "", gain: gain, state: nil, knobs: nil)
            snap.mute = mute ? true : nil
            snap.rotoColor = rotoColor
            snap.customName = customName
            snap.drafts = drafts.isEmpty ? nil : drafts
            snap.defaultSnapshot = defaultSnapshot
            return snap
        }
        let desc = unit.audioComponentDescription
        var snap = SlotSnapshot(
            index: index,
            componentType: desc.componentType,
            componentSubType: desc.componentSubType,
            componentManufacturer: desc.componentManufacturer,
            name: displayName ?? "(unknown)",
            gain: gain,
            state: cachedState,
            knobs: knobMappings.isEmpty ? nil : knobMappings
        )
        snap.mute = mute ? true : nil
        snap.rotoColor = rotoColor
        snap.customName = customName
        snap.drafts = drafts.isEmpty ? nil : drafts
        snap.defaultSnapshot = defaultSnapshot
        return snap
    }

    /// スナップショットの音色 blob と gain を適用する（ロード済みが前提）
    func applySnapshot(_ snap: SlotSnapshot) {
        if let state = RackStore.decodeState(snap.state) {
            audioUnit?.auAudioUnit.fullState = state
            cachedState = snap.state  // 適用した blob がそのままキャッシュ
        }
        gain = snap.gain
        mute = snap.mute ?? false
        rotoColor = snap.rotoColor
        customName = snap.customName
        knobMappings = snap.knobs ?? []
        drafts = snap.drafts ?? []
        defaultSnapshot = snap.defaultSnapshot
    }

    // MARK: - Drafts（design/06 §8。棚の実体はここ、切替と昇格は Rack）

    /// live の現在の姿を draft として写し取る（空スロットは nil）。
    /// fullState はここで新鮮に取得する（draft 操作 = 音の節目）— ついでに
    /// キャッシュも更新する
    func captureDraft() -> Draft? {
        guard let unit = audioUnit else { return nil }
        refreshStateCache()
        let desc = unit.audioComponentDescription
        return Draft(
            id: UUID(),
            componentType: desc.componentType,
            componentSubType: desc.componentSubType,
            componentManufacturer: desc.componentManufacturer,
            name: displayName ?? "(unknown)",
            gain: gain,
            state: cachedState,
            knobs: knobMappings.isEmpty ? nil : knobMappings,
            savedAt: Date()
        )
    }

    /// 現在の姿を棚へ入れる（差し替え・draft 切替の直前に呼ばれる暗黙生成）
    fileprivate func stashDraft() {
        if let draft = captureDraft() {
            drafts.append(draft)
        }
    }

    /// **この席の既定**（mako 要望 2026-08-06「set default / load default が欲しい」）。
    ///
    /// draft と同じ中身（音色 + 割当）を持つが、性質が違う:
    ///
    /// | | draft | default |
    /// |---|---|---|
    /// | 作られ方 | 差し替えの直前に**暗黙生成** | **明示的に「覚えろ」** |
    /// | 使われ方 | 選ぶと棚から**消える**（1 回きり） | **何度でも戻れる** |
    ///
    /// ライブ前に基準の音を作って覚えておき、演奏で崩したら 1 手で戻す用途。
    /// 棚（`drafts`）と同じ列に保存されるので DB の変更は要らない
    @Published private(set) var defaultSnapshot: Draft?

    /// いまの姿を「この席の既定」として覚える（上書き）
    func rememberAsDefault() {
        defaultSnapshot = captureDraft()
    }

    /// 既定を捨てる
    func forgetDefault() {
        defaultSnapshot = nil
    }

    /// 棚から 1 着取り出す（見つからなければ nil）
    fileprivate func removeDraft(id: UUID) -> Draft? {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return nil }
        return drafts.remove(at: index)
    }

    /// 棚の最新を取り出す（昇格後の工房の着せ直し用）
    fileprivate func popLatestDraft() -> Draft? {
        drafts.popLast()
    }

    /// draft の音色 blob と gain・割当を適用する（ロード済みが前提）
    fileprivate func applyDraft(_ draft: Draft) {
        if let state = RackStore.decodeState(draft.state) {
            audioUnit?.auAudioUnit.fullState = state
            cachedState = draft.state
        }
        gain = draft.gain
        knobMappings = draft.knobs ?? []
    }

    /// 棚ごと入れ替える（タイル並び替え用 — 棚は席に付いて動く）
    fileprivate func exchangeDrafts(with other: InstrumentSlot) {
        swap(&drafts, &other.drafts)
    }
}

/// スロットの中身一式（並び替えで運ぶもの。level は運ばない —
/// タップ張り直し後に即再充填されるため）
fileprivate struct SlotContents {
    var audioUnit: AVAudioUnit?
    var displayName: String?
    var gain: Float
    var mute: Bool
    var rotoColor: UInt8?
    var customName: String?
    var knobMappings: [FaceKnobMapping]
}

/// ラック本体 — N トラック + ドラムスロット + 選択状態 + 表示窓
@MainActor
final class InstrumentRack: ObservableObject {
    /// トラック総数 N（8 列 × 8 バンク。mako 裁定 2026-08-01「rack に全部
    /// 表示・結構たくさん作っておく」— 全トラックが 1 画面のグリッドに見える。
    /// 2026-08-04 に 24 → 32、2026-08-09 に 32 → 64 へ拡張。⚠️ 空きスロットは
    /// AU を持たないので、増やしたぶんの起動・保存コストはほぼ無い）。
    ///
    /// ⚠️ **ROTO の MIX 面は 16 席まで**（`RotoParam.mixCells`）。17 番目から
    /// 先はデバイスに送れないので、MIX 面の投影は先頭 16 で打ち切っている
    /// （上限を超えて書き込んだらデバイスが停止し、電源を入れ直す羽目になった）
    static let trackCount = 64

    /// バンク幅 = グリッドの列数（数字キー 1-8 / LED パッドと対応）
    static let visibleCount = 8

    /// バンク数 = グリッドの行数
    static var bankCount: Int { trackCount / visibleCount }

    let engine = AVAudioEngine()

    let slots: [InstrumentSlot]
    let drumSlot: InstrumentSlot

    /// **楽器が自分から「音の節目」を知らせてきたとき**の通知先
    /// （AppState が重い保存を配線する）。
    ///
    /// 普通の AU はプラグイン画面を閉じた瞬間が節目になるが、**画面を閉じない
    /// 楽器**（focus pane 常設の Lady Sampler）はその機会が無い。
    /// ホストが察する術は無いので、楽器側から言ってもらう
    var onInstrumentStateChanged: (() -> Void)?

    /// 選択中のスロット。切替時に旧スロットへ All Notes Off を送る
    @Published private(set) var selected = 0

    /// アクティブバンクの先頭 index — 選択のいる行（導出値。数字キー 1-8 /
    /// LED パッドはこの行に対応する。表示窓時代の windowStart の後継）
    var bankStart: Int { (selected / Self.visibleCount) * Self.visibleCount }

    /// ユーザーが選んだ出力デバイスの UID（nil = 既定 = L6max pin → OS 既定）。
    /// 永続化され、次回起動時の restore で再適用される（design/06 §8）
    @Published private(set) var outputDeviceUID: String?

    /// カタログ（起動時に列挙、deny list 適用済み）
    let catalog: [InstrumentComponent]

    /// マスターリミッター（Apple PeakLimiter）。複数スロットの合算が
    /// 0dBFS を超えたときのハードクリップを防ぐ（2026-08-01 mako 報告
    /// 「結構クリップする」— gain 100+95+80… の同時発音は素で超える）。
    /// 経路: slots → mainMixer → limiter → output
    /// **サンプラー後段のエフェクト 4 段**（mako 裁定 2026-08-06「CC の方はその
    /// プラグインの後にかけるエフェクトを切り替えるのに使う」）。
    ///
    /// ⚠️ **常に繋いでおいて `bypass` で切る**。挿し替えるとエンジンを止めることに
    /// なり、演奏中に音が途切れる。4 段ぶんの CPU は常に払うが、Apple 標準の
    /// エフェクトは bypass 中ほぼ無負荷
    let samplerEffects: [AVAudioUnitEffect] = [
        kAudioUnitSubType_Delay,
        kAudioUnitSubType_MatrixReverb,
        kAudioUnitSubType_Distortion,
        kAudioUnitSubType_LowPassFilter,
    ].map { subType in
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = subType
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        let effect = AVAudioUnitEffect(audioComponentDescription: desc)
        effect.bypass = true  // 既定は素通し — 挿しただけで音が変わるのは事故
        return effect
    }

    /// **サンプラーが控えた「鳴らなかった理由」を汲む係**（2026-08-06）。
    ///
    /// 空打ち / 音量ゼロ / STOP はリアルタイム経路では文字にできない
    /// （`LadySampler.padEvents`）ので、AU が控えたものをここで `debug.log` へ流す。
    ///
    /// ⚠️ **画面に持たせない**。サンプラーのペインを閉じていても
    /// 「後から何が起きたか分かる」（design/06 §1 の価値基準②）が要る —
    /// ステージで起きたことを後から読めることが、この仕組みの目的だった
    private var samplerEventTimer: Timer?

    let masterLimiter: AVAudioUnitEffect = {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Effect
        desc.componentSubType = kAudioUnitSubType_PeakLimiter
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }()

    init() {
        slots = (0..<Self.trackCount).map(InstrumentSlot.init)
        // ドラムは「index = トラック総数」の規約（rack.json の新旧互換もこの規約で
        // 解決する — 旧ファイルは総数 8 の時代なので drum=8 が自然に一致する）
        drumSlot = InstrumentSlot(index: Self.trackCount)
        // **自作シンセをプロセス内に登録**（mako 要望 2026-08-05）。
        // カタログを組む前にやること — 後だと列挙に間に合わない
        LadySynth.register()
        LadySampler.register()
        catalog = PluginCatalog.instruments()
        // 登録がカタログに届いたかを残す（`registerSubclass` はプロセス内
        // 登録なので、`AVAudioUnitComponentManager` が拾うかは実測でしか分からない）
        let found = catalog.contains { $0.name == LadySynth.displayName }
        NSLog(
            "synth: %@ を登録 — カタログに%@（全 %d 機種）",
            LadySynth.displayName, found ? "出た" : "**出なかった**", catalog.count)
    }

    /// グリッドの行（バンク）ごとのスロット列
    var slotRows: [[InstrumentSlot]] {
        stride(from: 0, to: Self.trackCount, by: Self.visibleCount).map { start in
            Array(slots[start..<(start + Self.visibleCount)])
        }
    }

    /// 選択カーソルを相対移動する（Cmd+矢印。±1 = 左右、±visibleCount =
    /// 行ジャンプ。全体をラップ — 2 行なら ↑↓ は行トグルになる）
    func selectOffset(_ delta: Int) {
        let count = Self.trackCount
        select(((selected + delta) % count + count) % count)
    }

    /// エンジンを開始する（起動時に一度）
    func start() throws {
        // マスターリミッターを mainMixer と output の間に常設する
        // （暗黙の mainMixer → output 接続を明示接続で置き換える）
        // サンプラー後段の 4 段も先に attach しておく（繋ぐのはロード時）
        NSLog("%@", BusFollowing.describe)
        NSLog("%@", RotoService.describeFlags)
        NSLog("%@", KeystageService.Handshake.describe)
        samplerEffects.forEach(engine.attach)
        engine.attach(masterLimiter)

        // ⚠️ **デバイスの固定を先にやる**（2026-08-06、実機で `mixer 44100` が出た）。
        //
        // `engine.mainMixerNode` は **lazy で、初回アクセス時のフォーマットで
        // 生まれて固定される**。以前はこの `pin` より前に mainMixer へ触っていたので、
        // **OS 既定の 44.1kHz で生まれていた** — AU が 192k で回るところまで
        // 直っても、`AU 192k → FX → mixer 44.1k → limiter → output 192k` と
        // **合流点で往復**して 192/32 の意味が失われていた。
        //
        // 出力を L6max に固定（不在なら OS 既定のまま = fail-open。
        // 自宅開発とライブリグで同じビルドが動く）
        OutputDevice.pin(nameContains: "L6max", engine: engine)

        // ⚠️ **共有ノードなので off では触らない**。全楽器（KORG も第三者 AU も）が
        // ここを通るので、既定では従来どおり `nil`（= ノードの現在値）で繋ぐ
        let mixerFormat = BusFollowing.enabled ? deviceFormat() : nil
        // 🧪 **`start()` の前後で値が違うか**を 1 回の起動で確定させる
        // （2026-08-06、実機で `mixer 44100` が残った件の切り分け）
        // 🧪 **チャンネル数も出す** — 3ch 以上だと `deviceFormat()` が nil を
        // 返していた（`deviceFormat` の説明）。真因がここだったので残す
        let probe = engine.outputNode.outputFormat(forBus: 0)
        NSLog(
            "device[start 前]: %.0f Hz / %u ch（合流点へ渡す形式: %@）",
            probe.sampleRate, probe.channelCount,
            mixerFormat.map { String(format: "%.0f Hz / %u ch", $0.sampleRate, $0.channelCount) }
                ?? "なし（追従しない）")
        connectMixerChain(format: mixerFormat)

        do {
            try engine.start()
        } catch {
            // ⚠️ **fail-open**。明示フォーマットが原因かもしれないので、
            // 従来の繋ぎ方へ戻してもう一度だけ試す。ここも駄目なら呼び出し元へ
            // 投げる（起動時エラーとして画面に出る）
            NSLog(
                "engine: ⚠️ 明示フォーマットで始動できない（%@）— 従来の繋ぎ方で再試行",
                error.localizedDescription)
            connectMixerChain(format: nil)
            try engine.start()
        }
        let after = engine.outputNode.outputFormat(forBus: 0)
        NSLog("device[start 後]: %.0f Hz / %u ch", after.sampleRate, after.channelCount)

        // ⚠️ **デバイスが確定するのは `start()` の後**（AVAudioEngine の定番の罠）。
        // 前に読んだ `outputNode.outputFormat` はプレースホルダのことがあり、
        // その値で繋いでいたので**明示フォーマット自体が 44.1kHz だった**。
        // 掛かった後にもう一度読んで、食い違っていれば繋ぎ直す
        realignMixerChain()
        logMixerFormat(at: "起動")
    }

    /// **合流点をデバイスの実レートへ揃え直す**（`start()` の後に 1 回）。
    ///
    /// ⚠️ **既に合っていれば何もしない** — 余計な stop/start を作らない。
    /// 起動時の一度きりなので停止窓を挟んでも音は誰も聞いていないが、
    /// 無意味な瞬断は残さない。
    ///
    /// ⚠️ 停止窓の中でやるのは `5b057ee` と同じ理由 — `engine.connect` の
    /// ObjC 例外は Swift で捕まえられないが、**停止中なら交渉が `start()` まで
    /// 遅れて Swift の throw に化ける**
    private func realignMixerChain() {
        guard BusFollowing.enabled, let target = deviceFormat() else { return }
        let current = engine.mainMixerNode.outputFormat(forBus: 0)
        guard current.sampleRate != target.sampleRate else { return }  // 既に合っている

        NSLog(
            "mixer: 合流点が %.0f Hz のまま — %.0f Hz へ揃え直す",
            current.sampleRate, target.sampleRate)
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        connectMixerChain(format: target)
        if restart(wasRunning) { return }

        // ⚠️ **fail-open**。揃え直せなければ元の繋ぎ方へ戻して音を出し続ける
        NSLog("mixer: ⚠️ 揃え直しに失敗 — 従来の繋ぎ方へ戻す")
        connectMixerChain(format: nil)
        if !restart(wasRunning) {
            NSLog("mixer: ⚠️ 戻した後もエンジンが始動しない — 音が出ない状態")
        }
    }

    /// `mainMixer → masterLimiter → outputNode` を繋ぐ（起動時と追従で同じ手順）
    private func connectMixerChain(format: AVAudioFormat?) {
        engine.connect(engine.mainMixerNode, to: masterLimiter, format: format)
        engine.connect(masterLimiter, to: engine.outputNode, format: format)
    }

    /// いまのデバイスのレートで作った標準フォーマット（合流点に通す形）。
    ///
    /// ⚠️ **`standardFormatWithSampleRate:channels:` は 3ch 以上で `nil` を返す**
    /// （チャンネルレイアウトが要るため。実測 2026-08-06）。
    ///
    /// これが実機で `mixer 44100` が残った真因だった — **多チャンネルの
    /// インターフェース**（Zenith 2 / L6max）では `outputNode.channelCount` が
    /// 3 以上になり、この関数が `nil` を返していた。呼び出し側は `nil` を
    /// 「追従しない」と解釈するので、**合流点は `format: nil` で繋がれ 44.1k の
    /// まま**になり、`realignMixerChain` も `guard let target` で黙って抜けていた
    /// （だから「揃え直す」のログも出なかった）。
    ///
    /// 合流点は 2ch で足りる（`masterLimiter` も stereo）ので**2 に落とす**。
    /// デバイスが何チャンネル出そうと、こちらが決めるのはレートだけ
    private func deviceFormat() -> AVAudioFormat? {
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0 else { return nil }
        let channels = max(1, min(output.channelCount, 2))
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: output.sampleRate, channels: channels)
        else {
            NSLog(
                "mixer: ⚠️ %.0f Hz / %u ch のフォーマットを作れない — 追従を諦める",
                output.sampleRate, output.channelCount)
            return nil
        }
        return format
    }

    /// 合流点のレートをログに出す（`format[…]` の `mixer` と突き合わせる用）
    private func logMixerFormat(at moment: String) {
        // **FX 4 段も並べる** — 「192k の鎖に切れ目が無い」ことは、
        // 途中の段を 1 つでも見落とすと確かめられない。
        //
        // ⚠️ **繋がっていないときは値を出さない**。FX は `start()` で `attach`
        // するだけで、**繋ぐのはサンプラーをロードした時**。未接続ノードの
        // 既定値（44.1k）を並べると「FX も詰まっている」と誤読させる
        let samplerLoaded = (slots + [drumSlot]).contains {
            $0.audioUnit?.auAudioUnit is LadySampler
        }
        let fx =
            samplerLoaded
            ? samplerEffects
                .map { String(format: "%.0f", $0.outputFormat(forBus: 0).sampleRate) }
                .joined(separator: "/")
            : "未接続（サンプラー未ロード）"
        NSLog(
            "mixer[%@]: FX %@ / mainMixer %.0f / limiter %.0f / device %.0f",
            moment, fx,
            engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
            masterLimiter.outputFormat(forBus: 0).sampleRate,
            engine.outputNode.outputFormat(forBus: 0).sampleRate)
    }

    /// 出力デバイスを UID で切り替える（設定 UI と起動復元から呼ばれる）。
    ///
    /// 見つからなければ何もしない — **動作中のエンジンを不在デバイスのために
    /// 止めない**（挿し忘れ・抜線後の起動でも音が出続ける）。
    /// 不在で切替できなかった出力の UID（**後から現れたら適用する** —
    /// AirPods 等の Bluetooth は性質上いつも起動より後に繋がるので、
    /// 復元時の「現状維持」だけだと毎回手で選び直しになる。
    /// 実例 2026-08-22「GoFast Packing から音が出ない」。
    /// 挿抜リスナー（AppState）が一覧更新のたびにここを見て再試行する）
    private(set) var wantedOutputUID: String?

    @discardableResult
    func switchOutput(toUID uid: String) -> Bool {
        guard let device = OutputDevice.all().first(where: { $0.uid == uid }) else {
            NSLog("output: uid %@ が見つからない — 現状維持（現れたら切替）", uid)
            wantedOutputUID = uid
            return false
        }
        wantedOutputUID = nil
        // 切替の瞬断でノートが残らないように先に消音する
        slots.forEach { $0.allNotesOff() }
        drumSlot.allNotesOff()
        guard OutputDevice.select(id: device.id, engine: engine) else { return false }
        outputDeviceUID = uid
        followOutputRate()
        return true
    }

    /// サンプラーの控えを定期的に汲んでログへ流す。
    ///
    /// 0.5 秒に 1 回・**ふだんは空で返る**ので、演奏中の負荷は毎秒 2 回の
    /// ロック取得だけ。叩いた瞬間から遅くとも 0.5 秒でログに出る —
    /// 設営中の切り分け（「叩いたのに鳴らない」）はこの速さで足りる
    private func startSamplerEventDrain(_ sampler: LadySampler) {
        samplerEventTimer?.invalidate()
        samplerEventTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self, weak sampler] timer in
            guard let self, let sampler else {
                timer.invalidate()  // サンプラーを降ろしたら自分で店じまいする
                return
            }
            for message in sampler.drainEvents() { NSLog("%@", message) }
            MainActor.assumeIsolated { self.drainRenderStats() }
        }
    }

    /// **render のコストを `debug.log` へ流す**（mako 裁定 2026-08-06
    /// 「まず計測してから決める」）。
    ///
    /// 平均・最大・締切に対する占有率に直すのはここ（main）。RT 側は加算と
    /// max を控えるだけ（`RenderStats`）。**計測が切れていれば何も出ない**。
    ///
    /// 自作 AU（`LadySampler` / `LadySynth`）だけが対象 — 第三者プラグインの
    /// 中は測れない（測りたければ Instruments を使う）
    private func drainRenderStats() {
        guard RenderMetering.enabled else { return }
        var units: [RenderMetered] = []
        for slot in slots + [drumSlot] {
            if let metered = slot.audioUnit?.auAudioUnit as? RenderMetered {
                units.append(metered)
            }
        }
        for unit in units {
            guard let stats = unit.drainRenderStats() else { continue }
            // ⚠️ **判定は排出側（main）でやる。** RT 経路は加算と max を
            // 控えるだけのまま — そこに比較を足すと計測が音を削る
            let name = unit.meteredName
            let reason = RenderLogGate.reason(for: stats, previous: renderLogSeen[name])
            renderLogSeen[name] = RenderLogGate.Mark(stats)
            guard let reason else { continue }
            NSLog("%@%@", reason.prefix, stats.line(name))
        }
    }

    /// 楽器ごとの**前回の姿**（何が変わったかを見るため）。
    /// ⚠️ main からしか触らない
    private var renderLogSeen: [String: RenderLogGate.Mark] = [:]

    /// サンプラーが持つ on/off を実際の `bypass` へ写す。
    ///
    /// ⚠️ **切替のログはここで出す**（2026-08-06）。トグルを受けるのは CoreMIDI の
    /// 高優先度スレッドで、そこで NSLog を呼ぶとオーディオを削る
    /// （`LadySampler.padEvents` の説明）。ここは main なので安全 —
    /// しかも**実際に反映した値**を出せる
    func applySamplerEffects(_ sampler: LadySampler) {
        let states = sampler.effectStates()
        for (index, effect) in samplerEffects.enumerated() where index < states.count {
            let enabled = states[index]
            if effect.bypass == enabled {  // 変化したときだけ言う
                NSLog("sampler: FX%d を %@", index + 1, enabled ? "入れた" : "切った")
            }
            effect.bypass = !enabled
        }
    }

    /// **出力レートが変わったことを楽器へ伝える**（実測 2026-08-06）。
    ///
    /// ⚠️ `engine.stop()` → `start()` では **AU の `allocateRenderResources` が
    /// 呼ばれ直さない**。デバイスを 3 回切り替えてもサンプラーは 44.1kHz のまま
    /// 計算していて、Zenith 2 を 192kHz にした瞬間に 4.35 倍速になった。
    ///
    /// レートを自分で読める AU（AVAudioUnit のラッパー）は追従するが、
    /// **素の `AUAudioUnit` は教えてもらうしかない**
    /// **繋ぐ前にバスをデバイスのレートへ合わせる**（mako 裁定 2026-08-06）。
    ///
    /// 繋いだ後だと `setFormat` が通らないうえ、起動時に
    /// 「44.1k で変換 → 直後に再変換」の二度手間が起きる。
    ///
    /// ⚠️ **追従できる楽器なら種類を問わない。** ここを `LadySampler` で
    /// 絞っていたのが 2026-08-07 の 2 度目の取りこぼしだった。
    ///
    /// ⚠️ **off なら nil を返す**（`BusFollowing`）。バスは 44.1k のまま =
    /// バッファも 44.1k で一貫する。fail-open —
    /// 失敗しても 44.1k のまま繋いで音は出す
    private func alignedBusFormat(_ unit: AVAudioUnit) -> AVAudioFormat? {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard BusFollowing.enabled, rate > 0,
            let instrument = unit.auAudioUnit as? any EngineRateFollowing
        else { return nil }
        let bus = instrument.outputBusses[0]
        guard bus.format.sampleRate != rate,
            let next = AVAudioFormat(
                standardFormatWithSampleRate: rate, channels: bus.format.channelCount)
        else { return nil }
        do {
            try bus.setFormat(next)
            return next
        } catch {
            NSLog(
                "audio: ⚠️ 起動時の %.0f Hz 追従に失敗（%@）— 既定のまま続行",
                rate, error.localizedDescription)
            return nil
        }
    }

    func followOutputRate() {
        // ⚠️ off ならここでも止める（ロード時だけ止めると半分追従になる）
        guard BusFollowing.enabled else { return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0 else { return }

        // 追従が要る席だけ集める。**同レートなら何もしない** = エンジンも止めない
        var targets: [BusFollow] = []
        for slot in slots + [drumSlot] {
            // ⚠️ **具体型で絞らない**（実測 2026-08-07: `as? LadySampler` で
            // 絞っていたので LadySynth にレートが渡らず、192000/44100 = 4.35 倍
            // 音程がずれた）。`EngineRateFollowing` なら**楽器を足す人が
            // 適合を強制される**ので、同じ漏れが二度と起きない
            guard let unit = slot.audioUnit,
                let instrument = unit.auAudioUnit as? any EngineRateFollowing
            else { continue }
            let previous = instrument.outputBusses[0].format
            guard previous.sampleRate != rate else { continue }
            targets.append(
                BusFollow(unit: unit, instrument: instrument, previous: previous))
        }
        guard !targets.isEmpty else { return }

        // ⚠️ **エンジンを止めてからやる**（2026-08-06、fail-open の穴を塞ぐ）。
        //
        // `engine.connect` は Swift の `Error` を投げない — フォーマット不整合では
        // **ObjC の `NSException` を raise する**（`required condition is false: …`）。
        // Swift の `catch` はこれを捕まえられないので、走行中に繋ぎ替えると
        // **catch 節が走らずプロセスごと落ちる**。
        //
        // しかも繋ぎ替えは**必ず走行中に起きる**構造だった:
        // `switchOutput` → `OutputDevice.select` が stop → start まで済ませて返り、
        // **その後で**ここが呼ばれる。
        //
        // 停止中のエンジンはフォーマット交渉を `start()` まで遅らせるので、
        // **捕まえられない ObjC 例外が、捕まえられる Swift の throw に変わる**。
        // これで fail-open が意図どおり効くようになる
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        // ⚠️ **合流点も一緒に追従させる**（同じ停止窓に相乗り）。
        // ここを置いていくと `AU 192k → mixer 44.1k → output 192k` の往復が残り、
        // 速度は狂わないが 192/32 の意味が失われる
        let previousMixer = engine.mainMixerNode.outputFormat(forBus: 0)
        connectMixerChain(format: deviceFormat())

        let applied = applyBusRate(targets, to: rate)

        if applied.count == targets.count, restart(wasRunning) {
            logMixerFormat(at: "追従直後")
            applied.forEach { $0.instrument.refreshEngineRate() }
            NSLog("sampler: 出力バスを %.0f Hz へ追従させた（%d 席）", rate, applied.count)
            // **成功直後こそ確かめる** — setFormat が通っても接続に伝わっている
            // とは限らない（それが今の疑い）
            applied.forEach { logFormatViews($0.unit, at: "追従直後") }
            return
        }

        // ⚠️ **ここが fail-open の実体**。元の形式へ戻して繋ぎ直し、
        // 「前のレートのまま鳴り続ける」に着地させる
        NSLog("sampler: ⚠️ %.0f Hz への追従に失敗 — 元のレートへ戻す", rate)
        revertBusRate(applied)
        // 合流点も戻す（共有ノードなので、失敗を持ち越さない）
        connectMixerChain(format: previousMixer)
        if !restart(wasRunning) {
            // ここまで来たら打つ手が無い。**黙って無音にしない**ことだけはする
            NSLog("sampler: ⚠️ 戻した後もエンジンが始動しない — 音が出ない状態")
        }
        applied.forEach { $0.instrument.refreshEngineRate() }
    }

    /// 追従の対象 1 件（元の形式を覚えておく = 戻せるようにする）
    private struct BusFollow {
        let unit: AVAudioUnit
        /// ⚠️ **具体型で持たない** — ここを `LadySampler` にしていたのが
        /// 4.35 倍ずれの入口だった
        let instrument: any EngineRateFollowing
        let previous: AVAudioFormat
    }

    /// **エンジンを止めた状態で**バスの形式を書き換えて繋ぎ直す。
    /// 失敗した時点で打ち切り、**そこまでに適用できた分**を返す（戻す対象）
    private func applyBusRate(_ targets: [BusFollow], to rate: Double) -> [BusFollow] {
        var applied: [BusFollow] = []
        for target in targets {
            // 鳴らしたまま繋ぎ替えると、古いレートの音が一瞬漏れる
            target.instrument.silenceForRateChange()
            guard let next = AVAudioFormat(
                standardFormatWithSampleRate: rate,
                channels: target.previous.channelCount)
            else {
                NSLog("sampler: ⚠️ %.0f Hz のフォーマットを作れない", rate)
                return applied
            }
            do {
                // 繋ぎ替えの前に外す（render resources を握ったままでは通らない）
                engine.disconnectNodeOutput(target.unit)
                try target.instrument.outputBusses[0].setFormat(next)
                connectSamplerChain(target.unit, format: next)
                applied.append(target)
            } catch {
                NSLog(
                    "sampler: ⚠️ バスの形式を %.0f Hz にできない（%@）",
                    rate, error.localizedDescription)
                return applied
            }
        }
        return applied
    }

    /// 適用した分を元の形式へ戻す（**止まっている間に呼ぶこと**）
    private func revertBusRate(_ applied: [BusFollow]) {
        for target in applied {
            engine.disconnectNodeOutput(target.unit)
            try? target.instrument.outputBusses[0].setFormat(target.previous)
            connectSamplerChain(target.unit, format: target.previous)
        }
    }

    /// 止めていたエンジンを掛け直す。**始動できたかを返す** —
    /// `start()` は Swift の throw なので、ここで確実に拾える
    private func restart(_ wasRunning: Bool) -> Bool {
        guard wasRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("sampler: ⚠️ エンジンを掛け直せない — %@", error.localizedDescription)
            return false
        }
    }

    /// **同じフォーマットを 3 つの視点から見て並べる**（2026-08-06、実機で
    /// まだ間延びしていたため）。
    ///
    /// `setFormat` は成功しているのにエンジンが古いレートで引き続けていれば、
    /// **192k で作ったバッファが 44.1k で吐かれて 4.35 倍に間延びする**。
    /// どの層で嘘になっているかは、3 つを並べないと分からない:
    ///
    /// | 視点 | 意味 |
    /// |---|---|
    /// | AU | 自分はこのレートで回っているはずだ、という申告 |
    /// | **node** | **エンジンから見たノードの出力** — ここが AU と違えば `setFormat` が接続に伝わっていない |
    /// | mixer | 合流点。ここで SRC が挟まっているかが読める |
    /// | device | 出音の出口 |
    private func logFormatViews(_ unit: AVAudioUnit, at moment: String) {
        // ⚠️ **ここも絞っていた** — 診断器が synth を黙って飛ばしていたので、
        // 「AU と node が食い違い」の警告が synth については一度も出なかった
        guard let instrument = unit.auAudioUnit as? any EngineRateFollowing else { return }
        let au = instrument.outputBusses[0].format.sampleRate
        let node = unit.outputFormat(forBus: 0).sampleRate
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let device = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mark = abs(au - node) > 1 ? " ⚠️ AU と node が食い違い" : ""
        NSLog(
            "format[%@]: AU %.0f / node %.0f / mixer %.0f / device %.0f%@",
            moment, au, node, mixer, device, mark)
    }

    /// `sampler → FX×4 → mainMixer` を繋ぐ（ロード時と繋ぎ直しで同じ手順を使う）。
    ///
    /// ⚠️ **`format` を明示できるようにした**（2026-08-06）。`nil` は
    /// 「**ノードの現在の出力フォーマットを使う**」の意味で、`AVAudioUnit` 側が
    /// 古い値をキャッシュしていると `setFormat` が接続に伝わらない —
    /// AU は 192k のつもりなのにエンジンは 44.1k で引く、という食い違いになる
    /// （`95973c0` の `format[…]` 行で `AU 192000 / node 44100` として見える形）。
    ///
    /// 追従する時は **FX 各段と mainMixer への接続まで全部**同じフォーマットで通す。
    /// `AVAudioUnitEffect` が受け付けなければ `5b057ee` の fail-open が拾う
    private func connectSamplerChain(_ unit: AVAudioUnit, format: AVAudioFormat? = nil) {
        var previous: AVAudioNode = unit
        for effect in samplerEffects {
            engine.connect(previous, to: effect, format: format)
            previous = effect
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
    }

    /// 既定（L6max pin → OS 既定）へ戻す。UID の記憶も消す
    func resetOutputToDefault() {
        outputDeviceUID = nil
        wantedOutputUID = nil  // 既定へ戻す = 待っていた望みも捨てる
        slots.forEach { $0.allNotesOff() }
        drumSlot.allNotesOff()
        if let l6max = OutputDevice.all().first(where: { $0.name.contains("L6max") }) {
            _ = OutputDevice.select(id: l6max.id, engine: engine)
        } else if let def = OutputDevice.defaultOutputID() {
            _ = OutputDevice.select(id: def, engine: engine)
        }
        followOutputRate()
    }

    /// デバッグ用: 出力 RMS の監視タップを張る（selftest 時のみ呼ぶ）。
    ///
    /// mainMixer のバスに常設すると、テストや他の計測が tap を張れなくなる
    /// （1 バスに tap は 1 つ）ため、必要なときだけ opt-in する。
    func installDebugRMSTap() {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for i in 0..<frames { sum += data[i] * data[i] }
            let rms = (sum / Float(frames)).squareRoot()
            if rms > 0.0005 {
                NSLog("audio RMS %.4f", rms)
            }
        }
    }

    /// スロットを選択する（絶対 index）。旧スロットはリリースを鳴らし切る。
    /// 全トラックが常時見えているので追従スクロールは存在しない
    func select(_ index: Int) {
        guard (0..<Self.trackCount).contains(index), index != selected else { return }
        slots[selected].allNotesOff()
        selected = index
    }

    /// 順送り / 戻し（方向キー ←→。N 全域を巡る）
    func selectNext() { selectOffset(+1) }
    func selectPrevious() { selectOffset(-1) }

    /// スロット a と b の中身（楽器・名前・音量・つまみ割当）を入れ替える
    /// （タイル並び替え。design/06 §8 追補）。
    ///
    /// 位置＝同一性（index）は動かさない — ForEach の id・エディタキー・
    /// rack.json・LED パッド・数字キーの全対応が無傷。選択は楽器に追従する
    /// （selected==a → b）ため keyboard target の AU は変わらず、
    /// **All Notes Off 不要で音が切れない**。ドラム枠（index 8）は対象外
    func swapSlots(_ a: Int, _ b: Int) {
        guard a != b,
              (0..<Self.trackCount).contains(a),
              (0..<Self.trackCount).contains(b) else { return }
        let contentsA = slots[a].releaseContents()
        let contentsB = slots[b].releaseContents()
        slots[a].adoptContents(contentsB)
        slots[b].adoptContents(contentsA)
        // 棚は席に付いて動く（タイル = トラックの引っ越し。
        // 昇格は逆に「1 着だけ舞台へ」なので棚を持たない — 対比に注意）
        slots[a].exchangeDrafts(with: slots[b])
        if selected == a {
            selected = b
        } else if selected == b {
            selected = a
        }
    }

    /// 選択中スロットの参照
    var selectedSlot: InstrumentSlot { slots[selected] }

    /// 指定スロットにインストゥルメントをロードする（非同期）
    func load(_ component: InstrumentComponent, into slot: InstrumentSlot) async throws {
        try await load(description: component.description, name: component.name, into: slot)
    }

    /// AudioComponentDescription から直接ロードする（復元経路と共用）
    func load(
        description: AudioComponentDescription, name: String, into slot: InstrumentSlot
    ) async throws {
        // 差し替え時は旧ノードを外す
        unload(slot)

        let unit = try await AVAudioUnit.instantiate(with: description, options: [])
        guard unit is AVAudioUnitMIDIInstrument else {
            throw NSError(
                domain: "ladyland", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(name) は MIDI インストゥルメントではない"]
            )
        }
        engine.attach(unit)

        // ⚠️ **レートを合わせるのは楽器の種類と無関係**（実測 2026-08-07）。
        //
        // ここは 8/7 の 2 度目の取りこぼし。内側の `as? LadySampler` は直したのに、
        // **外側の門が `is LadySampler` のまま**だったので synth は `else` へ落ち、
        // `format: nil`（= 44.1k）で繋がれていた。実機で
        // `synth 44100Hz / 117 frames`（512 × 44100/192000 ≒ 117）が出ていたのが証拠。
        //
        // ⚠️ **繋ぎ方（FX 4 段 か mainMixer 直結か）と、レートを合わせるかは
        // 別の問い**。前者は楽器の種類で決まるが、後者は全楽器に効く。
        // 混ぜていたので、片方の分岐を直しても他方が残った
        let connectFormat = alignedBusFormat(unit)
        if unit.auAudioUnit is LadySampler {
            // **サンプラーだけ 4 段を通す** — `sampler → FX×4 → mainMixer`。
            // 段は常に繋がったままで、効くかどうかは `bypass` が決める
            connectSamplerChain(unit, format: connectFormat)
        } else {
            engine.connect(unit, to: engine.mainMixerNode, format: connectFormat)
        }
        slot.attach(unit, name: name)

        // ⚠️ **載せた直後にレートを取り直させる**（実測 2026-08-06）。
        // 繋いだ時点で出力バスの形式が決まるので、その値でバッファを揃える。
        // **デバイスのレートを渡してはいけない** — `followOutputRate` の説明
        (unit.auAudioUnit as? any EngineRateFollowing)?.refreshEngineRate()
        logFormatViews(unit, at: "ロード直後")

        // ⚠️ **サンプラーは自分から節目を知らせる**（実測 2026-08-06）。
        //
        // 重い保存（`fullState` の取り直し）が走るのは「プラグイン画面を閉じた」
        // 「終了時」「draft 操作」だけ。**focus pane は常設なので閉じる節目が
        // 来ない**ため、音を割り当てても記録されずに消えていた。
        // 普通のプラグインは画面を閉じる操作があるが、これは無い
        if let sampler = unit.auAudioUnit as? LadySampler {
            sampler.onSamplesChanged = { [weak self] in
                Task { @MainActor in self?.onInstrumentStateChanged?() }
            }
            // **AU の中からは自分の後段に手が届かない** — 状態はサンプラーが持ち、
            // bypass の反映はホストがやる
            sampler.onEffectsChanged = { [weak self, weak sampler] in
                Task { @MainActor in
                    guard let self, let sampler else { return }
                    self.applySamplerEffects(sampler)
                }
            }
            applySamplerEffects(sampler)
            startSamplerEventDrain(sampler)
        }

        // ロード直後は音の節目 — fullState キャッシュをここで初期化する
        // （復元/draft 適用の場合は直後の applySnapshot/applyDraft が上書き）
        slot.refreshStateCache()
    }

    /// 席を空にする（差し替えの前半と共用。mako 要望 2026-09-23
    /// 「右クリックで空にできるように」）。空の席では何もしない。
    ///
    /// 順序が重要: tap の除去（slot.detach 内）→ engine.detach。逆にすると
    /// 「NULL != engine」の NSException でクラッシュする
    /// （engine から外れたノードには removeTap できない）
    func unload(_ slot: InstrumentSlot) {
        guard let old = slot.audioUnit else { return }
        // 暗黙 draft 生成（design/06 §8 Drafts）: 外しても今の音色が
        // 消えない — 現在の姿を棚へ入れてから外す
        slot.stashDraft()
        slot.allNotesOff()
        slot.detach()
        engine.detach(old)
    }

    /// 全ロード済みスロットの fullState キャッシュを更新する
    /// （重い保存の直前にだけ呼ぶ — プラグイン画面を閉じた時 / 30 秒 / 終了時）
    /// 全 AU に fullState を問い合わせて控えを取り直す。
    ///
    /// ⚠️ **ここが重い保存の main コストの主役**（実測 2026-08-03: 24 台で
    /// 512-590ms。SQLite 書き込みの 250-350ms より大きい）。AU は main 前提の
    /// 相手なので逃がせない — だから**呼ぶ場面を節目だけに絞っている**
    /// （30 秒の定期保険は廃止。mako 裁定 2026-08-03）。
    /// 高い楽器を名指しできるよう、50ms を超えた席だけログに出す
    func refreshAllStateCaches() {
        func refresh(_ slot: InstrumentSlot) {
            guard slot.audioUnit != nil else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            slot.refreshStateCache()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if ms > 50 {
                NSLog(
                    "fullState 高: slot %d (%@) %.1fms", slot.index + 1,
                    slot.displayName ?? "?", ms)
            }
        }
        for slot in slots {
            refresh(slot)
        }
        refresh(drumSlot)
    }

    // MARK: - Drafts の切替と昇格（design/06 §8。mako 発案「工房と舞台の分離」）

    /// 棚の draft を着る。現在の姿は load 内の暗黙 stash で棚に入るので、
    /// 「試しに変えて、やっぱり戻る」が無損失に往復できる
    /// **この席の既定へ戻す**（mako 要望 2026-08-06）。
    ///
    /// ⚠️ draft と違って**消えない** — 何度でも戻れるのが「既定」の意味。
    /// 楽器が違っていればロードし直してから着せる（席に別の楽器が載っていても戻せる）
    func loadDefault(on slot: InstrumentSlot) async {
        guard let snapshot = slot.defaultSnapshot else { return }
        do {
            if slot.audioUnit == nil || slot.displayName != snapshot.name {
                try await load(description: snapshot.description, name: snapshot.name, into: slot)
            }
            slot.applyDraft(snapshot)
            NSLog("default: %@ を既定へ戻した", snapshot.name)
        } catch {
            NSLog("default: %@ の復元に失敗: %@", snapshot.name, String(describing: error))
        }
    }

    func activateDraft(withID id: UUID, on slot: InstrumentSlot) async {
        guard let draft = slot.removeDraft(id: id) else { return }
        do {
            try await load(description: draft.description, name: draft.name, into: slot)
            slot.applyDraft(draft)
        } catch {
            NSLog("draft: %@ の切替に失敗: %@", draft.name, String(describing: error))
        }
    }

    /// 昇格先の解決 — 純関数（テスト対象。状態を触らないので nonisolated）。
    /// 現在位置から前方へ探して最初の空席（ラップあり）。満席なら nil
    nonisolated static func promotionTarget(from index: Int, occupied: [Bool]) -> Int? {
        let count = occupied.count
        for step in 1..<count {
            let candidate = (index + step) % count
            if !occupied[candidate] { return candidate }
        }
        return nil
    }

    /// Cmd+Return: アクティブ draft（live の姿そのもの）を空きトラックへ
    /// **移動**し、選択もそこへ移る。工房には棚の最新 draft を着せ直す
    /// （棚が空なら空席のまま）。
    ///
    /// AU は releaseContents/adoptContents で席ごと移すため**音は切れない**
    /// （並び替えと同じ機構 — ルータの送り先は AU オブジェクト参照）。
    /// 棚は工房に残る: 昇格は「1 着だけ舞台へ」、引っ越し（swap）とは逆の作法
    @discardableResult
    func promoteActiveDraft() async -> Int? {
        let source = selectedSlot
        guard source.audioUnit != nil,
              let target = Self.promotionTarget(
                  from: selected, occupied: slots.map { $0.audioUnit != nil })
        else { return nil }

        let contents = source.releaseContents()
        slots[target].adoptContents(contents)
        selected = target  // focus 移動（弾いている AU はそのまま）

        // 工房の着せ直し（ここは async — 昇格と focus は上で確定済み）
        if let next = source.popLatestDraft() {
            do {
                try await load(description: next.description, name: next.name, into: source)
                source.applyDraft(next)
            } catch {
                NSLog("draft: 工房の着せ直しに失敗 (%@): %@", next.name,
                      String(describing: error))
            }
        }
        return target
    }

    // MARK: - 永続化（design/06 §2「再起動しても自分の楽器が並んでいる」）

    /// 復元先の解決 — 純関数（テスト対象）。ドラムは「index = 保存時の
    /// トラック総数」規約: 旧 rack.json（総数 8 の時代、trackCount 無し）でも
    /// drum=8 が自然に一致し、総数が変わっても壊れない
    enum RestoreTarget: Equatable {
        case drum
        case track(Int)
        case invalid
    }

    static func restoreTarget(snapIndex: Int, savedTrackCount: Int) -> RestoreTarget {
        if snapIndex == savedTrackCount { return .drum }
        if (0..<min(savedTrackCount, trackCount)).contains(snapIndex) {
            return .track(snapIndex)
        }
        return .invalid
    }

    /// ラック全体のスナップショットを取る
    func snapshot() -> RackSnapshot {
        var snaps = slots.compactMap { $0.snapshot() }
        if let drum = drumSlot.snapshot() {
            snaps.append(drum)
        }
        var snapshot = RackSnapshot(
            slots: snaps, selected: selected, outputDeviceUID: outputDeviceUID)
        snapshot.trackCount = Self.trackCount
        // windowStart は表示窓時代の遺物 — 全面グリッド化（2026-08-01）で
        // 導出値（bankStart）になったため、もう書かない（旧ファイルは読み飛ばす）
        return snapshot
    }

    /// スナップショットからラックを復元する（起動時に一度）
    ///
    /// 1 スロットの失敗（AU がアンインストールされた等）は該当スロットを
    /// 空のまま残して続行する — fail-open（design/06 §1「確実に動く」）。
    func restore(from snapshot: RackSnapshot) async {
        let savedTrackCount = snapshot.trackCount ?? 8  // 旧ファイル = 総数 8 の時代
        for snap in snapshot.slots {
            let slot: InstrumentSlot
            switch Self.restoreTarget(snapIndex: snap.index, savedTrackCount: savedTrackCount) {
            case .drum: slot = drumSlot
            case .track(let index): slot = slots[index]
            case .invalid: continue
            }
            // 空席 + 棚のみ（昇格直後の工房など）はロードせず棚だけ戻す
            if snap.componentType == 0 {
                slot.applySnapshot(snap)
                continue
            }
            do {
                try await load(description: snap.description, name: snap.name, into: slot)
                slot.applySnapshot(snap)
            } catch {
                NSLog("restore: slot %d (%@) failed: %@", snap.index + 1, snap.name,
                      String(describing: error))
            }
        }
        if (0..<Self.trackCount).contains(snapshot.selected) {
            selected = snapshot.selected
        }
        // 記憶した出力デバイスを最後に適用する。start() の L6max pin →
        // engine 稼働 → ここでランタイム切替、という順序なので
        // 「load が start より後」問題は構造的に起きない。不在ならスキップ
        if let uid = snapshot.outputDeviceUID {
            _ = switchOutput(toUID: uid)
        }
        NSLog("restore: %d slots restored", snapshot.slots.count)
    }

    /// Keystage からのノート系イベントを選択中スロットへ
    func routeKeyboard(_ bytes: [UInt8]) {
        selectedSlot.sendMIDI(bytes)
    }

    /// LPD8 からのノート系イベントをドラムスロットへ（持ち替えの影響を受けない）
    func routeDrums(_ bytes: [UInt8]) {
        drumSlot.sendMIDI(bytes)
    }
}
