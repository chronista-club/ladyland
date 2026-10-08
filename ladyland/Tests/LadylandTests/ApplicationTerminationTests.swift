import AppKit
import Testing
@testable import Ladyland

@MainActor @Suite("MIDI session shutdown")
struct ApplicationTerminationTests {
    @Test("終了要求が重なっても切断は一度。完了前には終了を許可しない")
    func waitsForSession() async throws {
        let delegate = AppDelegate()
        var pending: CheckedContinuation<Void, Never>?
        var cleanupCalls = 0
        var replies: [Bool] = []
        delegate.prepareForTermination = {
            cleanupCalls += 1
            await withCheckedContinuation { pending = $0 }
        }
        delegate.replyToTermination = { _, allowed in replies.append(allowed) }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let completion = try #require(pending)
        #expect(cleanupCalls == 1)
        #expect(replies.isEmpty)
        completion.resume()
        for _ in 0..<100 where replies.isEmpty { await Task.yield() }
        #expect(replies == [true])
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }
}
