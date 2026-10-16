import XCTest
@testable import QuickVoiceCore

/// A system with a virtual clock and a scripted tap-to-toggle engine behind the shortcut.
private final class FakeSystem: TapToggleEnvironment {
    var clock: TimeInterval = 1_000
    var now: TimeInterval { clock }

    /// Time of each tap's release.
    private(set) var tapTimes: [TimeInterval] = []
    private(set) var tapHotkeys: [Hotkey] = []
    private(set) var persisted: [Bool] = []
    private(set) var logs: [String] = []
    private(set) var forcedReleases = 0

    /// Microphone state changes, applied once the clock passes them.
    private var transitions: [(at: TimeInterval, on: Bool)] = []
    private var micBase = false

    /// What the engine does with the n-th tap (1-based); the default is a well-behaved toggle.
    var onTap: ((FakeSystem, Int) -> Void)?
    var startDelay: TimeInterval = 0.06
    var stopDelay: TimeInterval = 0.01
    /// The engine's own idea of whether it is recording; every tap toggles it.
    var engineRecording = false

    var keysHeldUntil: TimeInterval = 0
    var keysAlwaysHeld = false
    var leaveModifierDownAfterTap = false
    private var modifierDown = false

    var micOn: Bool {
        get { micActive() }
        set { micBase = newValue; transitions.removeAll() }
    }

    func micOnAt(_ time: TimeInterval) { transitions.append((time, true)) }
    func micOffAt(_ time: TimeInterval) { transitions.append((time, false)) }

    func sleep(_ seconds: TimeInterval) { clock += seconds }

    func captureMicBaseline() -> Bool { micActive() }

    func micActive() -> Bool {
        var on = micBase
        for transition in transitions.sorted(by: { $0.at < $1.at }) where transition.at <= clock {
            on = transition.on
        }
        return on
    }

    func realInputIdle() -> Bool { !keysAlwaysHeld && clock >= keysHeldUntil }

    func tap(_ hotkey: Hotkey, holdFor seconds: TimeInterval) {
        clock += seconds
        tapTimes.append(clock)
        tapHotkeys.append(hotkey)
        modifierDown = leaveModifierDownAfterTap
        let index = tapTimes.count
        if let onTap {
            onTap(self, index)
        } else {
            engineRecording.toggle()
            if engineRecording {
                micOnAt(clock + startDelay)
            } else {
                micOffAt(clock + stopDelay)
            }
        }
    }

    func modifiersClean(after hotkey: Hotkey) -> Bool { !modifierDown }

    func forceRelease(_ hotkey: Hotkey) {
        forcedReleases += 1
        modifierDown = false
    }

    func persist(active: Bool) { persisted.append(active) }

    func log(_ message: String) { logs.append(message) }

    var gaps: [TimeInterval] { zip(tapTimes, tapTimes.dropFirst()).map { $1 - $0 } }
}

final class TapToggleTests: XCTestCase {
    private let leftCommand = Hotkey(modifiers: [.leftCommand])

    private func session(_ system: FakeSystem, timing: TapToggleTiming = .standard) -> TapToggleSession {
        TapToggleSession(environment: system, timing: timing)
    }

    // MARK: The normal flow

    func testTapToStartThenTapToStop() throws {
        let system = FakeSystem()
        let session = session(system)

        guard case let .started(latency) = session.start(leftCommand) else { return XCTFail("expected a start") }
        XCTAssertEqual(latency, 0.16, accuracy: 0.1)
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(system.tapTimes.count, 1)

        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(system.tapTimes.count, 2)
        XCTAssertEqual(system.tapHotkeys, [leftCommand, leftCommand])
        XCTAssertFalse(system.micOn)
        XCTAssertEqual(system.persisted, [true, false])
        XCTAssertEqual(system.forcedReleases, 0)
    }

