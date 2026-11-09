import ApplicationServices
import Foundation
import MarginCore

/// Reads the address of the page in front from a browser's own toolbar, so
/// websites work with the one permission Margin already has. The toolbar stays
/// cheap to read, where asking a browser for its page contents would slow it.
final class SiteReader {
    private static let timeout: Float = 0.2
    private static let maxElements = 1500
    /// How long one search of a window may take.
    private static let searchBudget = 0.25
    private static let firstRetry = 2.0
    private static let lastRetry = 30.0
    private var pid: pid_t = 0
    private var window: AXUIElement?
    private var field: AXUIElement?
    /// A window with no bar, like a full-screen video, is searched less and less.
    private var nextSearch = 0.0
    private var retry = SiteReader.firstRetry

    /// What the address bar shows now, or nil if there's no window or no bar,
    /// as in a video gone full screen.
    func address(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        // Set on the system-wide element too, because a timeout on one element
        // doesn't reach the ones read from it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.timeout)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        guard let front: AXUIElement = Self.attribute(app, kAXFocusedWindowAttribute) else { return nil }
        if pid != self.pid || window.map({ !CFEqual($0, front) }) ?? true {
            self.pid = pid
            window = front
            field = nil
            nextSearch = 0
            retry = Self.firstRetry
        }
        if let field, let value: String = Self.attribute(field, kAXValueAttribute) { return value }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextSearch {
            field = find(in: front)
            if field == nil {
                nextSearch = now + retry
                retry = min(retry * 2, Self.lastRetry)
            } else {
                retry = Self.firstRetry
            }
        } else {
            field = nil
        }
        return field.flatMap { Self.attribute($0, kAXValueAttribute) } ?? pageAddress(in: app)
    }

    /// Firefox shares no toolbar, but its page reports its own address once it
    /// has been asked to open up. Only asked of it, because the same request
    /// makes Chrome build its whole page tree, which would slow it down.
    func openUp(pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// The page holding the keyboard focus, or nil while focus is outside one.
    private func pageAddress(in app: AXUIElement) -> String? {
        var current: AXUIElement? = Self.attribute(app, kAXFocusedUIElementAttribute)
        for _ in 0..<16 {
            guard let element = current else { return nil }
            if (Self.attribute(element, kAXRoleAttribute) as String?) == "AXWebArea" {
                let url: URL? = Self.attribute(element, kAXURLAttribute)
                return url?.absoluteString
            }
            current = Self.attribute(element, kAXParentAttribute)
        }
        return nil
    }

    /// Breadth first, because the toolbar sits near the top of a window and
    /// the page below it can be enormous.
    private func find(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + Self.searchBudget
        while index < queue.count, index < Self.maxElements, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue[index]
            index += 1
            let role: String = Self.attribute(element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { continue }
            if role == kAXTextFieldRole, Self.isAddressBar(element) { return element }
            queue += (Self.attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        return nil
    }

    private static func isAddressBar(_ element: AXUIElement) -> Bool {
        let names: [String?] = [attribute(element, kAXDescriptionAttribute), attribute(element, kAXIdentifierAttribute), attribute(element, kAXTitleAttribute)]
        return names.contains { name in
            guard let name = name?.lowercased() else { return false }
            return name.contains("address") || name.contains("search field") || name.contains("url")
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// Watches a browser's front tab and reports which known site it's on. Only
/// that pack's ID leaves here: addresses are never kept, saved or sent.
final class SiteWatcher {
    private let queue = DispatchQueue(label: "margin.sites", qos: .utility)
    private let reader = SiteReader()
    private var timer: DispatchSourceTimer?
    private var last: String?

    /// Called on the main queue.
    var onChange: ((String?) -> Void)?

    /// Starts on a browser, or stops with nil.
    func watch(pid: pid_t?, bundleID: String? = nil) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            last = nil
            guard let pid else { return }
            if bundleID == "org.mozilla.firefox" { reader.openUp(pid: pid) }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1)
            source.setEventHandler { [weak self] in self?.check(pid) }
            source.resume()
            timer = source
        }
    }

    private func check(_ pid: pid_t) {
        // No address means no toolbar, so a full-screen video keeps its site.
        guard let address = reader.address(pid: pid) else { return }
        let site = Sites.pack(address: address)?.id
        guard site != last else { return }
        last = site
        DispatchQueue.main.async { [self] in onChange?(site) }
    }
}
