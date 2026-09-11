//! ROTO から届く短い MIDI メッセージの分類。
//!
//! 生の status / CC の優先順位をここに閉じ込め、`RotoService` には分類後の
//! 状態更新だけを残す。分類は純粋で、MIDI の送受信やアプリ状態を持たない。

enum RotoShortRoute: Equatable {
    /// MIDI モード ch1: 顔つまみの席 CC。
    case midiSeat(cc: Int, value: UInt8)
    /// MIDI モード ch2 下半分: Track gain。
    case mixerGain(slot: Int, value: UInt8)
    /// MIDI モード ch2 上半分: Track 選択ボタン。
    case mixerButton(slot: Int, pressed: Bool)
    /// ch2 はすべて MIDI モードが受け止め、DAW 方言へ流さない。
    case midiModeIgnored
    /// Logic MIX 面の左右キー。現在は観測だけ。
    case mixArrow(forward: Bool, value: UInt8)
    /// MIX 面の RK1-8 を SMART ページ直選へ変換したもの。
    case smartPage(page: Int, pressed: Bool)
    /// Logic MIX 面の14bitノブ。
    case mixKnob(knob: Int, kind: RotoParam.Kind, value: UInt8)
    /// SMART/PLUGIN 面の14bitパラメータ。
    case parameter(control: Int, kind: RotoParam.Kind, value: UInt8)
    case ignored

    /// MIDI モードは値ストリーム用の別ログを持つため、DAW入力ログへ出さない。
    var isMidiMode: Bool {
        switch self {
        case .midiSeat, .mixerGain, .mixerButton, .midiModeIgnored:
            true
        default:
            false
        }
    }

    static func decode(
        status: UInt8, data1: UInt8, data2: UInt8,
        dialect: RotoDialect, smartPage: Int, pluginPage: Int
    ) -> Self {
        // MIDI モードは DAW 方言より先に受け止める。同じ CC を方言側へ
        // すり抜けさせると、Track 操作が音色パラメータへ誤配線される。
        if status == 0xB0, data1 < UInt8(KnobPages.seatCount) {
            return .midiSeat(cc: Int(data1), value: data2)
        }
        if status == 0xB1 {
            if data1 < UInt8(RotoMidiSetupExport.mixerTotalSlots) {
                return .mixerGain(slot: Int(data1), value: data2)
            }
            if data1 >= UInt8(RotoMidiSetupExport.mixerButtonCCBase) {
                return .mixerButton(
                    slot: Int(data1) - RotoMidiSetupExport.mixerButtonCCBase,
                    pressed: data2 > 0)
            }
            return .midiModeIgnored
        }

        // ch16 CC60/61 は MIX 面の左右キー。パラメータとして解釈しない。
        if status == 0xBF, data1 == 60 || data1 == 61 {
            return .mixArrow(forward: data1 == 61, value: data2)
        }
        if let page = RotoParam.decodeButton(status: status, cc: data1) {
            return .smartPage(page: page, pressed: data2 > 0)
        }

        // Logic の ch16 ノブは MIX 専用。Bitwig では同じ CC が PLUGIN 面なので、
        // 方言のパラメータ解決へ流す。
        if dialect.usesDirectSetters,
            let (knob, kind) = RotoParam.decodeKnob(status: status, cc: data1)
        {
            return .mixKnob(knob: knob, kind: kind, value: data2)
        }

        let decoded = dialect.resolveInput(
            status: status, cc: data1,
            smartCell: { RotoPageLayout.smartCell(page: smartPage, deviceCell: $0) },
            pluginCell: { RotoPageLayout.pluginCell(page: pluginPage, knob: $0) })
        guard let (control, kind) = decoded else { return .ignored }
        return .parameter(control: control, kind: kind, value: data2)
    }
}
