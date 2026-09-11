//! ROTO SysEx の opcode 分類。
//!
//! 生フレームの配列添字をここに閉じ込め、`RotoService` には分類後の
//! 状態遷移と応答だけを残す。自動応答そのものは即時性が要るため扱わない。

import RotoKit

enum RotoSysExRoute: Equatable {
    case hello
    case firmwareNotice
    case dawConnected
    case controlMapped
    case pluginFace
    case pluginPage(forward: Bool)
    case pluginSelected
    case mixFace
    case selectButton
    case observedTrack(index: Int?)
    case mixerSetup(payload: [UInt8])
    case unknown

    /// hello は毎秒届くため、通常の受信ログから除外する。
    static func isHello(_ frame: [UInt8]) -> Bool {
        frame.count >= 7 && frame[5] == 0x0A && frame[6] == 0x02
    }

    /// 0C 01 はフラッシュロードの開始なので、settle の材料には数えない。
    static func marksDeviceActivity(_ frame: [UInt8]) -> Bool {
        frame.count >= 7 && (frame[5], frame[6]) != (0x0C, 0x01)
    }

    static func decode(_ frame: [UInt8]) -> Self? {
        guard Roto.isRoto(frame), frame.count >= 7 else { return nil }
        switch (frame[5], frame[6]) {
        case (0x0A, 0x02):
            return .hello
        case (0x0A, 0x0E):
            return .firmwareNotice
        case (0x0A, 0x0C):
            return .dawConnected
        case (0x0B, 0x0B):
            return .controlMapped
        case (0x0B, 0x01):
            return .pluginFace
        case (0x0A, 0x14), (0x0A, 0x15):
            return .pluginPage(forward: frame[6] == 0x15)
        case (0x0B, 0x07):
            return .pluginSelected
        case (0x0C, 0x02):
            return .mixFace
        case (0x0B, 0x15):
            return .selectButton
        case (0x0A, 0x09):
            let index = frame.count >= 9
                ? Int(frame[7]) << 7 | Int(frame[8])
                : nil
            return .observedTrack(index: index)
        case (0x0C, 0x01):
            return .mixerSetup(payload: Array(frame.dropFirst(7).dropLast()))
        default:
            return .unknown
        }
    }
}
