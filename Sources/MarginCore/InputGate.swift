import Foundation

/// Decides which system input events Margin swallows during a gesture. It sits
/// in the path of every click and key on the Mac, so a state that can't clear
/// itself would take the mouse away from the whole system. Anything open here
/// therefore lapses once touch frames stop, whatever became of the finger.
public struct InputGate: Sendable {
    public enum Event: Equatable, Sendable {
        case mouseMoved, mouseDown, mouseUp
        case keyDown(isCaps: Bool), keyUp(isCaps: Bool)
    }

    /// Frames arrive constantly while a finger is down, so silence this long
    /// means the lift was missed, as when the Mac sleeps mid-touch.
    public static let staleAfter = 0.25

    public private(set) var capsHeld = false
    public private(set) var lastKey = 0.0
    private var holding = false
    private var lastFrame = 0.0
    private var clickGuardOpen = false
    private var clickGuardUntil = 0.0
    private var droppedDown = false

    public init() {}

    public var isHolding: Bool { holding }

    public mutating func hold(now: Double) {
        holding = true
        lastFrame = now
    }

    public mutating func frame(now: Double) { lastFrame = now }

    public mutating func releaseHold() { holding = false }

    public mutating func openClickGuard(now: Double) {
        clickGuardOpen = true
        lastFrame = now
    }

    /// Clicks stay swallowed until `until`, if the guard was open.
    public mutating func closeClickGuard(until: Double) {
        guard clickGuardOpen else { return }
        clickGuardOpen = false
        clickGuardUntil = until
    }

    /// True when the event must not reach the system.
    public mutating func shouldDrop(_ event: Event, now: Double) -> Bool {
        switch event {
        case .keyDown(let isCaps):
            if isCaps { capsHeld = true } else { lastKey = now }
            return isCaps
        case .keyUp(let isCaps):
            if isCaps { capsHeld = false }
            return isCaps
        case .mouseMoved:
            if holding, now - lastFrame > Self.staleAfter { holding = false }
            return holding
        case .mouseDown:
            if clickGuardOpen, now - lastFrame > Self.staleAfter { clickGuardOpen = false }
            droppedDown = clickGuardOpen || now < clickGuardUntil
            return droppedDown
        case .mouseUp:
            defer { droppedDown = false }
            return droppedDown
        }
    }
}
