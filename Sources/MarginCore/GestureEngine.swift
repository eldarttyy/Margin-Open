import Foundation

/// One contact from the trackpad, in normalized pad coordinates.
public struct TouchSample: Equatable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var majorAxis: Double

    public init(id: Int, x: Double, y: Double, majorAxis: Double = 8) {
        self.id = id
        self.x = x
        self.y = y
        self.majorAxis = majorAxis
    }
}

public enum Zones {
    /// The bound zone under a point. A corner with no binding falls through to
    /// the edge beneath it, so an unbound corner doesn't shorten a slider.
    public static func locate(x: Double, y: Double, tuning t: Tuning, isBound: (ZoneID) -> Bool) -> ZoneID? {
        let left = x < t.cornerWidth, right = x > 1 - t.cornerWidth
        let bottom = y < t.cornerHeight, top = y > 1 - t.cornerHeight
        var corner: ZoneID?
        if top && left { corner = .topLeft }
        if top && right { corner = .topRight }
        if bottom && left { corner = .bottomLeft }
        if bottom && right { corner = .bottomRight }
        if let corner, isBound(corner) { return corner }

        let sideAllowed = !t.lowerQuarterOnly || y < 0.25
        if x < t.edgeWidth, sideAllowed, isBound(.leftEdge) { return .leftEdge }
        if x > 1 - t.edgeWidth, sideAllowed, isBound(.rightEdge) { return .rightEdge }
        if y > 1 - t.edgeHeight, isBound(.topEdge) { return .topEdge }
        if y < t.edgeHeight, isBound(.bottomEdge) { return .bottomEdge }
        return nil
    }
}

public enum GestureEvent: Equatable, Sendable {
    /// A finger came down in a bound zone. Nothing is committed yet.
    case began(ZoneID)
    /// An edge finger passed the dwell, so the cursor should stop following it.
    case captured(ZoneID)
    /// Signed travel along the edge. Positive is up or right.
    case slide(ZoneID, Double)
    case step(ZoneID, forward: Bool)
    case tap(ZoneID)
    case hold(ZoneID)
    /// A tap on a zone that also has a double-tap. The host waits out the
    /// double-tap window before acting, and a `.doubleTap` cancels it.
    case deferredTap(ZoneID)
    case doubleTap(ZoneID)
    /// A finger has rested on an edge long enough to ask what it does.
    case rested(ZoneID)
    /// The finger lifted at the end of a gesture.
    case ended(ZoneID)
    /// The gesture was abandoned and the touch belongs to macOS after all.
    case cancelled(ZoneID)
}

/// Turns touch frames into gesture events. One instance per device.
///
/// A gesture is one finger, starting in a zone. Any second finger hands the
/// whole touch back to macOS until every finger has lifted, which keeps
/// two-finger scrolling and system swipes out of Margin's way.
public struct GestureEngine {
    /// Travel, as a fraction of the pad, that fires a stepper's first step.
    static let firstStep = 0.04

    public var tuning: Tuning
    public var bindings: [ZoneID: ZoneBinding]

    private struct Track {
        let zone: ZoneID
        let touchID: Int
        let startX, startY, startTime: Double
        var captured = false
        var sliding = false
        var holdFired = false
        var restFired = false
        var lastAlong = 0.0
        var stepAccumulator = 0.0
        var hasStepped = false
    }

    private enum Phase {
        case idle
        case ignoring
        case tracking(Track)
    }

    private var phase = Phase.idle
    private var lastTap: (zone: ZoneID, time: Double)?

    public init(tuning: Tuning, bindings: [ZoneID: ZoneBinding]) {
        self.tuning = tuning
        self.bindings = bindings
    }

    /// True from touch-down to lift of a gesture.
    public var isTracking: Bool {
        if case .tracking = phase { return true }
        return false
    }

    /// True while an edge finger is being tracked.
    public var isTrackingEdge: Bool {
        if case .tracking(let t) = phase { return !t.zone.isCorner }
        return false
    }

    /// Hands the current touch back to macOS, for example on a physical click.
    public mutating func cancel() -> [GestureEvent] {
        guard case .tracking(let t) = phase else { return [] }
        phase = .ignoring
        return [.cancelled(t.zone)]
    }

