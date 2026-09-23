import CoreGraphics
import XCTest
@testable import QuickVoiceCore

final class LongPressMachineTests: XCTestCase {
    private let origin = CGPoint(x: 100, y: 200)

    private func pressedMachine(holdDuration: TimeInterval = 0.5) -> LongPressMachine {
        var machine = LongPressMachine(config: LongPressConfig(holdDuration: holdDuration))
        _ = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: 0, enabled: true)
        return machine
    }

    func testMouseDownStartsTimingAndProbe() {
        var machine = LongPressMachine()
        let output = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: EventFlagBits.nonCoalesced, enabled: true)
        XCTAssertEqual(output.disposition, .pass)
        XCTAssertEqual(output.effects, [.startProbe(pressID: 1, at: origin, delay: 0.15), .scheduleCheck(pressID: 1, at: 10.5)])
        XCTAssertEqual(machine.state, .pressing(origin: origin, startedAt: 10))
    }

    func testProbeDelayIsCappedByShortHoldDuration() {
        var machine = LongPressMachine(config: LongPressConfig(holdDuration: 0.2))
        let output = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: 0, enabled: true)
        XCTAssertEqual(output.effects.first, .startProbe(pressID: 1, at: origin, delay: 0.1))
    }

    func testDisabledPassesThrough() {
        var machine = LongPressMachine()
        let output = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: 0, enabled: false)
        XCTAssertEqual(output, MachineOutput())
        XCTAssertEqual(machine.state, .idle)
    }

    func testDoubleClickIsIgnored() {
        var machine = LongPressMachine()
        let output = machine.mouseDown(at: origin, time: 10, clickCount: 2, modifierFlags: 0, enabled: true)
        XCTAssertEqual(output.effects, [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testModifierClickIsIgnored() {
        for flag in [EventFlagBits.command, EventFlagBits.option, EventFlagBits.control, EventFlagBits.shift] {
            var machine = LongPressMachine()
            _ = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: flag, enabled: true)
            XCTAssertEqual(machine.state, .idle, "flag \(flag)")
        }
    }

    func testCapsLockDoesNotBlockTrigger() {
        var machine = LongPressMachine()
        _ = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: EventFlagBits.alphaShift, enabled: true)
        XCTAssertEqual(machine.state, .pressing(origin: origin, startedAt: 10))
    }

    func testQuickReleaseIsANormalClick() {
        var machine = pressedMachine()
        let up = machine.mouseUp(at: origin, time: 10.2)
        XCTAssertEqual(up, MachineOutput(disposition: .pass, effects: [.cancelCheck]))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger), MachineOutput())
    }

    func testSmallMovementIsTolerated() {
        var machine = pressedMachine()
        let drag = machine.mouseDragged(to: CGPoint(x: 103, y: 204), time: 10.1)
        XCTAssertEqual(drag, MachineOutput())
        XCTAssertEqual(machine.state, .pressing(origin: origin, startedAt: 10))
    }

    func testDraggingCancels() {
        var machine = pressedMachine()
        let drag = machine.mouseDragged(to: CGPoint(x: 106, y: 200), time: 10.1)
        XCTAssertEqual(drag, MachineOutput(disposition: .pass, effects: [.cancelCheck]))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.mouseDragged(to: CGPoint(x: 150, y: 200), time: 10.2), MachineOutput())
        XCTAssertEqual(machine.mouseUp(at: CGPoint(x: 150, y: 200), time: 10.3), MachineOutput())
    }

    func testEarlyCheckReschedules() {
        var machine = pressedMachine()
        let output = machine.checkDue(pressID: 1, time: 10.3, verdict: .trigger)
        XCTAssertEqual(output.effects, [.scheduleCheck(pressID: 1, at: 10.5)])
        XCTAssertEqual(machine.state, .pressing(origin: origin, startedAt: 10))
    }

    func testTriggerStartsRecordingAtLatestPoint() {
        var machine = pressedMachine()
        let moved = CGPoint(x: 102, y: 201)
        _ = machine.mouseDragged(to: moved, time: 10.2)
        let output = machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger)
        XCTAssertEqual(output.effects, [.beginRecording(at: moved)])
        XCTAssertEqual(machine.state, .recording)
    }

    func testNotATextFieldLeavesPressAlone() {
        var machine = pressedMachine()
        let output = machine.checkDue(pressID: 1, time: 10.5, verdict: .skip)
        XCTAssertEqual(output, MachineOutput())
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.mouseUp(at: origin, time: 11), MachineOutput())
    }

    func testPendingProbeRechecksUntilDeadline() {
        var machine = LongPressMachine(config: LongPressConfig(holdDuration: 0.5, maxProbeWait: 0.2, probeRecheckInterval: 0.05))
        _ = machine.mouseDown(at: origin, time: 10, clickCount: 1, modifierFlags: 0, enabled: true)
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 10.5, verdict: .pending).effects, [.scheduleCheck(pressID: 1, at: 10.55)])
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 10.68, verdict: .pending).effects, [.scheduleCheck(pressID: 1, at: 10.7)])
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 10.7, verdict: .pending), MachineOutput())
        XCTAssertEqual(machine.state, .idle)
    }

    func testPendingThenTrigger() {
        var machine = pressedMachine()
        _ = machine.checkDue(pressID: 1, time: 10.5, verdict: .pending)
        let output = machine.checkDue(pressID: 1, time: 10.55, verdict: .trigger)
        XCTAssertEqual(output.effects, [.beginRecording(at: origin)])
    }

    func testRecordingConvertsDragsAndSwallowsRelease() {
        var machine = pressedMachine()
        _ = machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger)
        XCTAssertEqual(machine.mouseDragged(to: CGPoint(x: 300, y: 300), time: 11), MachineOutput(disposition: .convertToMove))
        XCTAssertEqual(machine.state, .recording)
        XCTAssertEqual(machine.mouseUp(at: CGPoint(x: 300, y: 300), time: 12), MachineOutput(disposition: .swallow, effects: [.endRecording]))
        XCTAssertEqual(machine.state, .idle)
    }

    func testStaleCheckFromPreviousPressIsIgnored() {
        var machine = pressedMachine()
        _ = machine.mouseUp(at: origin, time: 10.1)
        _ = machine.mouseDown(at: origin, time: 10.2, clickCount: 1, modifierFlags: 0, enabled: true)
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger), MachineOutput())
        XCTAssertEqual(machine.checkDue(pressID: 2, time: 10.7, verdict: .trigger).effects, [.beginRecording(at: origin)])
    }

    func testMouseDownWhileRecordingEndsStaleRecording() {
        var machine = pressedMachine()
        _ = machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger)
        let output = machine.mouseDown(at: origin, time: 20, clickCount: 1, modifierFlags: 0, enabled: true)
        XCTAssertEqual(output.effects.first, .endRecording)
        XCTAssertEqual(machine.state, .pressing(origin: origin, startedAt: 20))
    }

    func testResetReleasesHotkeyWhileRecording() {
        var machine = pressedMachine()
        _ = machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger)
        XCTAssertEqual(machine.reset().effects, [.endRecording])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.reset(), MachineOutput())
    }

    func testResetWhilePressingCancelsCheck() {
        var machine = pressedMachine()
        XCTAssertEqual(machine.reset().effects, [.cancelCheck])
    }

    func testCustomHoldDuration() {
        var machine = pressedMachine(holdDuration: 1.2)
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 10.5, verdict: .trigger).effects, [.scheduleCheck(pressID: 1, at: 11.2)])
        XCTAssertEqual(machine.checkDue(pressID: 1, time: 11.2, verdict: .trigger).effects, [.beginRecording(at: origin)])
    }
}
