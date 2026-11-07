import AppKit
import MarginCore
import SwiftUI

/// The state behind the menu bar panel. Readings refresh only while it's open.
@MainActor
final class PanelState: ObservableObject {
    enum Page { case glance, settings }

    @Published var page = Page.glance
    @Published var brightness: Double?
    @Published var volume: Double?

    private var timer: Timer?

    func opened() {
        page = .glance
        read()
        NowPlaying.shared.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    func closed() {
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        brightness = Display.brightness()
        volume = Audio.volume(input: false)
    }
}

/// Margin's mark: a trackpad with its active edge lit.
struct LogoMark: View {
    var size: CGFloat = 26

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.primary.opacity(0.15)))
            Capsule()
                .fill(Color.accentColor)
                .frame(width: size * 0.14, height: size * 0.62)
                .padding(.trailing, size * 0.16)
        }
        .frame(width: size, height: size)
    }
}

struct PanelHost: View {
    let model: AppModel
    @StateObject private var state = PanelState()

    var body: some View {
        PanelView(model: model, state: state)
            .frame(width: PanelView.size.width)
            .onAppear { state.opened() }
            .onDisappear { state.closed() }
    }
}

struct PanelView: View {
    static let size = NSSize(width: 340, height: 672)
    static let glanceHeight: CGFloat = 640

    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    @ObservedObject private var store: ConfigStore
    @ObservedObject private var song = NowPlaying.shared

