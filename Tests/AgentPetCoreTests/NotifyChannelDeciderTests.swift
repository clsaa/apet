import XCTest
@testable import AgentPetCore

/// 纯函数 `NotifyChannelDecider.decide`：在「基础决定要通知」之上叠加横幅/声音开关（F1）。
final class NotifyChannelDeciderTests: XCTestCase {

    func test_bannerOn_soundOn_postsWithSound() {
        let d = NotifyChannelDecider.decide(baseShouldNotify: true, bannerEnabled: true, soundEnabled: true)
        XCTAssertTrue(d.post); XCTAssertTrue(d.withSound)
    }

    func test_bannerOn_soundOff_postsSilently() {
        let d = NotifyChannelDecider.decide(baseShouldNotify: true, bannerEnabled: true, soundEnabled: false)
        XCTAssertTrue(d.post); XCTAssertFalse(d.withSound)
    }

    func test_bannerOff_neverPosts_noSound() {
        let d = NotifyChannelDecider.decide(baseShouldNotify: true, bannerEnabled: false, soundEnabled: true)
        XCTAssertFalse(d.post); XCTAssertFalse(d.withSound)
    }

    func test_baseFalse_neverPosts() {
        let d = NotifyChannelDecider.decide(baseShouldNotify: false, bannerEnabled: true, soundEnabled: true)
        XCTAssertFalse(d.post); XCTAssertFalse(d.withSound)
    }
}
