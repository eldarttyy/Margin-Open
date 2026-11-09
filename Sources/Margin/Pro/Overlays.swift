import AppKit
import MarginCore
import SwiftUI

private func makePanel(size: NSSize, clickable: Bool) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = !clickable
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

// MARK: First-launch toast

/// What the toast is showing, kept live so touches can light it up.
@MainActor
final class ToastState: ObservableObject {
    @Published var app = ""
    @Published var rows: [EdgeGuideRow] = []
    /// The zone under a finger right now, or last used.
    @Published var active: ZoneID?
    /// Zones that have done something while the toast was up.
    @Published var tried: Set<ZoneID> = []

    var allTried: Bool { !rows.isEmpty && rows.allSatisfy { tried.contains($0.zone) } }
}

struct ToastView: View {
    @ObservedObject var state: ToastState
    let onCustomize: () -> Void
    let onClose: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    /// Room for every edge and the corners people use most; the rest is in Settings.
    static let maxRows = 6

    private var rows: [EdgeGuideRow] { Array(state.rows.prefix(Self.maxRows)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .center, spacing: 14) {
                ToastTrackpad(rows: rows, active: state.active, tried: state.tried)
                    .frame(width: 132, height: 88)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.zone) { row($0) }
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 468, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
        .padding(8)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.15), value: state.active)
        .animation(.easeOut(duration: 0.2), value: state.tried)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.app).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(state.allTried ? "You've tried every edge. You're set." : "Your trackpad edges in this app. Try one now.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private func row(_ row: EdgeGuideRow) -> some View {
        let isActive = state.active == row.zone
        let isTried = state.tried.contains(row.zone)
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: isTried ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundStyle(isTried ? Color.green : Color.secondary.opacity(0.5))
            Text(Self.shortTitle(row.zone)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.what).fontWeight(.medium)
                Text(row.how).foregroundStyle(.secondary).font(.system(size: 10.5))
            }
            .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            let tried = state.tried.intersection(rows.map(\.zone)).count
            Text(tried == 0 ? "Rest a finger on an edge to see this later" : "Tried \(tried) of \(rows.count)")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button("Customize", action: onCustomize).controlSize(.small)
        }
    }

    /// "Top edge" reads "Top", and "Top-left corner" reads "Top-left".
    static func shortTitle(_ zone: ZoneID) -> String {
        zone.title.replacingOccurrences(of: " edge", with: "").replacingOccurrences(of: " corner", with: "")
    }
}

/// A small trackpad with each working zone drawn where it really is.
private struct ToastTrackpad: View {
    let rows: [EdgeGuideRow]
    let active: ZoneID?
    let tried: Set<ZoneID>

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.7))
                RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12))
                ForEach(rows, id: \.zone) { row in
                    mark(row.zone, in: size)
                }
            }
        }
    }

    private func color(_ zone: ZoneID) -> Color {
        if zone == active { return .accentColor }
        if tried.contains(zone) { return .green.opacity(0.8) }
        return .primary.opacity(0.35)
    }

    @ViewBuilder private func mark(_ zone: ZoneID, in s: CGSize) -> some View {
        let inset: CGFloat = 6, thick: CGFloat = zone == active ? 6 : 4
        let corner: CGFloat = zone == active ? 12 : 9
        switch zone {
        case .leftEdge, .rightEdge:
            Capsule().fill(color(zone))
                .frame(width: thick, height: s.height * 0.5)
                .position(x: zone == .leftEdge ? inset : s.width - inset, y: s.height / 2)
        case .topEdge, .bottomEdge:
            Capsule().fill(color(zone))
                .frame(width: s.width * 0.55, height: thick)
                .position(x: s.width / 2, y: zone == .topEdge ? inset : s.height - inset)
        default:
            let left = zone == .topLeft || zone == .bottomLeft
            let top = zone == .topLeft || zone == .topRight
            Circle().fill(color(zone))
                .frame(width: corner, height: corner)
                .position(x: left ? inset + 4 : s.width - inset - 4, y: top ? inset + 4 : s.height - inset - 4)
        }
    }
}

/// Says what the edges do the first time an app comes to the front, and
/// stays while you try them.
@MainActor
final class Toast {
    static let shared = Toast()

    private static let memoryKey = "toastMemory"
    private static let legacyKey = "toastedApps"

