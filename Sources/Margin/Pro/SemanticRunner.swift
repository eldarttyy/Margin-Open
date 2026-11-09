import AppKit
import ApplicationServices
import MarginCore

/// Performs semantic actions in the app in front. Menus are tried first because
/// a menu item is the app's own command, and it reports when it's unavailable.
/// Keys are the fallback. Runs on `ActionRunner`'s queue.
final class SemanticRunner {
    private typealias Item = MenuEntry<AXUIElement>

    private var pid: pid_t = 0
    private var menu: [Item]?
    private var pointer: PointerTarget?

    /// A hung app could otherwise stall every gesture behind it.
    private static let timeout: Float = 0.3
    private static let maxItems = 4000
    /// How long reading a menu bar may hold up a gesture. Listing for Settings
    /// runs apart from gestures, so it can take longer.
    private var readBudget = 1.5
    private var readDeadline = Date.distantFuture

    func setFrontmost(pid: pid_t) {
        self.pid = pid
        menu = nil
    }

    func step(_ action: SemanticAction, forward: Bool) {
        if let found = MenuMatcher.options(action, in: items()) {
            let options = forward ? found.forward : found.backward
            let usable = options.first { (Self.attribute($0.handle, kAXEnabledAttribute) as Bool?) != false } ?? options[0]
            press(usable.handle)
        } else if let keys = action.keys, let combo = KeyCombo(forward ? keys.forward : keys.backward) {
            Input.post(combo)
        }
    }

    /// The app commands go to. Stays put while Margin's own window is in front.
    var targetPid: pid_t { pid }

    /// True while a text box has the keyboard, where a site's plain `k` would
    /// land in the text instead of working the page.
    var isEditingText: Bool {
        guard pid != 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        guard let focused: AXUIElement = Self.attribute(app, kAXFocusedUIElementAttribute) else { return false }
        let role: String = Self.attribute(focused, kAXRoleAttribute) ?? ""
        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }

    /// Presses a menu command and returns Apple's result code, for diagnostics.
    func pressResult(_ path: String) -> Int32? {
        guard let item = MenuMatcher.find(path, in: items()) else { return nil }
        return AXUIElementPerformAction(item.handle, kAXPressAction as CFString).rawValue
    }

    /// Runs any menu command in the app in front. False when it isn't there.
    func pressMenu(_ path: String) -> Bool {
        guard let item = MenuMatcher.find(path, in: items()) else { return false }
        press(item.handle)
        return true
    }

    /// Every path in the menu bar of an app, for the feature library. Call off
    /// the main thread: a large app has thousands of items.
    static func menuPaths(pid: pid_t) -> [[String]] {
        let runner = SemanticRunner()
        runner.readBudget = 10
        runner.setFrontmost(pid: pid)
        return runner.items().map(\.path)
    }

    struct MenuCommand {
        var path: [String]
        var combo: String?
        var enabled: Bool
    }

    /// Every command in an app's menu bar with the shortcut it really has.
    static func menuCommands(pid: pid_t) -> [MenuCommand] {
        let runner = SemanticRunner()
        runner.setFrontmost(pid: pid)
        return runner.items().map {
            MenuCommand(path: $0.path, combo: shortcut(of: $0.handle), enabled: (attribute($0.handle, kAXEnabledAttribute) as Bool?) != false)
        }
    }