    /// `touches` holds the contacts currently down. `time` is in seconds.
    public mutating func process(touches: [TouchSample], time: Double) -> [GestureEvent] {
        let fingers = touches.filter { $0.majorAxis <= tuning.palmMajorAxis }

        switch phase {
        case .idle:
            guard let first = fingers.first else { return [] }
            guard fingers.count == 1,
                  let zone = Zones.locate(x: first.x, y: first.y, tuning: tuning, isBound: { bindings[$0]?.isActive == true })
            else {
                phase = .ignoring
                return []
            }
            phase = .tracking(Track(zone: zone, touchID: first.id, startX: first.x, startY: first.y, startTime: time))
            return [.began(zone)]

        case .ignoring:
            if fingers.isEmpty { phase = .idle }
            return []

        case .tracking(var track):
            guard !fingers.isEmpty else {
                phase = .idle
                return lifted(track, time: time)
            }
            guard fingers.count == 1, fingers[0].id == track.touchID else {
                phase = .ignoring
                return [.cancelled(track.zone)]
            }
            let events = track.zone.isCorner
                ? updateCorner(&track, finger: fingers[0], time: time)
                : updateEdge(&track, finger: fingers[0], time: time)
            if case .tracking = phase { phase = .tracking(track) }
            return events
        }
    }

    private mutating func lifted(_ track: Track, time: Double) -> [GestureEvent] {
        var events: [GestureEvent] = []
        let binding = bindings[track.zone]
        let quick = track.zone.isCorner && !track.holdFired && (time - track.startTime) * 1000 <= tuning.tapMaxMs
        if quick {
            if binding?.hasDoubleTap == true {
                if let last = lastTap, last.zone == track.zone, (time - last.time) * 1000 <= tuning.doubleTapMs {
                    lastTap = nil
                    events.append(.doubleTap(track.zone))
                } else {
                    lastTap = (track.zone, time)
                    if binding?.hasTap == true { events.append(.deferredTap(track.zone)) }
                }
            } else if binding?.hasTap == true {
                events.append(.tap(track.zone))
            }
        }
        events.append(.ended(track.zone))
        return events
    }

    private mutating func updateCorner(_ track: inout Track, finger: TouchSample, time: Double) -> [GestureEvent] {
        let moved = hypot(finger.x - track.startX, finger.y - track.startY)
        if moved > tuning.slop * 2 {
            phase = .ignoring
            return [.cancelled(track.zone)]
        }
        let held = (time - track.startTime) * 1000
        if !track.holdFired, held >= tuning.holdMs, bindings[track.zone]?.hasHold == true {
            track.holdFired = true
            return [.hold(track.zone)]
        }
        return []
    }

    private mutating func updateEdge(_ track: inout Track, finger: TouchSample, time: Double) -> [GestureEvent] {
        let vertical = track.zone.slidesVertically
        let along = vertical ? finger.y : finger.x
        let dAlong = along - (vertical ? track.startY : track.startX)
        let dPerpendicular = (vertical ? finger.x : finger.y) - (vertical ? track.startX : track.startY)

        if !track.captured {
            if abs(dPerpendicular) > tuning.slop * 2, abs(dPerpendicular) > abs(dAlong) {
                // Heading into the pad: an ordinary cursor move that began at the edge.
                phase = .ignoring
                return [.cancelled(track.zone)]
            }
            guard (time - track.startTime) * 1000 >= tuning.dwellMs else { return [] }
            track.captured = true
            return [.captured(track.zone)]
        }

        if !track.sliding {
            if abs(dAlong) > tuning.slop, abs(dAlong) >= abs(dPerpendicular) {
                track.sliding = true
                track.lastAlong = along
                return []
            }
            if abs(dPerpendicular) > tuning.slop {
                // Rested, then headed into the pad. The cursor gets it back.
                phase = .ignoring
                return [.cancelled(track.zone)]
            }
            if !track.restFired, (time - track.startTime) * 1000 >= tuning.restMs {
                track.restFired = true
                return [.rested(track.zone)]
            }
            return []
        }

        let delta = along - track.lastAlong
        track.lastAlong = along
        guard delta != 0, let binding = bindings[track.zone] else { return [] }

        if binding.isContinuous { return [.slide(track.zone, delta)] }

        var events: [GestureEvent] = []
        track.stepAccumulator += delta
        let step = max(binding.stepSize, 0.005)
        // The first step answers a short swipe, so one command is one flick.
        if !track.hasStepped, abs(track.stepAccumulator) >= min(step, Self.firstStep) {
            events.append(.step(track.zone, forward: track.stepAccumulator > 0))
            track.stepAccumulator = 0
            track.hasStepped = true
        }
        while abs(track.stepAccumulator) >= step {
            let forward = track.stepAccumulator > 0
            events.append(.step(track.zone, forward: forward))
            track.stepAccumulator -= forward ? step : -step
        }
        return events
    }
}
