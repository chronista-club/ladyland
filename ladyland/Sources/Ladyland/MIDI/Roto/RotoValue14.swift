//! ROTO の 14bit CC 値を組み立てる純粋層。
//!
//! MSB と LSB は別々の MIDI メッセージで届く。呼び出し側は SMART/PLUGIN と
//! MIX でインスタンスを分け、同じ番号を名乗る別のノブを混線させない。

struct RotoValue14 {
    static let maximum = 0x3FFF

    /// コントロール番号ごとに最後に届いた MSB を保持する。
    ///
    /// LSB のたびに消さない。MIDI は同じ MSB のまま LSB だけを更新できるため、
    /// 次の MSB が届くまでは直前の上位 7bit を使い続ける。
    private var msbByControl: [Int: UInt8] = [:]

    /// 1 バイトを受け取り、14bit 値が完成したときだけ返す。
    mutating func receive(control: Int, kind: RotoParam.Kind, value: UInt8) -> Int? {
        switch kind {
        case .msb:
            msbByControl[control] = value
            return nil
        case .lsb:
            guard let msb = msbByControl[control] else { return nil }
            return Int(msb) << 7 | Int(value)
        case .touch:
            return nil
        }
    }

    static func normalized(_ raw: Int) -> Double {
        min(1, max(0, Double(raw) / Double(maximum)))
    }
}
