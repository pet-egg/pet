import XCTest
@testable import ConnorPet

final class ClaudeDesktopStatusTests: XCTestCase {
    private func input(
        running: Bool = true,
        frontmost: Bool = false,
        generating: Bool = false,
        donePending: Bool = false
    ) -> ClaudeDesktopInput {
        ClaudeDesktopInput(running: running, frontmost: frontmost, generating: generating, donePending: donePending)
    }

    // 1. Not running → 잠듬, regardless of any other flag.
    func testNotRunningIsAlwaysIdle() {
        XCTAssertEqual(claudeDesktopAnimation(input(running: false)), .idle)
        XCTAssertEqual(
            claudeDesktopAnimation(input(running: false, frontmost: true, generating: true, donePending: true)),
            .idle
        )
    }

    // 2. Generating → 달리기, and it outranks everything below.
    func testGeneratingIsRunningAndTopsDoneAndWaiting() {
        XCTAssertEqual(claudeDesktopAnimation(input(generating: true)), .running)
        // even with a pending done notification and backgrounded
        XCTAssertEqual(
            claudeDesktopAnimation(input(frontmost: false, generating: true, donePending: true)),
            .running
        )
    }

    // 3. Done pending (not generating) → 헤롱헤롱, outranking 얼음.
    func testDonePendingIsReviewOverWaiting() {
        XCTAssertEqual(claudeDesktopAnimation(input(frontmost: false, donePending: true)), .review)
        XCTAssertEqual(claudeDesktopAnimation(input(frontmost: true, donePending: true)), .review)
    }

    // 4. Running but backgrounded, nothing else → 얼음.
    func testBackgroundedIdleIsWaiting() {
        XCTAssertEqual(claudeDesktopAnimation(input(frontmost: false)), .waiting)
    }

    // 5. Frontmost and idle → 잠듬.
    func testFrontmostIdleIsIdle() {
        XCTAssertEqual(claudeDesktopAnimation(input(frontmost: true)), .idle)
    }

    // Full precedence sweep: generating > donePending > !frontmost > idle.
    func testPrecedenceOrdering() {
        // generating wins over done + waiting
        XCTAssertEqual(
            claudeDesktopAnimation(input(frontmost: false, generating: true, donePending: true)),
            .running
        )
        // done wins over waiting when not generating
        XCTAssertEqual(
            claudeDesktopAnimation(input(frontmost: false, generating: false, donePending: true)),
            .review
        )
        // waiting only when backgrounded, not generating, nothing pending
        XCTAssertEqual(
            claudeDesktopAnimation(input(frontmost: false, generating: false, donePending: false)),
            .waiting
        )
    }
}
