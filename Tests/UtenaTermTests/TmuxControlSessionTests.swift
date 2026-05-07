import XCTest
@testable import utena_term

/// Per-syscall coalescing for tmux %output. Tests the pure helpers used by
/// `TmuxControlSession.readLoop` so we don't have to spawn a real tmux process.
///
/// Invariants under test:
///  - Consecutive %output for the same pane → single delegate call with
///    concatenated bytes in arrival order.
///  - %output then %layout-change → two delegate calls in arrival order.
///  - Two interleaved panes → each pane's bytes arrive in arrival order, but
///    the per-pane streams are NOT cross-merged.
final class TmuxControlSessionTests: XCTestCase {
    typealias Call = TmuxControlSession.PendingDelegateCall

    private func drain(_ events: [Call]) -> [Call] {
        var pending: [Call] = []
        var pendingOutput: (paneID: String, data: Data)? = nil
        for ev in events {
            TmuxControlSession.appendCall(ev, pending: &pending, pendingOutput: &pendingOutput)
        }
        TmuxControlSession.flushPendingOutput(pending: &pending, pendingOutput: &pendingOutput)
        return pending
    }

    func testConsecutiveOutputForSamePaneIsConcatenated() {
        let result = drain([
            .output(paneID: "%1", data: Data([0x68, 0x65])),       // "he"
            .output(paneID: "%1", data: Data([0x6C, 0x6C, 0x6F])), // "llo"
        ])
        XCTAssertEqual(result, [
            .output(paneID: "%1", data: Data([0x68, 0x65, 0x6C, 0x6C, 0x6F])), // "hello"
        ])
    }

    func testOutputThenLayoutChangePreservesOrder() {
        let result = drain([
            .output(paneID: "%1", data: Data([0x61])),            // "a"
            .layoutChange(windowID: "@0", layout: "abcd,80x24,0,0,0"),
            .output(paneID: "%1", data: Data([0x62])),            // "b"
        ])
        XCTAssertEqual(result, [
            .output(paneID: "%1", data: Data([0x61])),
            .layoutChange(windowID: "@0", layout: "abcd,80x24,0,0,0"),
            .output(paneID: "%1", data: Data([0x62])),
        ])
    }

    func testTwoPanesInterleavedAreNotCrossMerged() {
        let result = drain([
            .output(paneID: "%1", data: Data([0x41])),  // "A"
            .output(paneID: "%2", data: Data([0x58])),  // "X"
            .output(paneID: "%1", data: Data([0x42])),  // "B"
            .output(paneID: "%2", data: Data([0x59])),  // "Y"
        ])
        XCTAssertEqual(result, [
            .output(paneID: "%1", data: Data([0x41])),
            .output(paneID: "%2", data: Data([0x58])),
            .output(paneID: "%1", data: Data([0x42])),
            .output(paneID: "%2", data: Data([0x59])),
        ])
    }

    func testRunOfSamePaneAfterDifferentPaneIsMergedWithinThatRun() {
        let result = drain([
            .output(paneID: "%1", data: Data([0x41])),
            .output(paneID: "%1", data: Data([0x42])),  // merged with prev
            .output(paneID: "%2", data: Data([0x58])),  // different pane → separate
            .output(paneID: "%2", data: Data([0x59])),  // merged with prev %2
        ])
        XCTAssertEqual(result, [
            .output(paneID: "%1", data: Data([0x41, 0x42])),
            .output(paneID: "%2", data: Data([0x58, 0x59])),
        ])
    }

    func testNonOutputEventBetweenSamePaneFlushesAccumulator() {
        // A layout-change between two %output for the same pane MUST split
        // the output — the layout event might describe a state change the
        // first byte assumed and the second byte depends on.
        let result = drain([
            .output(paneID: "%1", data: Data([0x41])),
            .windowAdd(windowID: "@1"),
            .output(paneID: "%1", data: Data([0x42])),
        ])
        XCTAssertEqual(result, [
            .output(paneID: "%1", data: Data([0x41])),
            .windowAdd(windowID: "@1"),
            .output(paneID: "%1", data: Data([0x42])),
        ])
    }

    func testEmptyDrainProducesNoCalls() {
        XCTAssertEqual(drain([]), [])
    }

    func testSinglePaneSingleByteRoundtripsUnchanged() {
        // The common typing-echo case: one %output line with one byte.
        let result = drain([
            .output(paneID: "%1", data: Data([0x78])),  // "x"
        ])
        XCTAssertEqual(result, [.output(paneID: "%1", data: Data([0x78]))])
    }
}