    func testTheTwoTapsAreNeverCloserThanTheMinimumInterval() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        // The mouse is released straight away.
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
        XCTAssertGreaterThanOrEqual(system.gaps[0], TapToggleTiming.standard.minInterval - 0.001)
    }

    func testAShortRecordingStillWaitsOutTheIntervalOnlyOnce() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.sleep(3)
        let before = system.clock
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
        XCTAssertLessThan(system.tapTimes[1] - before, 0.3, "no extra waiting after a long recording")
    }

    func testBackToBackRecordingsKeepTheIntervalBetweenTheStopAndTheNextStart() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.sleep(1)
        _ = session.stop(reason: "mouse up")
        guard case .started = session.start(leftCommand) else { return XCTFail("expected a start") }
        XCTAssertGreaterThanOrEqual(system.gaps[1], TapToggleTiming.standard.minInterval - 0.001)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
        for gap in system.gaps {
            XCTAssertGreaterThanOrEqual(gap, TapToggleTiming.standard.minInterval - 0.001)
        }
    }

    func testTapHoldComesFromTheTiming() {
        let system = FakeSystem()
        let session = session(system, timing: TapToggleTiming(tapHold: 0.15))
        let before = system.clock
        _ = session.start(leftCommand)
        XCTAssertEqual(system.tapTimes[0] - before, 0.15, accuracy: 0.001)
        XCTAssertEqual(TapToggleTiming.clampedTapHold(0), 0.03)
        XCTAssertEqual(TapToggleTiming.clampedTapHold(5), 0.4)
        XCTAssertEqual(TapToggleTiming.clampedTapHold(0.1), 0.1)
        XCTAssertEqual(TapToggleTiming(tapHold: 10).tapHold, 0.4)
    }

    // MARK: Starting safely

    func testNothingIsTappedWhenTheMicrophoneIsAlreadyRunning() {
        let system = FakeSystem()
        system.micOn = true
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand), .micBusy)
        XCTAssertEqual(system.tapTimes.count, 0)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.stop(reason: "mouse up"), .notRecording)
        XCTAssertEqual(system.tapTimes.count, 0, "someone else's recording must not be stopped")
    }

    func testNothingIsTappedWhileARealKeyIsHeldDown() {
        let system = FakeSystem()
        system.keysAlwaysHeld = true
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand), .realKeysHeld)
        XCTAssertEqual(system.tapTimes.count, 0)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(system.persisted, [])
    }

    func testAKeyReleasedWithinTheWaitDoesNotBlockTheStart() {
        let system = FakeSystem()
        system.keysHeldUntil = system.clock + 0.2
        let session = session(system)
        guard case .started = session.start(leftCommand) else { return XCTFail("expected a start") }
        XCTAssertGreaterThanOrEqual(system.tapTimes[0], system.keysHeldUntil)
    }

    func testReleasingTheMouseBeforeTheTapCancelsIt() {
        let system = FakeSystem()
        system.keysAlwaysHeld = true
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand, shouldAbort: { true }), .aborted)
        XCTAssertEqual(system.tapTimes.count, 0)

        let free = FakeSystem()
        XCTAssertEqual(self.session(free).start(leftCommand, shouldAbort: { true }), .aborted)
        XCTAssertEqual(free.tapTimes.count, 0)
    }

    func testAStartWhileOneIsRunningIsIgnored() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(session.start(leftCommand), .alreadyActive)
        XCTAssertEqual(system.tapTimes.count, 1)
        XCTAssertEqual(session.state, .recording)
    }

    func testAStaleRecordingStateIsForgottenWhenTheMicrophoneIsOff() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.micOffAt(system.clock) // stopped from Bageshuo's own window
        system.engineRecording = false
        guard case .started = session.start(leftCommand) else { return XCTFail("expected a new start") }
        XCTAssertEqual(system.tapTimes.count, 2)
    }

    // MARK: The microphone does not start

    func testNoSecondTapWhenTheFirstDidNotStartAnything() {
        let system = FakeSystem()
        system.onTap = { _, _ in } // the engine ignores the tap
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand), .notStarted)
        XCTAssertEqual(session.state, .startUnconfirmed)
        XCTAssertTrue(session.needsStop)
        XCTAssertEqual(session.stop(reason: "mouse up"), .notRecording)
        XCTAssertEqual(system.tapTimes.count, 1, "a stop tap would start a recording")
        XCTAssertEqual(session.settleUnconfirmedStart(), .notRecording)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(system.tapTimes.count, 1)
        XCTAssertEqual(system.persisted.last, false)
    }

    func testALateStartIsStoppedWhenTheMouseIsReleased() {
        let system = FakeSystem()
        system.startDelay = 3 // longer than the confirmation wait
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand), .notStarted)
        system.sleep(1.5) // the microphone comes on while the button is still held
        XCTAssertTrue(system.micOn)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
        XCTAssertEqual(system.tapTimes.count, 2)
        XCTAssertFalse(system.micOn)
        XCTAssertEqual(session.state, .idle)
    }

    func testALateStartIsNoticedWhileTheButtonIsStillHeld() {
        let system = FakeSystem()
        system.startDelay = 3
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand), .notStarted)
        XCTAssertFalse(session.pollLateStart())
        system.sleep(1.5)
        XCTAssertTrue(session.pollLateStart())
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
    }

    func testALateStartAfterTheMouseWasReleasedIsStoppedByTheJanitor() {
        let system = FakeSystem()
        system.startDelay = 3.5
        let session = session(system)
        XCTAssertEqual(session.start(leftCommand), .notStarted)
        XCTAssertEqual(session.stop(reason: "mouse up"), .notRecording)
        XCTAssertEqual(system.tapTimes.count, 1)
        system.sleep(TapToggleTiming.standard.lateStartWindow)
        XCTAssertTrue(system.micOn, "it started after all")
        XCTAssertEqual(session.settleUnconfirmedStart(), .stopped(retried: false))
        XCTAssertFalse(system.micOn)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(system.tapTimes.count, 2)
    }

    // MARK: Stopping safely

    func testNoStopTapWhenTheRecordingAlreadyEnded() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.micOffAt(system.clock + 0.5) // the user stopped it in Bageshuo
        system.sleep(1)
        XCTAssertEqual(session.stop(reason: "mouse up"), .endedByItself)
        XCTAssertEqual(system.tapTimes.count, 1, "a second tap would start a new recording")
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(system.persisted.last, false)
    }

    func testStopWithNothingRunningDoesNothing() {
        let system = FakeSystem()
        XCTAssertEqual(session(system).stop(reason: "quit"), .notRecording)
        XCTAssertEqual(system.tapTimes.count, 0)
        XCTAssertEqual(system.persisted, [])
    }

    func testOneCompensatingTapWhenTheStopTapWasDropped() {
        let system = FakeSystem()
        system.onTap = { system, index in
            switch index {
            case 1: system.micOnAt(system.clock + 0.06)
            case 2: break // dropped
            default: system.micOffAt(system.clock + 0.01)
            }
        }
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: true))
        XCTAssertEqual(system.tapTimes.count, 3)
        XCTAssertEqual(session.state, .idle)
        for gap in system.gaps {
            XCTAssertGreaterThanOrEqual(gap, TapToggleTiming.standard.minInterval - 0.001)
        }
    }

    func testNoMoreThanOneCompensatingTapThenItGivesUp() {
        let system = FakeSystem()
        system.onTap = { system, index in
            if index == 1 { system.micOnAt(system.clock + 0.06) }
        }
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stuck)
        XCTAssertEqual(system.tapTimes.count, 3, "start + stop + one compensation")
        XCTAssertEqual(session.state, .stuck)
        XCTAssertTrue(session.needsStop)
        XCTAssertTrue(system.logs.contains { $0.contains("giving up") })
        XCTAssertEqual(session.start(leftCommand), .alreadyActive)
        XCTAssertEqual(system.tapTimes.count, 3, "nothing is tapped while a recording is stuck")
    }

    func testAStuckRecordingIsRetriedWhenAskedAgain() {
        let system = FakeSystem()
        var stopsIgnored = true
        system.onTap = { system, index in
            if index == 1 {
                system.micOnAt(system.clock + 0.06)
            } else if !stopsIgnored {
                system.micOffAt(system.clock + 0.01)
            }
        }
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stuck)
        stopsIgnored = false
        XCTAssertEqual(session.stop(reason: "quit", urgent: true), .stopped(retried: false))
        XCTAssertEqual(session.state, .idle)
    }

    func testAStuckRecordingFreesItselfWhenTheUserStopsItByHand() {
        let system = FakeSystem()
        system.onTap = { system, index in
            if index == 1 { system.micOnAt(system.clock + 0.06) }
        }
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(session.stop(reason: "mouse up"), .stuck)
        system.micOffAt(system.clock)
        system.onTap = nil
        guard case .started = session.start(leftCommand) else { return XCTFail("expected a start") }
    }

    func testStopWaitsForARealKeyThatIsHeldThenTaps() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.sleep(2)
        system.keysHeldUntil = system.clock + 1.5
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false))
        XCTAssertGreaterThanOrEqual(system.tapTimes[1], system.keysHeldUntil)
    }

    func testStopTapsAnywayWhenARealKeyStaysHeld() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.sleep(1)
        system.keysAlwaysHeld = true
        let before = system.clock
        XCTAssertEqual(session.stop(reason: "mouse up"), .stopped(retried: false), "a recording must not run on")
        XCTAssertGreaterThanOrEqual(system.tapTimes[1] - before, TapToggleTiming.standard.idleWaitForStop - 0.1)
        XCTAssertTrue(system.logs.contains { $0.contains("tapping anyway") })
    }

    func testAQuittingAppDoesNotWaitLongForTheKeyboard() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        system.sleep(1)
        system.keysAlwaysHeld = true
        let before = system.clock
        XCTAssertEqual(session.stop(reason: "quit", urgent: true), .stopped(retried: false))
        XCTAssertLessThan(system.tapTimes[1] - before, 0.6)
    }

    // MARK: Modifiers

    func testAModifierLeftDownAfterTheTapIsReleased() {
        let system = FakeSystem()
        system.leaveModifierDownAfterTap = true
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(system.forcedReleases, 1)
        XCTAssertTrue(system.logs.contains { $0.contains("still down after the tap") })
        _ = session.stop(reason: "mouse up")
        XCTAssertEqual(system.forcedReleases, 2)
    }

    func testACleanTapIsNotReleasedAgain() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        _ = session.stop(reason: "mouse up")
        XCTAssertEqual(system.forcedReleases, 0)
    }

    // MARK: Recovering from a crash

    func testARecordingLeftBehindByAPreviousRunIsStopped() {
        let system = FakeSystem()
        system.micOn = true
        system.engineRecording = true
        let session = session(system)
        XCTAssertEqual(session.recoverLeftoverRecording(with: leftCommand), .stopped(retried: false))
        XCTAssertEqual(system.tapTimes.count, 1)
        XCTAssertFalse(system.micOn)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(system.persisted.last, false)
    }

    func testNothingIsTappedOnLaunchWhenTheMicrophoneIsOff() {
        let system = FakeSystem()
        let session = session(system)
        XCTAssertEqual(session.recoverLeftoverRecording(with: leftCommand), .notRecording)
        XCTAssertEqual(system.tapTimes.count, 0)
        XCTAssertEqual(system.persisted, [false])
    }

    func testRecoveryIsSkippedWhileARecordingIsRunning() {
        let system = FakeSystem()
        let session = session(system)
        _ = session.start(leftCommand)
        XCTAssertEqual(session.recoverLeftoverRecording(with: leftCommand), .notRecording)
        XCTAssertEqual(system.tapTimes.count, 1)
    }
}