    init(model: AppModel, state: PanelState) {
        self.model = model
        self.state = state
        store = model.store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.page == .glance { glance } else { settings }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: At a glance

    private var statusText: (String, Color) {
        if model.deviceCount <= 0 && !model.isPreview { return ("No trackpad", .orange) }
        return store.config.enabled ? ("Ready", .green) : ("Paused", .secondary)
    }

    @ViewBuilder private var glance: some View {
        HStack(spacing: 10) {
            LogoMark()
            Text("Margin").font(.headline)
            Spacer()
            Circle().fill(statusText.1).frame(width: 7, height: 7)
            Text(statusText.0).font(.caption).foregroundStyle(.secondary)
        }


        if let update = model.updates.available {
            Button { NSWorkspace.shared.open(update.url) } label: {
                Label("Version \(update.version) is available", systemImage: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
        }

        readouts
        nowPlaying

        if !model.accessibilityGranted && !model.isPreview {
            Button { model.requestAccessibility() } label: {
                Label("Grant Accessibility Access", systemImage: "lock.open").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }

        VStack(spacing: 12) {
            PanelRow(symbol: "hand.tap.fill", title: "Haptic Feedback", detail: "Ticks as you slide", prominent: true) {
                Picker("", selection: $store.config.haptics) {
                    ForEach(HapticLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if model.plan == .pro {
                toggleRow("speaker.slash.fill", "Quick Mute", "Hold the top-right corner", $store.config.quickMute)
            }
            toggleRow("forward.fill", "Media Strip", "Top edge, in Finder and music apps", $store.config.mediaStrip)
            if model.plan == .pro {
                toggleRow("playpause.fill", "Tap to Play or Pause", "Tap the top-right corner", $store.config.tapToPlay)
            }
        }

        Divider()

        sliderRow("gauge.with.needle", "Sensitivity", String(format: "%.1f×", store.config.sensitivity), $store.config.sensitivity, 0.5...4)
        sliderRow("arrow.left.and.right", "Edge Width", "\(Int((store.config.tuning.edgeWidth * 100).rounded()))%", $store.config.tuning.edgeWidth, 0.03...0.15)

        Divider()

        Button { model.customizeCurrentApp() } label: {
            Label(model.customizeTitle, systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
        }
        .controlSize(.large)

        HStack {
            Button { state.page = .settings } label: { Label("Preferences", systemImage: "gearshape") }
            Spacer()
            moreMenu
            quitButton
        }
        .buttonStyle(.plain)
    }

    private var readouts: some View {
        HStack(spacing: 0) {
            Readout(symbol: "sun.max.fill", tint: .orange, title: "BRIGHTNESS", value: state.brightness, alignment: .leading)
            Spacer(minLength: 10)
            Readout(symbol: "speaker.wave.2.fill", tint: .accentColor, title: "VOLUME", value: state.volume, alignment: .trailing)
        }
        .padding(12)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var nowPlaying: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(song.current == nil ? Color.secondary : Color.pink, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.current?.title ?? "Nothing playing").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(song.current?.artist ?? "Music and Spotify appear here").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 12) {
                mediaButton("backward.fill", "Previous song") { Input.post(.previous) }
                mediaButton(song.current?.isPlaying == true ? "pause.fill" : "play.fill", "Play or pause") { Input.post(.play) }
                mediaButton("forward.fill", "Next song") { Input.post(.next) }
            }
        }
    }

    private func mediaButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 18, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Set once

    @ViewBuilder private var settings: some View {
        HStack(spacing: 10) {
            LogoMark()
            Text("Preferences").font(.headline)
            Spacer()
        }

        sectionTitle("Edge Gestures")
        toggleRow("arrow.left.arrow.right", "Swap Sides", store.config.swapSides ? "Left: Volume · Right: Brightness" : "Left: Brightness · Right: Volume", $store.config.swapSides, prominent: false)
        toggleRow("rectangle.bottomhalf.filled", "Bottom Quarter Only", "Sides respond in the lower 25% only", $store.config.tuning.lowerQuarterOnly, prominent: false)
        toggleRow("option", "Require Fn or ⌥", "Only slide while holding a modifier", $store.config.requireModifier, prominent: false)

        Divider()
        sectionTitle("While Sliding")
        toggleRow("cursorarrow", "Freeze Cursor", "Pointer stays put while sliding", $store.config.holdCursor)
        toggleRow("dial.low.fill", "Fine Control", "Hold ⇧⌥ for quarter steps", $store.config.fineControl)

        Divider()
        sectionTitle("General")
        toggleRow("music.note", "Song in Menu Bar", "Show what's playing beside the icon", $store.config.songInMenuBar)
        PanelRow(symbol: "circle.lefthalf.filled", title: "Appearance", detail: nil, prominent: false) {
            Picker("", selection: $store.config.appearance) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
        }
        toggleRow("power", "Open at Login", nil, Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))

        Spacer(minLength: 0)
        Divider()

        HStack {
            Button { state.page = .glance } label: { Label("Back", systemImage: "chevron.left") }
            Button("All Apps…") { model.showSettings() }
            Spacer()
            moreMenu
            quitButton
        }
        .buttonStyle(.plain)
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func toggleRow(_ symbol: String, _ title: String, _ detail: String?, _ value: Binding<Bool>, prominent: Bool? = nil) -> some View {
        PanelRow(symbol: symbol, title: title, detail: detail, prominent: prominent ?? value.wrappedValue) {
            Toggle("", isOn: value).labelsHidden().toggleStyle(PillToggle())
        }
    }

    private func sliderRow(_ symbol: String, _ title: String, _ value: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range).controlSize(.small).labelsHidden()
        }
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Enabled", isOn: $store.config.enabled)
            Button("All Apps…") { model.showSettings() }
            Button("Reload Config File") { store.reload() }
            Button("Restart Touch Input") { model.restartInput() }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    private var quitButton: some View {
        Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
            .help("Quit Margin")
            .accessibilityLabel("Quit Margin")
    }
}

/// Always accent-coloured when on, in or out of a key window, matching the rows beside it.
private struct PillToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.14))
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
            }
            .frame(width: 34, height: 20)
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(configuration.isOn ? "On" : "Off")
    }
}

private struct PanelRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    let prominent: Bool
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(prominent ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            accessory()
        }
    }
}

private struct Readout: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: Double?
    let alignment: HorizontalAlignment

    private var percent: String { value.map { "\(Int(($0 * 100).rounded()))" } ?? "–" }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(tint).frame(height: geometry.size.height * (value ?? 0))
            }
        }
        .frame(width: 4, height: 58)
    }

    var body: some View {
        HStack(spacing: 10) {
            if alignment == .leading { bar }
            VStack(alignment: alignment, spacing: 2) {
                HStack(spacing: 4) {
                    if alignment == .leading { Image(systemName: symbol).foregroundStyle(tint) }
                    Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    if alignment == .trailing { Image(systemName: symbol).foregroundStyle(tint) }
                }
                .font(.system(size: 10))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(percent).font(.system(size: 30, weight: .light)).monospacedDigit()
                    Text("%").font(.system(size: 13))
                }
            }
            if alignment == .trailing { bar }
        }
    }
}
