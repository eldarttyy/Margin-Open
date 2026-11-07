import Foundation
import Testing
@testable import MarginCore

private func engine(_ bindings: [ZoneID: ZoneBinding]? = nil) -> GestureEngine {
    GestureEngine(tuning: Tuning(), bindings: bindings ?? MarginConfig.standard.bindings(for: AppContext()))
}

/// Feeds one finger along a path, one frame per 10ms, then lifts it.
private func run(_ e: inout GestureEngine, _ path: [(Double, Double)], lift: Bool = true, major: Double = 8) -> [GestureEvent] {
    var out: [GestureEvent] = []
    var t = 0.0
    for p in path {
        out += e.process(touches: [TouchSample(id: 1, x: p.0, y: p.1, majorAxis: major)], time: t)
        t += 0.01
    }
    if lift { out += e.process(touches: [], time: t) }
    return out
}

private func rest(_ x: Double, _ y: Double, ms: Int = 100) -> [(Double, Double)] {
    Array(repeating: (x, y), count: ms / 10 + 1)
}

@Suite struct ZoneTests {
    let t = Tuning()

    @Test func edgesAndMiddle() {
        #expect(Zones.locate(x: 0.02, y: 0.5, tuning: t) { _ in true } == .leftEdge)
        #expect(Zones.locate(x: 0.98, y: 0.5, tuning: t) { _ in true } == .rightEdge)
        #expect(Zones.locate(x: 0.5, y: 0.98, tuning: t) { _ in true } == .topEdge)
        #expect(Zones.locate(x: 0.5, y: 0.02, tuning: t) { _ in true } == .bottomEdge)
        #expect(Zones.locate(x: 0.5, y: 0.5, tuning: t) { _ in true } == nil)
    }

    @Test func cornersWinWhenBound() {
        #expect(Zones.locate(x: 0.03, y: 0.97, tuning: t) { _ in true } == .topLeft)
        #expect(Zones.locate(x: 0.97, y: 0.03, tuning: t) { _ in true } == .bottomRight)
    }

    @Test func unboundCornerFallsThroughToEdge() {
        #expect(Zones.locate(x: 0.03, y: 0.97, tuning: t) { $0 == .leftEdge } == .leftEdge)
    }

    @Test func unboundZoneIsIgnored() {
        #expect(Zones.locate(x: 0.5, y: 0.02, tuning: t) { $0 != .bottomEdge } == nil)
    }
}

@Suite struct EdgeGestureTests {
    @Test func restThenSlideProducesTravel() {
        var e = engine()
        let path = rest(0.97, 0.3) + stride(from: 0.31, through: 0.60, by: 0.01).map { (0.97, $0) }
        let events = run(&e, path)
        #expect(events.first == .began(.rightEdge))
        #expect(events.contains(.captured(.rightEdge)))
        #expect(events.last == .ended(.rightEdge))
        let travel = events.reduce(0.0) { sum, event in
            if case .slide(_, let d) = event { return sum + d }
            return sum
        }
        #expect(travel > 0.25 && travel < 0.30)
    }

    @Test func slideDownIsNegative() {
        var e = engine()
        let path = rest(0.97, 0.7) + stride(from: 0.69, through: 0.5, by: -0.01).map { (0.97, $0) }
        let slides = run(&e, path).compactMap { event -> Double? in
            if case .slide(_, let d) = event { return d }
            return nil
        }
        #expect(!slides.isEmpty && slides.allSatisfy { $0 < 0 })
    }

    @Test func movingBeforeDwellIsANormalCursorMove() {
        var e = engine()
        let path = stride(from: 0.97, through: 0.5, by: -0.03).map { ($0, 0.5) }
        let events = run(&e, path)
        #expect(events == [.began(.rightEdge), .cancelled(.rightEdge)])
    }

