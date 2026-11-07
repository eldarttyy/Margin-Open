import Foundation
import Testing
@testable import MarginCore

/// `#expect` can't call a mutating method, so this reports through a copy-out.
private func dropped(_ gate: inout InputGate, _ event: InputGate.Event, now: Double) -> Bool {
    gate.shouldDrop(event, now: now)
}

@Test func aCornerTouchSwallowsItsTapToClick() {
    var gate = InputGate()
    gate.openClickGuard(now: 1)
    gate.frame(now: 1.1)
    do { let d = dropped(&gate, .mouseDown, now: 1.15); #expect(d) }
    do { let d = dropped(&gate, .mouseUp, now: 1.16); #expect(d) }
}

@Test func clicksComeBackIfTheLiftWasNeverSeen() {
    var gate = InputGate()
    gate.openClickGuard(now: 1)
    // The Mac slept with a finger down, so no lift ever arrives.
    do { let d = dropped(&gate, .mouseDown, now: 1 + InputGate.staleAfter + 0.01); #expect(!d) }
    do { let d = dropped(&gate, .mouseUp, now: 2); #expect(!d) }
    do { let d = dropped(&gate, .mouseDown, now: 3); #expect(!d) }
}

@Test func theGuardOutlastsTheLiftBriefly() {
    var gate = InputGate()
    gate.openClickGuard(now: 1)
    gate.closeClickGuard(until: 1.2)
    do { let d = dropped(&gate, .mouseDown, now: 1.1); #expect(d) }
    do { let d = dropped(&gate, .mouseUp, now: 1.11); #expect(d) }
    do { let d = dropped(&gate, .mouseDown, now: 1.3); #expect(!d) }
}

@Test func aClickThatGotThroughKeepsItsRelease() {
    var gate = InputGate()
    do { let d = dropped(&gate, .mouseDown, now: 1); #expect(!d) }
    gate.openClickGuard(now: 1.1)
    do { let d = dropped(&gate, .mouseUp, now: 1.11); #expect(!d) }
}

@Test func theCursorIsLetGoIfFramesStop() {
    var gate = InputGate()
    gate.hold(now: 1)
    do { let d = dropped(&gate, .mouseMoved, now: 1.1); #expect(d) }
    do { let d = dropped(&gate, .mouseMoved, now: 1 + InputGate.staleAfter + 0.01); #expect(!d) }
    #expect(!gate.isHolding)
}

@Test func ordinaryKeysAreTimedAndPassed() {
    var gate = InputGate()
    do { let d = dropped(&gate, .keyDown(isCaps: false), now: 5); #expect(!d) }
    #expect(gate.lastKey == 5)
    do { let d = dropped(&gate, .keyUp(isCaps: false), now: 6); #expect(!d) }
}

@Test func theCapsKeyIsHeldAndHidden() {
    var gate = InputGate()
    do { let d = dropped(&gate, .keyDown(isCaps: true), now: 1); #expect(d) }
    #expect(gate.capsHeld)
    #expect(gate.lastKey == 0)
    do { let d = dropped(&gate, .keyUp(isCaps: true), now: 2); #expect(d) }
    #expect(!gate.capsHeld)
}

@Test func filesAndOptionsAreRefusedAsActionTargets() {
    #expect(Action(.openURL, "file:///Applications/Calculator.app").openableURL == nil)
    #expect(Action(.openURL, "FILE:///tmp/x").openableURL == nil)
    #expect(Action(.openURL, "not a url").openableURL == nil)
    #expect(Action(.openURL, "https://example.com").openableURL != nil)
    #expect(Action(.openURL, "raycast://extensions").openableURL != nil)
    #expect(Action(.openApp, "--fresh").isSafeArgument == false)
    #expect(Action(.openApp, "").isSafeArgument == false)
    #expect(Action(.openApp, "Safari").isSafeArgument)
}

@Test func aHandEditedSensitivityCantOverflowASlider() throws {
    let huge = try JSONDecoder().decode(ZoneBinding.self, from: Data(#"{"sensitivity":1e308}"#.utf8))
    #expect(huge.sensitivity == 100)
    let negative = try JSONDecoder().decode(ZoneBinding.self, from: Data(#"{"sensitivity":-5}"#.utf8))
    #expect(negative.sensitivity == 0)
    let normal = try JSONDecoder().decode(ZoneBinding.self, from: Data(#"{"sensitivity":1.4}"#.utf8))
    #expect(normal.sensitivity == 1.4)
}
