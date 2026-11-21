#if os(macOS)
import AppKit
@testable import Stillday
import Testing

struct DesktopTrackpadTests {
    @MainActor @Test func aNewFlickResumesAtTheDisplayedOffsetDuringSnap() {
        let position = WeekHorizontalPosition()
        position.offset = -80
        position.beginSnap(to: -100, dayShift: 1, at: 0)
        #expect(position.advanceSnap(at: 0.05) == nil)
        let displayedOffset = position.offset
        #expect(displayedOffset < -80 && displayedOffset > -100)

        position.interruptSnap()
        #expect(!position.isSettling)
        position.offset += 15
        #expect(position.advanceSnap(at: 0.2) == nil)
        #expect(position.offset == displayedOffset + 15)

        position.beginSnap(to: -100, dayShift: 1, at: 0.2)
        #expect(position.advanceSnap(at: 0.4) == 1)
        #expect(position.offset == -100)
        #expect(position.advanceSnap(at: 0.5) == nil)
    }

    @Test func weekScrollContinuesThroughMomentumBeforeFinishing() {
        var input = DesktopTrackpadScroll()
        #expect(input.receive(phase: .began, momentum: [], x: -70, y: 1, time: 0,
                              startsHere: true, followsMomentum: true) == .move(-70))
        #expect(input.receive(phase: .ended, momentum: [], x: 0, y: 0, time: 0.05,
                              startsHere: false, followsMomentum: true) == .waitForMomentum)
        #expect(input.receive(phase: [], momentum: .began, x: -40, y: 0, time: 0.06,
                              startsHere: false, followsMomentum: true) == .move(-40))
        #expect(input.receive(phase: [], momentum: .changed, x: -24, y: 0, time: 0.08,
                              startsHere: false, followsMomentum: true) == .move(-24))
        #expect(input.receive(phase: [], momentum: .ended, x: 0, y: 0, time: 0.1,
                              startsHere: false, followsMomentum: true) == .finish(0))
    }

    @Test func verticalScrollDoesNotSwitchToDayPagingWhenTheFingersDrift() {
        var input = DesktopTrackpadScroll()
        #expect(input.receive(phase: .began, momentum: [], x: 2, y: 12, time: 0, startsHere: true) == .pass)
        #expect(input.receive(phase: .changed, momentum: [], x: -48, y: 4, time: 0.02, startsHere: false) == .pass)
        #expect(input.receive(phase: .ended, momentum: [], x: 0, y: 0, time: 0.03, startsHere: false) == .pass)
        #expect(input.receive(phase: [], momentum: .began, x: 0, y: 8, time: 0.04, startsHere: false) == .pass)
    }

    @Test func horizontalFlickFollowsTheFingersAndSettlesOnce() {
        var input = DesktopTrackpadScroll()
        #expect(input.receive(phase: .began, momentum: [], x: -4, y: 1, time: 0, startsHere: true) == .pass)
        #expect(input.receive(phase: .changed, momentum: [], x: -12, y: 0, time: 0.01, startsHere: false) == .move(-16))
        #expect(input.receive(phase: .changed, momentum: [], x: -25, y: 5, time: 0.03, startsHere: false) == .move(-25))
        let result = input.receive(phase: .ended, momentum: [], x: 0, y: 0, time: 0.04, startsHere: false)
        if case .finish(let extra) = result {
            #expect((extra ?? 0) < 0)
        } else {
            Issue.record("A horizontal flick should settle with its release velocity.")
        }
        #expect(input.receive(phase: [], momentum: .began, x: -40, y: 0, time: 0.05, startsHere: false) == .consume)
        #expect(input.receive(phase: [], momentum: .ended, x: 0, y: 0, time: 0.1, startsHere: false) == .consume)
    }
}
#endif
