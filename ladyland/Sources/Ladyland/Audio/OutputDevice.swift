//! 出力デバイスの固定と切替（design/06 §4・§8、doc 05 S3 の持ち越し）。
//!
//! 起動時: ライブ本番で「OS 既定任せ」をやめ、L6max を名前で選んで出力先に固定する。
//! 見つからなければ OS 既定のまま続行する — fail-open（§1「確実に動く」。
//! 自宅開発時は Zenith 2 等で、本番リグでは L6max で、同じビルドが動く）。
//!
//! 実行中: 設定ウィンドウから UID で切替（stop → set → start。失敗時は
//! 旧デバイスへ戻して再開する — 音が出ない状態で放置しない）。

import AVFoundation
import CoreAudio

/// 出力可能デバイス 1 台分（UID は個体に紐づき再接続後も安定 — 永続化のキー）
struct AudioOutputDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum OutputDevice {
    /// 出力可能な全デバイスを列挙する
    static func all() -> [AudioOutputDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutput(id), let name = name(of: id), let uid = uid(of: id) else {
                return nil
            }
            return AudioOutputDeviceInfo(id: id, uid: uid, name: name)
        }
    }

    /// 名前の部分一致で出力デバイスを探し、エンジンの出力に固定する。
    /// 見つからなければ false（OS 既定のまま）。engine.start() の前に呼ぶこと。
    @discardableResult
    static func pin(nameContains fragment: String, engine: AVAudioEngine) -> Bool {
        guard let device = all().first(where: { $0.name.contains(fragment) }) else {
            NSLog("output: '%@' が見つからない — OS 既定のまま", fragment)
            return false
        }
        guard setCurrentDevice(device.id, engine: engine) else {
            NSLog("output: %@ への固定に失敗", device.name)
            return false
        }
        NSLog("output: %@ に固定", device.name)
        return true
    }

    /// 実行中エンジンの出力デバイスを切り替える（stop → set → start）。
    /// set か再 start に失敗したら旧デバイスへ戻して再開する。
    @discardableResult
    static func select(id: AudioDeviceID, engine: AVAudioEngine) -> Bool {
        let previous = currentDevice(engine: engine)
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        if setCurrentDevice(id, engine: engine) {
            do {
                if wasRunning { try engine.start() }
                NSLog("output: %@ へ切替", name(of: id) ?? "(unknown)")
                return true
            } catch {
                NSLog("output: 切替後の再開に失敗 (%@) — 旧デバイスへ戻す",
                      String(describing: error))
            }
        } else {
            NSLog("output: デバイス設定に失敗 — 旧デバイスへ戻す")
        }

        // 復帰路: 旧デバイスへ戻して鳴る状態を維持する
        if let previous { _ = setCurrentDevice(previous, engine: engine) }
        if wasRunning { try? engine.start() }
        return false
    }

    /// OS 既定の出力デバイス
    static func defaultOutputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != 0 else { return nil }
        return id
    }

    /// エンジンが**実際に**出力しているデバイスの情報（footer の誤ルート警告用）。
    /// 「選んだつもり」の UID ではなく実態を答える — 2026-08-01 の
    /// 「音が出ない（内蔵スピーカーに向いていた）」事故の再発防止
    static func currentInfo(engine: AVAudioEngine) -> AudioOutputDeviceInfo? {
        guard let id = currentDevice(engine: engine),
              let name = name(of: id), let uid = uid(of: id) else { return nil }
        return AudioOutputDeviceInfo(id: id, uid: uid, name: name)
    }

    /// リグの正規出力か（mako 裁定 2026-08-01: Zenith 2 / L6max 以外に
    /// 出ていたら footer に警告を出す）。判定は名前の部分一致 —
    /// L6max の pin と同じ作法
    static func isExpectedLiveOutput(name: String) -> Bool {
        name.contains("Zenith 2") || name.contains("L6max")
    }

    /// デバイス一覧の変化（挿抜）を監視する。ハンドラはメインキューで呼ばれる
    static func observeChanges(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { _, _ in handler() }
    }

    // MARK: - 内部

    fileprivate static func currentDevice(engine: AVAudioEngine) -> AudioDeviceID? {
        guard let audioUnit = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            &size
        ) == noErr, id != 0 else { return nil }
        return id
    }

    private static func setCurrentDevice(_ id: AudioDeviceID, engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.outputNode.audioUnit else { return false }
        var deviceID = id
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        stringProperty(of: id, selector: kAudioObjectPropertyName)
    }

    /// デバイス UID（個体識別子。名前と違い装飾や重複がなく、永続化に使える）
    private static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(
        of id: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }
}