    private let state = ToastState()
    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?
    private var hovering = false
    private var onCustomize: () -> Void = {}
    /// Bumped by each show, so a fade-out that finishes late can't hide a newer toast.
    private var generation = 0

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the toast for an app it hasn't explained yet, or whose ready-made
    /// edges changed since. Your own changes never bring it back.
    func showIfNew(id: String, app: String, rows: [EdgeGuideRow], fingerprint: String, onCustomize: @escaping () -> Void) {
        var memory = loadMemory()
        let show = memory.shouldShow(id, fingerprint: fingerprint)
        UserDefaults.standard.set(memory.shown, forKey: Self.memoryKey)
        if show { self.show(app: app, rows: rows, onCustomize: onCustomize) }
    }

    /// Shows it whether or not it was seen, as the menu's "What the Edges Do" does.
    func show(app: String, rows: [EdgeGuideRow], onCustomize: @escaping () -> Void) {
        guard !rows.isEmpty else { return }
        self.onCustomize = onCustomize
        generation += 1
        state.app = app
        state.rows = rows
        state.active = nil
        state.tried = []

        let panel = self.panel ?? makePanel(size: NSSize(width: 484, height: 260), clickable: true)
        if self.panel == nil {
            panel.contentView = NSHostingView(rootView: ToastView(
                state: state,
                onCustomize: { [weak self] in
                    self?.hide()
                    self?.onCustomize()
                },
                onClose: { [weak self] in self?.hide() },
                onHover: { [weak self] inside in self?.hover(inside) }))
            self.panel = panel
        }
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            panel.setContentSize(host.fittingSize)
        }
        let size = panel.frame.size
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.maxY - size.height - 8))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide(after: 12)
    }

    /// A gesture did something. Ticks the zone off and keeps the toast up while you play.
    func zoneUsed(_ zone: ZoneID) {
        guard isVisible, state.rows.contains(where: { $0.zone == zone }) else { return }
        state.active = zone
        state.tried.insert(zone)
        scheduleHide(after: state.allTried ? 3 : 8)
    }

    /// A finger rests on a zone. True when the toast took it, so the cheat sheet stays away.
    func zoneRested(_ zone: ZoneID) -> Bool {
        guard isVisible else { return false }
        if state.rows.contains(where: { $0.zone == zone }) { state.active = zone }
        scheduleHide(after: 8)
        return true
    }

    /// Forgets every app, so each one explains itself again.
    func forgetAll() {
        UserDefaults.standard.removeObject(forKey: Self.memoryKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }

    private func loadMemory() -> ToastMemory {
        var memory = ToastMemory(shown: UserDefaults.standard.dictionary(forKey: Self.memoryKey) as? [String: String] ?? [:])
        if let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyKey) {
            memory.adopt(legacy: legacy)
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        }
        return memory
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { hideTask?.cancel() } else { scheduleHide(after: 4) }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        guard !hovering else { return }
        let task = DispatchWorkItem { [weak self] in self?.hide() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func hide() {
        hideTask?.cancel()
        hovering = false
        guard let panel, panel.isVisible else { return }
        let shown = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.generation == shown else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }
}

// MARK: Cheat sheet

struct CheatSheetView: View {
    let app: String
    let current: ZoneID
    let bindings: [ZoneID: ResolvedBinding]

    private static let order: [ZoneID] = [.rightEdge, .leftEdge, .bottomEdge, .topEdge, .topLeft, .topRight, .bottomLeft, .bottomRight]

    private var rows: [(ZoneID, String, Layer)] {
        Self.order.compactMap { zone in
            guard let resolved = bindings[zone], resolved.binding.isActive else { return nil }
            return (zone, resolved.binding.label, resolved.layer)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(app).font(.system(size: 13, weight: .semibold)).padding(.bottom, 2)
            ForEach(rows, id: \.0) { zone, label, _ in
                HStack {
                    Text(zone.title).foregroundStyle(zone == current ? Color.primary : Color.secondary)
                    Spacer(minLength: 16)
                    Text(label).fontWeight(zone == current ? .semibold : .regular).lineLimit(1)
                }
                .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
        .padding(8)
    }
}

/// Shown while a finger rests on an edge, so the mapping is one touch away.
@MainActor
final class CheatSheet {
    static let shared = CheatSheet()

    private let panel = makePanel(size: NSSize(width: 316, height: 280), clickable: false)

    func show(app: String, current: ZoneID, bindings: [ZoneID: ResolvedBinding]) {
        let host = NSHostingView(rootView: CheatSheetView(app: app, current: current, bindings: bindings))
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 96))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
