import AppKit
import ApplicationServices
import MarginCore

/// Reads the buttons, toggles, tabs and sliders in an app's windows and works
/// them through Accessibility, so a zone can do anything a click can. The app
/// doesn't have to be in front, and nothing moves the pointer.
final class ScreenReader: @unchecked Sendable {
    static let shared = ScreenReader()

    struct Found {
        var control: ScreenControl
        var element: AXUIElement
    }

    private static let timeout: Float = 0.3
    private static let maxNodes = 8000
    private let lock = NSLock()
    /// Where each target was last found. Checked before use, because a
    /// redrawn window hands out new elements.
    private var cache: [String: (pid: pid_t, element: AXUIElement)] = [:]
    /// Apps already asked to build their tree. Electron and Chromium apps only
    /// report their window's contents after `AXManualAccessibility`.
    private var awakened = Set<pid_t>()

    // MARK: Reading

    /// Every labeled control in the app's windows, the focused window first.
    func controls(pid: pid_t, budget: TimeInterval) -> [Found] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        awaken(app, pid: pid)
        // Finder lists the desktop among its windows, and its controls aren't the app's.
        var windows: [AXUIElement] = (Self.attribute(app, kAXWindowsAttribute) ?? [])
            .filter { (Self.attribute($0, kAXRoleAttribute) as String?) == kAXWindowRole }
        if let focused: AXUIElement = Self.attribute(app, kAXFocusedWindowAttribute),
           let index = windows.firstIndex(where: { CFEqual($0, focused) }) {
            windows.insert(windows.remove(at: index), at: 0)
        }
        let deadline = Date(timeIntervalSinceNow: budget)
        var found: [Found] = []
        var visited = 0
        for window in windows {
            walk(window, depth: 0, deadline: deadline, visited: &visited, into: &found)
        }
        return found
    }

    private func awaken(_ app: AXUIElement, pid: pid_t) {
        lock.lock()
        let first = awakened.insert(pid).inserted
        lock.unlock()
        guard first else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func walk(_ element: AXUIElement, depth: Int, deadline: Date, visited: inout Int, into found: inout [Found]) {
        guard depth < 60, visited < Self.maxNodes, Date() < deadline else { return }
        visited += 1
        let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
        let subrole: String = Self.attribute(element, kAXSubroleAttribute) ?? ""
        if let kind = ScreenControl.Kind(role: role, subrole: subrole) {
            let label = Self.label(of: element)
            if !label.isEmpty { found.append(Found(control: ScreenControl(kind: kind, label: label), element: element)) }
            // A control's insides are its own parts, not more controls.
            if kind != .popUp, kind != .link { return }
        }
        let children: [AXUIElement] = Self.attribute(element, kAXChildrenAttribute) ?? []
        for child in children { walk(child, depth: depth + 1, deadline: deadline, visited: &visited, into: &found) }
    }

    /// The name a person sees or a screen reader speaks.
    static func label(of element: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let text: String = attribute(element, name) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        // A button that shows only an image often names the image instead.
        let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for child in children.prefix(3) {
            if let text: String = attribute(child, kAXDescriptionAttribute) ?? attribute(child, kAXValueAttribute) as String?,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    // MARK: Doing

    enum Outcome: Equatable {
        case done, appNotRunning, notFound, disabled, noAccess
    }

    /// Presses, or nudges a slider, wherever the target lives.
    @discardableResult
    func perform(_ target: ScreenTarget) -> Outcome {
        guard AXIsProcessTrusted() else { return .noAccess }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first else {
            return .appNotRunning
        }
        let pid = app.processIdentifier
        let key = "\(target.bundleID)|\(target.kind.rawValue)|\(target.label)"
        guard let element = cached(key, pid: pid, target: target) ?? search(target, pid: pid, cacheKey: key) else {
            return .notFound
        }
        if (Self.attribute(element, kAXEnabledAttribute) as Bool?) == false { return .disabled }
        let name: String
        switch target.verb {
        case .press: name = target.kind == .popUp ? kAXShowMenuAction : kAXPressAction
        case .increment: name = kAXIncrementAction
        case .decrement: name = kAXDecrementAction
        }
        let result = AXUIElementPerformAction(element, name as CFString)
        if result != .success, target.verb != .press { return nudge(element, up: target.verb == .increment) ? .done : .notFound }
        return result == .success ? .done : .notFound
    }

    /// For a slider that only takes a value, a twentieth of its range.
    private func nudge(_ element: AXUIElement, up: Bool) -> Bool {
        guard let value: NSNumber = Self.attribute(element, kAXValueAttribute),
              let low: NSNumber = Self.attribute(element, kAXMinValueAttribute),
              let high: NSNumber = Self.attribute(element, kAXMaxValueAttribute) else { return false }
        let step = (high.doubleValue - low.doubleValue) / 20
        let next = min(high.doubleValue, max(low.doubleValue, value.doubleValue + (up ? step : -step)))
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, next as CFNumber) == .success
    }

    private func cached(_ key: String, pid: pid_t, target: ScreenTarget) -> AXUIElement? {
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        guard let hit, hit.pid == pid else { return nil }
        // Still on screen, and still the same control.
        let role: String = Self.attribute(hit.element, kAXRoleAttribute) ?? ""
        let subrole: String = Self.attribute(hit.element, kAXSubroleAttribute) ?? ""
        guard let kind = ScreenControl.Kind(role: role, subrole: subrole),
              target.match(in: [ScreenControl(kind: kind, label: Self.label(of: hit.element))]) != nil else { return nil }
        return hit.element
    }

    private func search(_ target: ScreenTarget, pid: pid_t, cacheKey: String) -> AXUIElement? {
        var found = controls(pid: pid, budget: 1.0)
        if found.isEmpty {
            // A just-awakened Electron app fills in its tree a moment later.
            Thread.sleep(forTimeInterval: 0.3)
            found = controls(pid: pid, budget: 1.0)
        }
        guard let index = target.match(in: found.map(\.control)) else { return nil }
        let element = found[index].element
        lock.lock()
        cache[cacheKey] = (pid, element)
        lock.unlock()
        return element
    }

    // MARK: Pointing

    /// Where a control is on screen, top-left origin, for the dev check.
    func frame(of target: ScreenTarget) -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first else { return nil }
        let found = controls(pid: app.processIdentifier, budget: 3)
        guard let index = target.match(in: found.map(\.control)) else { return nil }
        let element = found[index].element
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position: AXValue = Self.attribute(element, kAXPositionAttribute),
              let extent: AXValue = Self.attribute(element, kAXSizeAttribute),
              AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// The control under a screen point (top-left origin), with its app.
    static func control(at point: CGPoint) -> (bundleID: String, control: ScreenControl)? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        var current = hit
        // The hit is often an icon or text inside the button.
        for _ in 0..<6 {
            guard let element = current else { return nil }
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            let subrole: String = attribute(element, kAXSubroleAttribute) ?? ""
            if let kind = ScreenControl.Kind(role: role, subrole: subrole) {
                let label = label(of: element)
                var pid: pid_t = 0
                guard !label.isEmpty, AXUIElementGetPid(element, &pid) == .success,
                      let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
                return (bundleID, ScreenControl(kind: kind, label: label))
            }
            current = attribute(element, kAXParentAttribute)
        }
        return nil
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
