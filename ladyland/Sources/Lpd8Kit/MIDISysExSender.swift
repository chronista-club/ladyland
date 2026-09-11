//! CoreMIDI SysEx 送信（Ladyland / RigBench 共用）。
//!
//! MIDISendSysex の完了コールバックを一級市民として扱う — 「送った」ではなく
//! 「ドライバが送り切った」時刻が取れる。これが LedBus の completion-gated
//! 送信のゲートであり、RigBench ではバックプレッシャの観測点になる
//! （LPD8 実測: サービス ≈107ms/frame ≈ 9-10fps が上限）。

import CoreMIDI
import Foundation

public enum MIDISysExError: Error, CustomStringConvertible {
    case clientCreate(OSStatus)
    case endpointNotFound(String, available: [String])

    public var description: String {
        switch self {
        case .clientCreate(let status):
            return "MIDI クライアント作成に失敗 (\(status))"
        case .endpointNotFound(let fragment, let names):
            return "'\(fragment)' に一致する MIDI エンドポイントが無い。接続中: \(names.joined(separator: ", "))"
        }
    }
}

public enum MIDISysExSender {
    public static func makeClient(_ name: String) throws -> MIDIClientRef {
        var client = MIDIClientRef()
        let status = MIDIClientCreate(name as CFString, nil, nil, &client)
        guard status == noErr else { throw MIDISysExError.clientCreate(status) }
        return client
    }

    /// 表示名の部分一致（大文字小文字無視）で MIDI 宛先を探す
    public static func destination(matching fragment: String) throws -> MIDIEndpointRef {
        try find(fragment, count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination)
    }

    /// 表示名の部分一致（大文字小文字無視）で MIDI ソースを探す
    public static func source(matching fragment: String) throws -> MIDIEndpointRef {
        try find(fragment, count: MIDIGetNumberOfSources(), get: MIDIGetSource)
    }

    /// 生の短い MIDI メッセージ（CC など）を送る。SysEx とは経路が別で、
    /// ROTO のモーター位置は**この 14bit CC**で送る（doc 20 §5）
    public static func sendRaw(_ bytes: [UInt8], to dest: MIDIEndpointRef) {
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, bytes.count, bytes)
        MIDISend(sharedPort(), dest, &packetList)
    }

    /// 生 MIDI 送信用のポート（1 度作って使い回す）
    private static let rawPort: MIDIPortRef = {
        var port = MIDIPortRef()
        if let client = try? makeClient("lpd8kit-raw") {
            MIDIOutputPortCreate(client, "raw" as CFString, &port)
        }
        return port
    }()

    private static func sharedPort() -> MIDIPortRef { rawPort }

    /// SysEx を非同期送信する。completion にはドライバ完了までの ms が渡る
    /// （CoreMIDI のスレッドから呼ばれる — 受け側でメインへ hop すること）
    public static func send(
        _ bytes: [UInt8],
        to dest: MIDIEndpointRef,
        completion: (@Sendable (_ latencyMs: Double) -> Void)? = nil
    ) {
        let dataPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        dataPtr.update(from: bytes, count: bytes.count)
        let ctx = RequestContext(completion: completion, data: dataPtr)
        let reqPtr = UnsafeMutablePointer<MIDISysexSendRequest>.allocate(capacity: 1)
        reqPtr.initialize(to: MIDISysexSendRequest(
            destination: dest,
            data: UnsafePointer(dataPtr),
            bytesToSend: UInt32(bytes.count),
            complete: false,
            reserved: (0, 0, 0),
            completionProc: sysexCompletion,
            completionRefCon: Unmanaged.passRetained(ctx).toOpaque()
        ))
        let status = MIDISendSysex(reqPtr)
        if status != noErr {
            NSLog("MIDISendSysex error: %d", status)
        }
    }

    private static func find(
        _ fragment: String, count: Int, get: (Int) -> MIDIEndpointRef
    ) throws -> MIDIEndpointRef {
        var names: [String] = []
        for i in 0..<count {
            let endpoint = get(i)
            let name = displayName(of: endpoint) ?? "(unknown)"
            names.append(name)
            if name.localizedCaseInsensitiveContains(fragment) { return endpoint }
        }
        throw MIDISysExError.endpointNotFound(fragment, available: names)
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
        else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// 1 リクエスト分の寄生データ（送信時刻・バッファ）。完了コールバックで解放する
private final class RequestContext {
    let completion: (@Sendable (Double) -> Void)?
    let sentAtNs: UInt64
    let data: UnsafeMutablePointer<UInt8>

    init(completion: (@Sendable (Double) -> Void)?, data: UnsafeMutablePointer<UInt8>) {
        self.completion = completion
        self.sentAtNs = DispatchTime.now().uptimeNanoseconds
        self.data = data
    }
}

private let sysexCompletion: MIDICompletionProc = { reqPtr in
    guard let refCon = reqPtr.pointee.completionRefCon else { return }
    let ctx = Unmanaged<RequestContext>.fromOpaque(refCon).takeRetainedValue()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - ctx.sentAtNs) / 1_000_000
    ctx.completion?(ms)
    ctx.data.deallocate()
    reqPtr.deallocate()
}
