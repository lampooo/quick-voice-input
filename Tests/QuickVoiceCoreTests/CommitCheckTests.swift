import XCTest
@testable import QuickVoiceCore

final class CommitCheckTests: XCTestCase {
    private func samples(_ lengths: [Int?]) -> [CommitCheck.Sample] {
        zip(CommitCheck.sampleDelays, lengths).map { CommitCheck.Sample(after: $0, length: $1) }
    }

    func testCommittedAfterRelease() {
        let outcome = CommitCheck.evaluate(baseline: 10, samples: samples([10, 10, 18, 18, 18, 18]))
        XCTAssertEqual(outcome, .committed(added: 8, after: 1))
        XCTAssertEqual(outcome.summary, "已上屏 8 个字符（松开后 1 秒）")
        XCTAssertEqual(outcome.logDescription, "committed +8 chars, 1s after release")
    }

    func testTextAlreadyThereAtRelease() {
        XCTAssertEqual(CommitCheck.evaluate(baseline: 0, samples: samples([5, 5, 5, 5, 5, 5])), .committed(added: 5, after: 0))
    }

    /// Input methods may rewrite the text after committing it (Doubao's polishing).
    func testFinalCountWinsWhenTextIsRewritten() {
        XCTAssertEqual(CommitCheck.evaluate(baseline: 10, samples: samples([10, 10, 18, 17, 17, 17])), .committed(added: 7, after: 2))
    }

    func testUnchanged() {
        let outcome = CommitCheck.evaluate(baseline: 42, samples: samples([42, 42, 42, 42, 42, 42]))
        XCTAssertEqual(outcome, .unchanged(waited: 5))
        XCTAssertEqual(outcome.summary, "松开后 5 秒内输入框里没有新文字")
    }

    func testReplacedSelection() {
        XCTAssertEqual(CommitCheck.evaluate(baseline: 10, samples: samples([10, 6, 6, 6, 6, 6])), .changed(delta: -4, after: 0.3))
    }

    func testUnreadableField() {
        XCTAssertEqual(CommitCheck.evaluate(baseline: nil, samples: samples([1, 2, 3, 4, 5, 6])), .unavailable("开始时读不到输入框的字数"))
        XCTAssertEqual(CommitCheck.evaluate(baseline: 3, samples: samples([nil, nil, nil, nil, nil, nil])), .unavailable("松开后读不到输入框的字数"))
    }

    func testFieldGoneAfterCommit() {
        XCTAssertEqual(CommitCheck.evaluate(baseline: 10, samples: samples([10, 18, nil, nil, nil, nil])), .committed(added: 8, after: 0.3))
    }

    func testStoppedEarly() {
        XCTAssertEqual(CommitCheck.evaluate(baseline: 10, samples: samples([10, 10, 10])), .unchanged(waited: 1))
    }

    func testSecondsFormatting() {
        XCTAssertEqual(CommitCheck.Outcome.seconds(0), "0")
        XCTAssertEqual(CommitCheck.Outcome.seconds(0.3), "0.3")
        XCTAssertEqual(CommitCheck.Outcome.seconds(3.5), "3.5")
        XCTAssertEqual(CommitCheck.sampleDelays.last, 5)
    }
}
