import AppKit
import os
import SwiftUI

struct HUDReading: Equatable, Sendable {
    var symbol = "speaker.wave.2.fill"
    var title = ""
    var value: Double?
    /// The value as text, such as "42 px". Shown beside the title.
    var detail: String?
}

final class HUDModel: ObservableObject {
    @Published var reading = HUDReading()
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    private var reading: HUDReading { model.reading }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reading.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                if reading.value == nil || reading.detail != nil {
                    HStack {
                        Text(reading.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if let detail = reading.detail {
                            Text(detail).font(.system(size: 14)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if let value = reading.value {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.15))
                            Capsule().fill(.primary).frame(width: max(6, geometry.size.width * value))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(width: 300, height: 58)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .padding(8)
    }
}

/// A floating value readout that replaces the system volume overlay, which
/// macOS doesn't show when volume is set through CoreAudio.
@MainActor
final class HUD {
    static let shared = HUD()

    private let model = HUDModel()
    private let panel: NSPanel
    private var hideAt = 0.0
    private var hideScheduled = false

    /// The newest reading from a slide. Only that one is ever drawn, so a busy
    /// main thread never falls behind the finger.
    private nonisolated static let waiting = OSAllocatedUnfairLock<HUDReading?>(initialState: nil)

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 316, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    /// Shows a reading from any thread, replacing one that hasn't been drawn yet.
    nonisolated static func post(symbol: String, title: String, value: Double?, detail: String? = nil) {
        let reading = HUDReading(symbol: symbol, title: title, value: value, detail: detail)
        let idle = waiting.withLock { current -> Bool in
            defer { current = reading }
            return current == nil
        }
        guard idle else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let next = waiting.withLock { current -> HUDReading? in
                    defer { current = nil }
                    return current
                }
                if let next { shared.show(next, duration: 1.1) }
            }
        }
    }

    func show(symbol: String, title: String, value: Double?, detail: String? = nil, duration: Double = 1.1) {
        show(HUDReading(symbol: symbol, title: title, value: value, detail: detail), duration: duration)
    }

    private func show(_ reading: HUDReading, duration: Double) {
        if reading != model.reading { model.reading = reading }

        if !panel.isVisible, let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2, y: screen.visibleFrame.minY + 96))
        }
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }

        hideAt = ProcessInfo.processInfo.systemUptime + duration
        scheduleHide()
    }

    /// One pending check at a time, however often the readout changes.
    private func scheduleHide() {
        guard !hideScheduled else { return }
        hideScheduled = true
        let wait = max(0, hideAt - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            MainActor.assumeIsolated {
                hideScheduled = false
                if ProcessInfo.processInfo.systemUptime < hideAt {
                    scheduleHide()
                } else {
                    fadeOut()
                }
            }
        }
    }

    private func fadeOut() {
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // A new reading during the fade put it back.
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }
}