    /// The item's shortcut in `KeyCombo` text. Modifier bits are Apple's: 1 is
    /// shift, 2 option, 4 control and 8 means no command key.
    private static func shortcut(of item: AXUIElement) -> String? {
        let char: String? = attribute(item, kAXMenuItemCmdCharAttribute)
        let glyph = (attribute(item, kAXMenuItemCmdGlyphAttribute) as NSNumber?)?.intValue ?? 0
        let virtualKey = (attribute(item, kAXMenuItemCmdVirtualKeyAttribute) as NSNumber?)?.intValue ?? 0
        let modifiers = (attribute(item, kAXMenuItemCmdModifiersAttribute) as NSNumber?)?.intValue ?? 0
        let glyphs = [100: "left", 101: "right", 104: "up", 106: "down", 2: "tab", 23: "delete", 27: "escape", 4: "return", 11: "return", 9: "space"]
        var key: String?
        if let name = glyphs[glyph] {
            key = name
        } else if let char, !char.isEmpty, char.unicodeScalars.first?.value ?? 0 >= 0x20, char.unicodeScalars.first?.value ?? 0 < 0x7F {
            key = char == " " ? "space" : char.lowercased()
        } else if virtualKey != 0 {
            key = KeyCombo.text(keyCode: UInt16(virtualKey), command: false, shift: false, option: false, control: false)
        }
        guard let key else { return nil }
        var parts: [String] = []
        if modifiers & 4 != 0 { parts.append("ctrl") }
        if modifiers & 2 != 0 { parts.append("opt") }
        if modifiers & 1 != 0 { parts.append("shift") }
        if modifiers & 8 == 0 { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// Every item in the app's menu bar, read once per activation.
    private func items() -> [Item] {
        if let menu { return menu }
        var found: [Item] = []
        if pid != 0, AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(pid)
            // Set on the system-wide element, because a timeout on one element
            // doesn't reach the menu items read from it.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.timeout)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            readDeadline = Date(timeIntervalSinceNow: readBudget)
            if let bar: AXUIElement = Self.attribute(app, kAXMenuBarAttribute) {
                walk(bar, path: [], depth: 0, into: &found)
            }
        }
        menu = found
        return found
    }

    private func walk(_ element: AXUIElement, path: [String], depth: Int, into found: inout [Item]) {
        guard depth < 6, found.count < Self.maxItems, Date() < readDeadline else { return }
        let children: [AXUIElement] = Self.attribute(element, kAXChildrenAttribute) ?? []
        for child in children {
            let title: String = Self.attribute(child, kAXTitleAttribute) ?? ""
            let nextPath = title.isEmpty ? path : path + [title]
            if !title.isEmpty, (Self.attribute(child, kAXRoleAttribute) as String?) == kAXMenuItemRole {
                found.append(Item(path: nextPath, title: title, handle: child))
            }
            walk(child, path: nextPath, depth: depth + 1, into: &found)
        }
    }

    private func press(_ element: AXUIElement) {
        guard (Self.attribute(element, kAXEnabledAttribute) as Bool?) != false else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: Value under the pointer

    private struct PointerTarget {
        var element: AXUIElement
        var name: String
        var value: Double?
        var min: Double
        var max: Double
        var stepAccumulator = 0.0
    }

    /// Finds an adjustable control at a screen point, checking a few parents
    /// because the hit is often a slider's inner indicator.
    func beginPointer(at point: CGPoint) {
        pointer = nil
        guard AXIsProcessTrusted() else { return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return }
        var current = hit
        for _ in 0..<4 {
            guard let element = current else { return }
            let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
            let name: String = Self.attribute(element, kAXTitleAttribute) ?? Self.attribute(element, kAXDescriptionAttribute) ?? "Value"
            let number: NSNumber? = Self.attribute(element, kAXValueAttribute)
            if role == kAXSliderRole, let number,
               let low: NSNumber = Self.attribute(element, kAXMinValueAttribute),
               let high: NSNumber = Self.attribute(element, kAXMaxValueAttribute) {
                pointer = PointerTarget(element: element, name: name, value: number.doubleValue, min: low.doubleValue, max: high.doubleValue)
                return
            }
            if role == kAXIncrementorRole {
                pointer = PointerTarget(element: element, name: name, value: nil, min: 0, max: 0)
                return
            }
            current = Self.attribute(element, kAXParentAttribute)
        }
    }

    /// Moves the captured control, returning what to show. Nil when there's nothing under the pointer.
    func slidePointer(travel: Double) -> (name: String, fraction: Double?)? {
        guard var target = pointer else { return nil }
        defer { pointer = target }
        if let value = target.value {
            let next = Swift.min(target.max, Swift.max(target.min, value + travel * (target.max - target.min)))
            target.value = next
            AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, next as CFNumber)
            return (target.name, target.max > target.min ? (next - target.min) / (target.max - target.min) : nil)
        }
        target.stepAccumulator += travel
        if abs(target.stepAccumulator) >= 0.05 {
            let up = target.stepAccumulator > 0
            target.stepAccumulator = 0
            AXUIElementPerformAction(target.element, (up ? kAXIncrementAction : kAXDecrementAction) as CFString)
        }
        return (target.name, nil)
    }

    func endPointer() { pointer = nil }
}