    @Test func aShortFlickFiresAStepperOnce() {
        var binding = ZoneBinding.stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.15)
        binding.mode = .stepper
        var e = GestureEngine(tuning: Tuning(), bindings: [.rightEdge: binding])
        var time = 0.0
        var steps = 0
        for y in [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5] + stride(from: 0.5, through: 0.56, by: 0.01) {
            for event in e.process(touches: [TouchSample(id: 1, x: 0.97, y: y)], time: time) {
                if case .step = event { steps += 1 }
            }
            time += 0.016
        }
        #expect(steps == 1)
    }

    @Test func slidingStraightAwayStillEngages() {
        // Most real slides begin moving the moment the finger lands.
        var e = engine()
        let path = stride(from: 0.30, through: 0.70, by: 0.005).map { (0.97, $0) }
        let events = run(&e, path)
        #expect(events.contains(.captured(.rightEdge)))
        #expect(events.contains { if case .slide = $0 { return true } else { return false } })
    }

    @Test func landingJitterDoesNotCancel() {
        var e = engine()
        let path = [(0.97, 0.50), (0.975, 0.515), (0.968, 0.52)] + rest(0.97, 0.52) + [(0.97, 0.56), (0.97, 0.60)]
        let events = run(&e, path)
        #expect(!events.contains(.cancelled(.rightEdge)))
    }

    @Test func restThenHeadingIntoThePadReleasesTheTouch() {
        var e = engine()
        let path = rest(0.97, 0.5) + stride(from: 0.95, through: 0.5, by: -0.02).map { ($0, 0.5) }
        let events = run(&e, path)
        #expect(events.last == .cancelled(.rightEdge))
        #expect(!events.contains { if case .slide = $0 { return true } else { return false } })
    }

    @Test func secondFingerHandsTheTouchBackUntilAllLift() {
        var e = engine()
        _ = run(&e, rest(0.97, 0.5), lift: false)
        let two = [TouchSample(id: 1, x: 0.97, y: 0.6), TouchSample(id: 2, x: 0.5, y: 0.5)]
        #expect(e.process(touches: two, time: 1) == [.cancelled(.rightEdge)])
        // One finger remaining must not restart a gesture.
        #expect(e.process(touches: [two[0]], time: 1.1) == [])
        #expect(e.process(touches: [], time: 1.2) == [])
        #expect(e.process(touches: [TouchSample(id: 3, x: 0.97, y: 0.5)], time: 1.3) == [.began(.rightEdge)])
    }

    @Test func twoFingersAtOnceNeverStart() {
        var e = engine()
        let two = [TouchSample(id: 1, x: 0.97, y: 0.5), TouchSample(id: 2, x: 0.5, y: 0.5)]
        #expect(e.process(touches: two, time: 0) == [])
    }

    @Test func palmIsInvisible() {
        var e = engine()
        #expect(run(&e, rest(0.97, 0.5), major: 30).isEmpty)
    }

    @Test func palmDoesNotCancelAFinger() {
        var e = engine()
        _ = run(&e, rest(0.97, 0.5), lift: false)
        let frame = [TouchSample(id: 1, x: 0.97, y: 0.5), TouchSample(id: 9, x: 0.1, y: 0.1, majorAxis: 40)]
        let events = e.process(touches: frame, time: 1)
        #expect(!events.contains(.cancelled(.rightEdge)))
        #expect(e.isTrackingEdge)
    }

    @Test func stepperFiresPerDetentBothWays() {
        var e = engine([.rightEdge: .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.1)])
        let up = stride(from: 0.31, through: 0.55, by: 0.01).map { (0.97, $0) }
        let down = stride(from: 0.54, through: 0.30, by: -0.01).map { (0.97, $0) }
        let events = run(&e, rest(0.97, 0.3) + up + down)
        let steps = events.compactMap { event -> Bool? in
            if case .step(_, let forward) = event { return forward }
            return nil
        }
        // The first step fires early, on a short flick, and the rest per detent.
        #expect(steps.filter { $0 }.count == 2)
        #expect(steps.filter { !$0 }.count >= 1)
    }

    @Test func restingOnAnEdgeAsksOnceWhatItDoes() {
        var e = engine()
        let events = run(&e, rest(0.97, 0.5, ms: 900))
        #expect(events.filter { $0 == .rested(.rightEdge) }.count == 1)
    }

    @Test func slidingNeverAsks() {
        var e = engine()
        let path = rest(0.97, 0.2) + stride(from: 0.21, through: 0.8, by: 0.005).map { (0.97, $0) }
        #expect(!run(&e, path).contains(.rested(.rightEdge)))
    }

    @Test func semanticSteppersStepAndContinuousOnesSlide() {
        var e = engine([.rightEdge: .semantic(.undoScrub, step: 0.1), .leftEdge: .semantic(.scroll)])
        let up = stride(from: 0.31, through: 0.55, by: 0.01)
        let steps = run(&e, rest(0.97, 0.3) + up.map { (0.97, $0) })
        #expect(steps.filter { if case .step = $0 { return true } else { return false } }.count == 2)
        let slides = run(&e, rest(0.03, 0.3) + up.map { (0.03, $0) })
        #expect(slides.contains { if case .slide = $0 { return true } else { return false } })
    }

    @Test func cancelReturnsTouchToMacOS() {
        var e = engine()
        _ = run(&e, rest(0.97, 0.5), lift: false)
        #expect(e.cancel() == [.cancelled(.rightEdge)])
        #expect(!e.isTrackingEdge)
        #expect(e.cancel() == [])
    }
}

