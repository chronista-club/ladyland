// mem_1CgGUt6c4wBCNzowECCFsR — 演奏中は更新のダイアログでフォーカスを奪わない。
import Sparkle
import Testing
@testable import Ladyland

@MainActor @Suite("App update reminders")
struct AppUpdatesTests {
    @Test("更新通知はアプリが引き受ける")
    func gentleReminders() throws {
        let driver: any SPUStandardUserDriverDelegate = AppDelegate()
        #expect(driver.supportsGentleScheduledUpdateReminders == true)
    }

    @Test("起動直後・アイドル復帰も含め、定期確認からダイアログを出さない", arguments: [false, true])
    func scheduledChecksStayQuiet(immediateFocus: Bool) throws {
        let driver: any SPUStandardUserDriverDelegate = AppDelegate()
        // Sparkle exposes this fixture initializer; no feed or updater is started.
        let item = try #require(SUAppcastItem(dictionary: [
            "enclosure": ["url": "https://example.invalid/Ladyland.dmg", "sparkle:version": "60"]
        ]))
        #expect(driver.standardUserDriverShouldHandleShowingScheduledUpdate?(
            item, andInImmediateFocus: immediateFocus) == false)
    }
}
