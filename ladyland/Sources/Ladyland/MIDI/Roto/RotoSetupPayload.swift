import Foundation
import MidistageClient

/// 冊全体の希望値。実機の読み戻しや席単位の差分は midistaged が担当する。
struct RotoSetupPayload: Equatable, Sendable {
    let setup: Int
    let content: SetupContent
}

extension RotoMidiSetupExport {
    /// 既存 builder とサービス契約の境界。JSON export の基準形は変えない。
    static func servicePayload(_ book: Book) throws -> RotoSetupPayload {
        guard MIDIUseSession.rotoSetups.contains(book.setupIndex) else {
            throw MIDIUseError.rotoConfigurationFailed("Ladyland の冊 0–3 だけを書き込めます。")
        }
        func check(control: Int, channel: Int, cc: Int, colors: [UInt8]) throws {
            guard (0...31).contains(control), (1...16).contains(channel), (0...127).contains(cc),
                  colors.allSatisfy({ $0 <= 82 }) else {
                throw MIDIUseError.rotoConfigurationFailed("ROTO の席・チャンネル・CC・色が範囲外です。")
            }
        }
        guard Set(book.knobs.map(\.controlIndex)).count == book.knobs.count,
              Set(book.buttons.map(\.controlIndex)).count == book.buttons.count else {
            throw MIDIUseError.rotoConfigurationFailed("ROTO の同じ席に複数の設定があります。")
        }
        // KDL: name = 印字可能な ASCII 12 字。非対応の字は ? へ、長い名前は切る。
        func name(_ value: String) -> String {
            String(value.unicodeScalars.prefix(12).map { scalar in
                (32...126).contains(scalar.value) ? Character(scalar) : Character("?")
            })
        }
        let knobs = try book.knobs.map { knob in
            try check(control: knob.controlIndex, channel: knob.channel, cc: knob.cc, colors: [knob.colorScheme])
            return KnobConfig(control: knob.controlIndex, mode: .cc7, channel: knob.channel,
                              param: knob.cc, max: 127, name: name(knob.name), color: Int(knob.colorScheme),
                              haptics: .smooth(indents: []))
        }
        let switches = try book.buttons.map { button in
            try check(control: button.controlIndex, channel: button.channel, cc: button.cc,
                      colors: [button.colorScheme, button.ledOn, button.ledOff])
            return SwitchConfig(control: button.controlIndex, mode: .cc7, channel: button.channel,
                                param: button.cc, max: 127, name: name(button.name), color: Int(button.colorScheme),
                                ledOn: Int(button.ledOn), ledOff: Int(button.ledOff),
                                action: button.toggle ? .toggle : .push)
        }
        // 未掲載席はサービス側が CLEAR。空席を別の希望値で補完しない。
        return RotoSetupPayload(setup: book.setupIndex,
                                content: SetupContent(name: name(book.name), knobs: knobs, switches: switches))
    }
}