@Suite struct CornerGestureTests {
    let bindings: [ZoneID: ZoneBinding] = [.topRight: .buttons(tap: Action(.playPause), hold: Action(.toggleMute))]

    @Test func doubleTapDefersTheFirstTapAndFiresOnce() {
        var binding = ZoneBinding.buttons(tap: Action(.playPause))
        binding.doubleTap = Action(.toggleMute)
        var e = engine([.topRight: binding])
        let p = TouchSample(id: 1, x: 0.95, y: 0.95)
        #expect(e.process(touches: [p], time: 0) == [.began(.topRight)])
        #expect(e.process(touches: [], time: 0.08) == [.deferredTap(.topRight), .ended(.topRight)])
        #expect(e.process(touches: [p], time: 0.2) == [.began(.topRight)])
        #expect(e.process(touches: [], time: 0.27) == [.doubleTap(.topRight), .ended(.topRight)])
    }

    @Test func slowSecondTapIsAnotherSingleTap() {
        var binding = ZoneBinding.buttons(tap: Action(.playPause))
        binding.doubleTap = Action(.toggleMute)
        var e = engine([.topRight: binding])
        let p = TouchSample(id: 1, x: 0.95, y: 0.95)
        _ = e.process(touches: [p], time: 0)
        _ = e.process(touches: [], time: 0.08)
        _ = e.process(touches: [p], time: 0.6)
        #expect(e.process(touches: [], time: 0.68) == [.deferredTap(.topRight), .ended(.topRight)])
    }

    @Test func doubleTapOnlyCornerIgnoresSingleTaps() {
        var binding = ZoneBinding.buttons()
        binding.doubleTap = Action(.plugin, "xray_toggle")
        var e = engine([.topLeft: binding])
        #expect(run(&e, rest(0.05, 0.95)) == [.began(.topLeft), .ended(.topLeft)])
    }

    @Test func quickTouchIsATap() {
        var e = engine(bindings)
        #expect(run(&e, rest(0.95, 0.95, ms: 100)) == [.began(.topRight), .tap(.topRight), .ended(.topRight)])
    }

    @Test func longTouchHoldsOnceAndNeverTaps() {
        var e = engine(bindings)
        #expect(run(&e, rest(0.95, 0.95, ms: 700)) == [.began(.topRight), .hold(.topRight), .ended(.topRight)])
    }

    @Test func pauseBetweenTapAndHoldDoesNothing() {
        var e = engine(bindings)
        #expect(run(&e, rest(0.95, 0.95, ms: 350)) == [.began(.topRight), .ended(.topRight)])
    }

    @Test func movingOutOfACornerCancels() {
        var e = engine(bindings)
        let path = stride(from: 0.95, through: 0.6, by: -0.03).map { ($0, 0.95) }
        #expect(run(&e, path) == [.began(.topRight), .cancelled(.topRight)])
    }

    @Test func cornerWithoutHoldIgnoresLongPress() {
        var e = engine([.topLeft: .buttons(tap: Action(.toggleMic))])
        #expect(run(&e, rest(0.05, 0.95, ms: 700)) == [.began(.topLeft), .ended(.topLeft)])
    }
}

