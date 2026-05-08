import Foundation
import os.signpost

// Lightweight Points of Interest signposts for the keystroke → render pipeline.
//
// These compile to nearly nothing when Instruments isn't recording. Use the
// "Points of Interest" instrument and filter by subsystem `com.utena-term` to
// see the cascade of events for one keystroke:
//
//   keyDown                 — AppKit handed us a key event (main thread)
//   tmuxWrite               — tmux send-keys command finished writing to PTY
//   tmuxOutput pane=%N      — tmux %output line parsed off the wire
//   paneReceive pane=%N     — pane delivered bytes to the VT bridge (main)
//   draw                    — Metal command buffer committed (main)
//
// The user-visible echo latency is keyDown → draw for the same keystroke.
// Correlate by timestamp; we don't try to plumb a single signpost ID across
// the wire because tmux's output is unconnected to any in-process keystroke.
enum Signpost {
    static let log = OSLog(subsystem: "com.utena-term", category: .pointsOfInterest)

    @inline(__always)
    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    @inline(__always)
    static func event(_ name: StaticString, _ message: @autoclosure () -> String) {
        guard log.signpostsEnabled else { return }
        os_signpost(.event, log: log, name: name, "%{public}s", message())
    }
}
