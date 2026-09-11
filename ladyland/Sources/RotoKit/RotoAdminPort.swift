//! アドミンポートのシリアル I/O（POSIX、依存なし）。
//!
//! フレーミングは `RotoAdmin`（純粋層）、こちらは線の世話だけ。
//! RigBench の roto-admin と Ladyland 本体（直接焼き）が共有する。
//!
//! ## 掟: 瞬間芸（open → 用事 → close）
//!
//! **ポートを開いている間、実機は MIDI モードの CC 送出を止める**
//! （実測 2026-08-12 — ROTO-SETUP の罠の真の主語はこれだった。close で即復帰、
//! 差し直し不要）。開きっぱなしの常駐は絶対にしない — `withPort` が
//! close を構造的に保証する。
//!
//! ポートの特定は総当たりプローブ: /dev/cu.usbmodem* に GET_FW_VERSION を
//! 撃ち、正しく答えたものがアドミンポート（2 本目のデバッグコンソールは
//! テキストしか流さないので自然に外れる）。

import Darwin
import Foundation

public enum RotoAdminPortError: Error, CustomStringConvertible {
    case notFound(candidates: [String])
    case writeFailed(String)
    case timeout(String)
    case rejected(code: UInt8)

    public var description: String {
        switch self {
        case .notFound(let candidates):
            return candidates.isEmpty
                ? "シリアルポートが無い（/dev/cu.usbmodem* が空。実機は挿さっていますか）"
                : "GET_FW_VERSION に答えるポートが無かった（候補: \(candidates.joined(separator: ", "))。"
                    + "ROTO-SETUP が握っていないか確認）"
        case .writeFailed(let detail):
            return "シリアル書き込みに失敗（\(detail)）"
        case .timeout(let detail):
            return "応答タイムアウト（\(detail)）"
        case .rejected(let code):
            return "実機が拒否した（rc=\(String(format: "%02X", code))）"
        }
    }
}

/// 開いている間だけ生きるハンドル。`RotoAdminPort.withPort` からしか作れない —
/// close し忘れの形を作らない
public final class RotoAdminSession {
    private let fd: Int32
    public let path: String
    public let version: RotoAdmin.FwVersion
    private var parser = RotoAdmin.StreamParser()

    fileprivate init(fd: Int32, path: String, version: RotoAdmin.FwVersion) {
        self.fd = fd
        self.path = path
        self.version = version
    }

    fileprivate func close() {
        Darwin.close(fd)
    }

    public struct Reply {
        public let code: UInt8
        public let data: [UInt8]
        public var isOK: Bool { code == RotoAdmin.okCode }
    }

    /// 1 リクエスト = 1 応答の往復（公式と同じく in flight は常に 1 本）。
    /// 応答待ち中に届いた実機発コマンドは `onNotification` へ流す（既定は捨てる）
    public func transact(
        _ request: [UInt8], expecting: Int, timeout: TimeInterval = 2.0,
        onNotification: ((UInt8, UInt8, [UInt8]) -> Void)? = nil
    ) throws -> Reply {
        parser.expectResponse(bytes: expecting)
        let written = request.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else {
            throw RotoAdminPortError.writeFailed("\(written)/\(request.count)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for event in parser.feed(Self.readAvailable(fd)) {
                switch event {
                case .response(let code, let data):
                    return Reply(code: code, data: data)
                case .notification(let family, let sub, let data):
                    onNotification?(family, sub, data)
                }
            }
            usleep(10_000)
        }
        throw RotoAdminPortError.timeout("\(timeout) 秒")
    }

    /// START → 本体 → END の 3 連括弧（公式 configUpdateRequest の写し）。
    /// 設定書き込みは必ずこれで包む。**1 通でも拒否されたら投げる** —
    /// 黙って進むと「焼けたつもり」が残る（rc 確認漏れの実バグ 2026-08-12）
    public func configUpdate(_ request: [UInt8]) throws {
        for message in [RotoAdmin.startConfigUpdate(), request, RotoAdmin.endConfigUpdate()] {
            let reply = try transact(message, expecting: 0)
            guard reply.isOK else { throw RotoAdminPortError.rejected(code: reply.code) }
        }
    }

    fileprivate static func readAvailable(_ fd: Int32) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return [] }
        return Array(buffer[0..<count])
    }
}

public enum RotoAdminPort {
    /// 同時に開かない門番 — 焼き込み（数秒）と冊切替（一往復）が別スレッドから
    /// 重なっても、同じ tty へ書き込みが混ざらないよう直列化する
    private static let gate = DispatchQueue(label: "club.chronista.ladyland.roto-admin-port")

    /// **瞬間芸の入口** — 開いて、用事を済ませて、必ず閉じる。
    /// 開いている間は実機の CC が止まることを忘れない（数秒で済ませる）
    public static func withPort<T>(
        explicitPath: String? = nil, body: (RotoAdminSession) throws -> T
    ) throws -> T {
        try gate.sync {
            let session = try open(explicitPath: explicitPath)
            defer { session.close() }
            return try body(session)
        }
    }

    private static func open(explicitPath: String?) throws -> RotoAdminSession {
        let candidates: [String]
        if let explicitPath {
            candidates = [explicitPath]
        } else {
            candidates = (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
                .filter { $0.hasPrefix("cu.usbmodem") }
                .map { "/dev/\($0)" }
                .sorted() ?? []
        }
        var probed: [String] = []
        for path in candidates {
            guard let fd = openSerial(path) else {
                probed.append("\(path): open 不可")
                continue
            }
            var parser = RotoAdmin.StreamParser()
            parser.expectResponse(bytes: 10)
            let request = RotoAdmin.getFwVersion()
            let written = request.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if written == request.count, let version = awaitVersion(fd, &parser) {
                return RotoAdminSession(fd: fd, path: path, version: version)
            }
            close(fd)
            probed.append("\(path): 応答なし")
        }
        throw RotoAdminPortError.notFound(candidates: probed)
    }

    private static func awaitVersion(
        _ fd: Int32, _ parser: inout RotoAdmin.StreamParser
    ) -> RotoAdmin.FwVersion? {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            for event in parser.feed(RotoAdminSession.readAvailable(fd)) {
                if case .response(let code, let data) = event, code == RotoAdmin.okCode {
                    return RotoAdmin.FwVersion(data)
                }
            }
            usleep(10_000)
        }
        return nil
    }

    private static func openSerial(_ path: String) -> Int32? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        // **排他 open**（TIOCEXCL）— ladyland の焼きと RigBench の読み戻しが
        // 同じポートに同時に入ると応答ストリームが混線し、2 秒タイムアウトの
        // 連鎖で片方が死ぬ（実例 2026-08-13: 差分焼きが競合タイムアウトで
        // 影ごと捨てて追従停止）。2 番目の open を即 EBUSY にして
        // 「使用中」と分かる形で失敗させる
        guard ioctl(fd, UInt(TIOCEXCL)) == 0 else {
            close(fd)
            return nil
        }
        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            close(fd)
            return nil
        }
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