@Suite struct ConfigTests {
    @Test func roundTrips() throws {
        let config = MarginConfig.standard
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(MarginConfig.self, from: data) == config)
    }

    @Test func handEditedPartialConfigFillsDefaults() throws {
        let json = #"{"base":{"id":"7C9F4B0E-9B1B-4E6C-9C6D-0A4E0D2F1A11","name":"Mine","bundleIDs":[],"bindings":{"leftEdge":{"mode":"slider","slider":"volume"}}},"tuning":{"dwellMs":40}}"#
        let config = try JSONDecoder().decode(MarginConfig.self, from: Data(json.utf8))
        #expect(config.enabled)
        #expect(config.tuning.dwellMs == 40)
        #expect(config.tuning.edgeWidth == Tuning().edgeWidth)
        #expect(config.base[.leftEdge]?.sensitivity == ZoneBinding().sensitivity)
    }

    /// A file from a newer Margin, or with a typo, must keep everything this
    /// version understands instead of falling back to the defaults.
    @Test func unknownValuesOnlyLoseTheirOwnZone() throws {
        let json = #"""
        {"haptics":"thunder","appearance":"sepia","smartEdges":false,
         "base":{"id":"7C9F4B0E-9B1B-4E6C-9C6D-0A4E0D2F1A11","name":"Mine","bindings":{
           "leftEdge":{"mode":"slider","slider":"volume","sensitivity":2},
           "rightEdge":{"mode":"slider","slider":"hologram"},
           "topEdge":{"mode":"semantic","semantic":"teleport"},
           "bottomEdge":{"mode":"warp"},
           "topLeft":{"mode":"buttons","tap":{"kind":"summon","value":"x"},"hold":{"kind":"playPause"}}}}}
        """#
        let config = try JSONDecoder().decode(MarginConfig.self, from: Data(json.utf8))
        #expect(config.smartEdges == false)
        #expect(config.haptics == .light)
        #expect(config.appearance == .system)
        #expect(config.base[.leftEdge]?.mode == .slider)
        #expect(config.base[.leftEdge]?.sensitivity == 2)
        // An unknown slider doesn't quietly become a volume slider.
        #expect(config.base[.rightEdge]?.mode == .off)
        #expect(config.base[.topEdge]?.mode == .off)
        #expect(config.base[.bottomEdge]?.mode == .off)
        #expect(config.base[.topLeft]?.tap.kind == ActionKind.none)
        #expect(config.base[.topLeft]?.hold.kind == .playPause)
    }

    @Test func handEditedTuningIsHeldToRange() throws {
        let json = #"{"base":{"id":"7C9F4B0E-9B1B-4E6C-9C6D-0A4E0D2F1A11","name":"Mine"},"tuning":{"edgeWidth":0.5,"cornerWidth":0,"holdMs":-10,"palmMajorAxis":1000,"dwellMs":120}}"#
        let tuning = try JSONDecoder().decode(MarginConfig.self, from: Data(json.utf8)).tuning
        #expect(tuning.edgeWidth == Tuning.edgeWidthRange.upperBound)
        #expect(tuning.cornerWidth == Tuning.cornerWidthRange.lowerBound)
        #expect(tuning.holdMs == Tuning.holdRange.lowerBound)
        #expect(tuning.palmMajorAxis == Tuning.palmRange.upperBound)
        #expect(tuning.dwellMs == 120)
    }

    @Test func defaultTuningIsInsideItsRanges() {
        let t = Tuning()
        let checks: [(Double, ClosedRange<Double>)] = [
            (t.edgeWidth, Tuning.edgeWidthRange), (t.edgeHeight, Tuning.edgeHeightRange),
            (t.cornerWidth, Tuning.cornerWidthRange), (t.cornerHeight, Tuning.cornerHeightRange),
            (t.dwellMs, Tuning.dwellRange), (t.slop, Tuning.slopRange), (t.tapMaxMs, Tuning.tapMaxRange),
            (t.holdMs, Tuning.holdRange), (t.doubleTapMs, Tuning.doubleTapRange), (t.restMs, Tuning.restRange),
            (t.typingGuardMs, Tuning.typingGuardRange), (t.palmMajorAxis, Tuning.palmRange),
        ]
        for (value, range) in checks { #expect(range.contains(value)) }
    }

    @Test func defaultKeyCombosAllParse() {
        let config = MarginConfig.standard
        for profile in [config.base] + config.apps {
            for binding in profile.bindings.values {
                for action in [binding.forward, binding.backward, binding.tap, binding.hold] where action.kind == .keyCombo {
                    #expect(KeyCombo(action.value) != nil, "\(action.value)")
                }
            }
        }
    }
}

@Suite struct KeyComboTests {
    @Test func modifiersAndKey() throws {
        let combo = try #require(KeyCombo("cmd+shift+]"))
        #expect(combo.keyCode == 30 && combo.command && combo.shift && !combo.option && !combo.control)
    }

    @Test func plusKeyAndNamedKeys() throws {
        #expect(try #require(KeyCombo("cmd++")).keyCode == 24)
        #expect(try #require(KeyCombo("ctrl+left")).keyCode == 123)
        #expect(try #require(KeyCombo("F5")).keyCode == 96)
    }

    @Test func rejectsGarbage() {
        #expect(KeyCombo("") == nil)
        #expect(KeyCombo("cmd") == nil)
        #expect(KeyCombo("a+b") == nil)
        #expect(KeyCombo("hyper+q") == nil)
    }
}

@Suite struct PanelSettingTests {
    @Test func swapSidesExchangesTheEdgesBothWays() {
        var config = MarginConfig.standard
        #expect(!config.swapSides)
        config.swapSides = true
        #expect(config.swapSides)
        #expect(config.base[.leftEdge]?.slider == .volume)
        #expect(config.base[.rightEdge]?.slider == .brightness)
        config.swapSides = false
        #expect(config.base[.rightEdge]?.slider == .volume)
    }

    @Test func togglesReadBackAndLeaveNeighboursAlone() {
        var config = MarginConfig.standard
        #expect(config.quickMute && config.mediaStrip && config.tapToPlay)
        config.quickMute = false
        #expect(!config.quickMute && config.tapToPlay)
        config.tapToPlay = false
        #expect(!config.tapToPlay)
        #expect(config.base[.topRight]?.isActive == false)
        config.mediaStrip = false
        #expect(config.base[.topEdge]?.isActive == false)
        config.mediaStrip = true
        #expect(config.base[.topEdge]?.forward.kind == .nextTrack)
    }

    @Test func sensitivityCoversBothSliders() {
        var config = MarginConfig.standard
        config.sensitivity = 2.5
        #expect(config.base[.leftEdge]?.sensitivity == 2.5)
        #expect(config.base[.rightEdge]?.sensitivity == 2.5)
    }

    @Test func lowerQuarterLimitsOnlyTheSideEdges() {
        var t = Tuning()
        t.lowerQuarterOnly = true
        #expect(Zones.locate(x: 0.02, y: 0.6, tuning: t) { $0 == .leftEdge } == nil)
        #expect(Zones.locate(x: 0.02, y: 0.2, tuning: t) { $0 == .leftEdge } == .leftEdge)
        #expect(Zones.locate(x: 0.5, y: 0.98, tuning: t) { $0 == .topEdge } == .topEdge)
    }
}

@Suite struct FreePlanTests {
    @Test func freeKeepsVolumeAndSkipAndNothingElse() {
        let limited = MarginConfig.standard.limited(to: .free)
        #expect(limited.base[.rightEdge]?.slider == .volume)
        #expect(limited.base[.rightEdge]?.mode == .slider)
        #expect(limited.base[.topEdge]?.forward.kind == .nextTrack)
        #expect(limited.base[.leftEdge]?.mode == .off)
        #expect(limited.base[.topLeft]?.mode == .off)
        #expect(limited.base[.topRight]?.mode == .off)
    }

    @Test func freeFeaturesAreExactlyVolumeSkipAndOff() {
        let free = FeatureCatalog.system.filter(\.isFree).map(\.title).sorted()
        #expect(free == ["Next track", "Off", "Output volume", "Previous track", "Skip tracks"])
    }

    @Test func searchMatchesTitlesAndKeywords() {
        #expect(FeatureCatalog.search("sound", in: FeatureCatalog.system).first?.title == "Output volume")
        #expect(FeatureCatalog.search("zzzz", in: FeatureCatalog.system).isEmpty)
    }

    @Test func aProfileAppliesOnlyToItsApp() {
        var config = MarginConfig.standard
        config.smartEdges = false
        config.apps = [Profile(name: "Mail", bundleIDs: ["com.apple.mail"], bindings: [.leftEdge: .slider(.scroll)])]
        #expect(config.bindings(for: AppContext(bundleID: "com.apple.mail"))[.leftEdge]?.slider == .scroll)
        #expect(config.bindings(for: AppContext(bundleID: "com.apple.Notes"))[.leftEdge]?.slider == .brightness)
    }
}
