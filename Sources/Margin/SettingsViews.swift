import AppKit
import MarginCore
import os
import SwiftUI
import UniformTypeIdentifiers

/// Latest touches for the map. Updated from the multitouch thread, drawn at display pace.
@MainActor
final class LiveTouches: ObservableObject {
    @Published var touches: [TouchSample] = []
    private let waiting = OSAllocatedUnfairLock<[TouchSample]?>(initialState: nil)

    /// From the touch thread. Keeps only the newest frame, so a slow redraw
    /// can't build a backlog that freezes the window.
    nonisolated func post(_ samples: [TouchSample]) {
        let idle = waiting.withLock { state -> Bool in
            defer { state = samples }
            return state == nil
        }
        guard idle else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                touches = waiting.withLock { state in
                    defer { state = nil }
                    return state ?? []
                }
            }
        }
    }
}

/// View-local selection. Uses `@StateObject` rather than `@State` because the
/// `@State` macro's plugin ships with Xcode, not the Command Line Tools.
final class Selected<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// One set of edges, used everywhere.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: ConfigStore
    @StateObject private var general = Selected(false)

    init(model: AppModel) {
        self.model = model
        store = model.store
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $general.value) {
                Text("Edges").tag(false)
                Text("General").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 12)
            if general.value {
                GeneralPane(model: model)
            } else {
                ProfilePane(profile: $store.config.base, isBase: true, config: store.config, model: model, onUpgrade: {}, onDelete: {})
            }
        }
        .onAppear {
            let live = model.liveTouches
            model.controller.setTouchObserver { live.post($0) }
        }
        .onDisappear { model.controller.setTouchObserver(nil) }
    }
}

// MARK: - Trackpad map

/// The pad drawn to scale, with each zone selectable and live touches on top.
struct TrackpadMap: View {
    let tuning: Tuning
    let bindingFor: (ZoneID) -> ZoneBinding?
    @Binding var selection: ZoneID
    @ObservedObject var live: LiveTouches

    private func rect(_ zone: ZoneID, in s: CGSize) -> CGRect {
        let cw = tuning.cornerWidth * s.width, ch = tuning.cornerHeight * s.height
        let ew = tuning.edgeWidth * s.width, eh = tuning.edgeHeight * s.height
        switch zone {
        case .topLeft: return CGRect(x: 0, y: 0, width: cw, height: ch)
        case .topRight: return CGRect(x: s.width - cw, y: 0, width: cw, height: ch)
        case .bottomLeft: return CGRect(x: 0, y: s.height - ch, width: cw, height: ch)
        case .bottomRight: return CGRect(x: s.width - cw, y: s.height - ch, width: cw, height: ch)
        case .leftEdge: return CGRect(x: 0, y: ch, width: ew, height: s.height - 2 * ch)
        case .rightEdge: return CGRect(x: s.width - ew, y: ch, width: ew, height: s.height - 2 * ch)
        case .topEdge: return CGRect(x: cw, y: 0, width: s.width - 2 * cw, height: eh)
        case .bottomEdge: return CGRect(x: cw, y: s.height - eh, width: s.width - 2 * cw, height: eh)
        }
    }

    private func symbol(_ binding: ZoneBinding?) -> String? {
        guard let binding, binding.isActive else { return nil }
        switch binding.mode {
        case .slider:
            switch binding.slider {
            case .volume: return "speaker.wave.2.fill"
            case .micVolume: return "mic.fill"
            case .brightness: return "sun.max.fill"
            case .keyboardBacklight: return "light.max"
            case .scroll: return "arrow.up.and.down"
            case .shell: return "terminal.fill"
            case .plugin: return "puzzlepiece.extension.fill"
            case .midi: return "pianokeys"
            }
        case .semantic: return "wand.and.stars"
        case .stepper: return "arrow.left.arrow.right"
        case .buttons: return "hand.tap.fill"
        case .off: return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.6))
                ForEach(ZoneID.allCases, id: \.self) { zone in
                    zoneButton(zone, frame: rect(zone, in: size))
                }
                ForEach(live.touches, id: \.id) { touch in
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1.5))
                        .shadow(radius: 2)
                        .frame(width: 20, height: 20)
                        .position(x: touch.x * size.width, y: (1 - touch.y) * size.height)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        }
        .aspectRatio(1.62, contentMode: .fit)
    }

    private func zoneButton(_ zone: ZoneID, frame: CGRect) -> some View {
        let selected = selection == zone
        let binding = bindingFor(zone)
        return Button { selection = zone } label: {
            ZStack {
                Rectangle().fill(selected ? Color.accentColor : binding?.isActive == true ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                if let symbol = symbol(binding) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(selected ? .white : .accentColor)
                        .id(selected)
                }
            }
            .overlay(Rectangle().strokeBorder(Color(nsColor: .windowBackgroundColor).opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .help(zone.title)
        .accessibilityLabel(zone.title)
    }
}

// MARK: - Profiles

struct ProfilePane: View {
    @Binding var profile: Profile
    let isBase: Bool
    let config: MarginConfig
    @ObservedObject var model: AppModel
    let onUpgrade: () -> Void
    let onDelete: () -> Void

    @StateObject private var zone = Selected(ZoneID.rightEdge)
    /// Nil means every mode.
    @StateObject private var mode = Selected<String?>(nil)

    private var bundleID: String? { profile.bundleIDs.first }

    private var context: AppContext {
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let category = url.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
        return AppContext(bundleID: bundleID, category: AppCategory(lsCategory: category), mode: mode.value)
    }

    /// What this zone really does here, across all five layers.
    private func effective(_ zone: ZoneID) -> ResolvedBinding? {
        if isBase { return profile[zone].map { ResolvedBinding(binding: $0, layer: .system) } }
        var resolved = config
        if let index = resolved.apps.firstIndex(where: { $0.id == profile.id }) { resolved.apps[index] = profile }
        return resolved.resolve(context)[zone]
    }

    private var modes: [String] {
        []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        TrackpadMap(
                            tuning: config.tuning,
                            bindingFor: { effective($0)?.binding },
                            selection: $zone.value,
                            live: model.liveTouches)
                        Text("Select a zone. Touches appear here live.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 240, maxWidth: 300)

                    ZoneEditor(
                        zone: zone.value, mode: mode.value, profile: $profile, isBase: isBase,
                        effective: effective(zone.value), plan: model.plan,
                        accessibility: model.accessibilityGranted,
                        onGrant: { model.requestAccessibility() },
                        onBridgeFeature: {
                        })
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(24)
        }
    }


    private var subtitle: String {
        if isBase { return "Used in Finder and music apps, and everywhere when Smart Edges is off." }
        return profile.bundleIDs.joined(separator: ", ")
    }

    private var removeTitle: String {
        return "Remove App"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !isBase, config.apps.contains(where: { $0.id == profile.id }) {
                Button(removeTitle, role: .destructive, action: onDelete)
            }
        }
    }
}

/// Everything a zone can do in this app, best picks first and the long tail
/// folded away. One Add button per row: the choice of tap, hold or direction
/// is made once, above the list.
private struct FeatureLibrary: View {
    let zone: ZoneID
    let bundleID: String?
    let appName: String
    let isBase: Bool
    let plan: Plan
    let accessibility: Bool
    let onGrant: () -> Void
    let onPick: (Feature, FeatureSlot) -> Void

    @StateObject private var query = Selected("")
    @StateObject private var notRunning = Selected(false)
    @StateObject private var needsAccess = Selected(false)
    @StateObject private var menus = Selected<[Feature]>([])
    @StateObject private var menuNote = Selected<String?>(nil)
    @StateObject private var slot = Selected<FeatureSlot?>(nil)
    @StateObject private var hidden = Selected<Set<String>>([])

    private var appFeatures: [Feature] { FeatureCatalog.appFeatures(forBundleID: bundleID) }

    private var shelves: FeatureShelves {
        FeatureCatalog.shelves(app: appFeatures, menus: menus.value, system: FeatureCatalog.system, zone: zone, hidden: hidden.value,
            edgePicks: FeatureCatalog.edgePicks(forBundleID: bundleID))
    }

    private var results: [Feature] {
        FeatureCatalog.search(query.value, in: appFeatures + menus.value + FeatureCatalog.system)
            .filter { !$0.slots(on: zone).isEmpty && !hidden.value.contains($0.id) }
    }

    private var slots: [FeatureSlot] { zone.isCorner ? [.tap, .doubleTap, .hold] : [.forward, .backward] }

    /// Where a single command goes when added.
    private var activeSlot: FeatureSlot {
        if let chosen = slot.value, slots.contains(chosen) { return chosen }
        return slots[0]
    }

    private var isSearching: Bool { !query.value.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search features", text: $query.value)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Text(zone.isCorner ? "Commands run on" : "Commands run when you slide").font(.caption).foregroundStyle(.secondary)
                Picker("Commands run on", selection: Binding(get: { activeSlot }, set: { slot.value = $0 })) {
                    ForEach(slots, id: \.self) { Text($0.title(on: zone)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if isSearching {
                        ForEach(results) { row($0) }
                        if results.isEmpty {
                            Text("Nothing matches. Advanced settings below take any key combination, menu command or script.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                        }
                    } else {
                        let shelves = shelves
                        section("Best for this spot", shelves.best)
                        section("More for \(appName)", shelves.more)
                        section("Works in any app", shelves.everywhere, folded: !isBase)
                        section("All \(appName) menu commands", shelves.menus, folded: true)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 310)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if let note = menuNote.value {
                HStack {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    if notRunning.value { Button("Open \(appName)") { openApp() }.controlSize(.small) }
                    if needsAccess.value { Button("Turn On Access") { onGrant() }.controlSize(.small) }
                }
            }
        }
        .task(id: "\(bundleID ?? "")\(accessibility)") { await loadMenus() }
        .task { hidden.value = await Task.detached { Hardware.missingFeatures }.value }
    }

    @ViewBuilder private func section(_ title: String, _ features: [Feature], folded: Bool = false) -> some View {
        if !features.isEmpty {
            if folded {
                DisclosureGroup("\(title) (\(features.count))") {
                    ForEach(features) { row($0) }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(features) { row($0) }
            }
        }
    }

    private func isLocked(_ feature: Feature) -> Bool {
        plan == .free && (!feature.isFree || !isBase)
    }

    private func row(_ feature: Feature) -> some View {
        let whole = feature.slots(on: zone).contains(.whole)
        return HStack(spacing: 6) {
            Text(feature.title).font(.body).foregroundStyle(.primary).lineLimit(1)
            if feature.isRisky {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .help("Easy to set off by accident")
            }
            Spacer(minLength: 8)
            if isLocked(feature) {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(whole ? "Uses whole edge" : activeSlot.title(on: zone)).font(.caption).foregroundStyle(.secondary)
                Button("Add") { onPick(feature, whole ? .whole : activeSlot) }.controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func loadMenus() async {
        menus.value = []
        menuNote.value = nil
        notRunning.value = false
        needsAccess.value = false
    }

    private func openApp() {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        notRunning.value = false
        menuNote.value = "Opening \(appName)…"
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Task { await loadMenus() } }
            }
        }
    }
}

private struct ZoneEditor: View {
    let zone: ZoneID
    let mode: String?
    @Binding var profile: Profile
    let isBase: Bool
    let effective: ResolvedBinding?
    let plan: Plan
    let accessibility: Bool
    let onGrant: () -> Void
    let onBridgeFeature: () -> Void

    private var hasOverride: Bool { profile[zone, mode: mode] != nil }

    private var overrides: Binding<Bool> {
        Binding(
            get: { hasOverride },
            set: { profile[zone, mode: mode] = $0 ? (effective?.binding ?? ZoneBinding(mode: zone.isCorner ? .buttons : .off)) : nil })
    }

    private var binding: Binding<ZoneBinding>? {
        if !isBase, !hasOverride { return nil }
        return Binding(get: { profile[zone, mode: mode] ?? ZoneBinding() }, set: { profile[zone, mode: mode] = $0 })
    }

    private func add(_ feature: Feature, _ slot: FeatureSlot) {
        profile[zone, mode: mode] = (profile[zone, mode: mode] ?? ZoneBinding()).adding(feature, slot: slot)
        if feature.usesBridge { onBridgeFeature() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(zone.title).font(.headline)
                HStack {
                    Text("Now: \(summary(effective?.binding))").foregroundStyle(.secondary).lineLimit(1)
                    if !isBase, hasOverride {
                        Button("Reset") { profile[zone, mode: mode] = nil }.controlSize(.small)
                    }
                }
            }
            FeatureLibrary(
                zone: zone, bundleID: profile.bundleIDs.first, appName: profile.name, isBase: isBase, plan: plan,
                accessibility: accessibility, onGrant: onGrant, onPick: add)
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    if !isBase {
                    }
                    if let binding {
                        if zone.isCorner { cornerFields(binding) } else { edgeFields(binding) }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func summary(_ binding: ZoneBinding?) -> String {
        guard let binding, binding.isActive else { return "Off" }
        return binding.label
    }

    private func edgeFields(_ binding: Binding<ZoneBinding>) -> some View {
        Group {
            Picker("Behavior", selection: binding.mode) {
                Text("Off").tag(BindingMode.off)
                Text("Meaning").tag(BindingMode.semantic)
                Text("Slider").tag(BindingMode.slider)
                Text("Stepper").tag(BindingMode.stepper)
            }
            .pickerStyle(.segmented)

            switch binding.wrappedValue.mode {
            case .semantic:
                Picker("Does", selection: binding.semantic) {
                    ForEach(SemanticAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Margin works out how to do this in whichever app is in front.")
                    .font(.caption).foregroundStyle(.secondary)
            case .slider:
                Picker("Controls", selection: binding.slider) {
                    ForEach(SliderTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if binding.wrappedValue.slider == .shell {
                    TextField("Command, with the value in $VALUE", text: binding.command)
                        .font(.system(.body, design: .monospaced))
                }
                if binding.wrappedValue.slider == .midi {
                    Stepper("Controller \(binding.wrappedValue.cc)", value: binding.cc, in: 0...127)
                }
                LabeledContent("Sensitivity") {
                    Slider(value: binding.sensitivity, in: 0.3...4)
                }
                Toggle("Reverse direction", isOn: binding.invert)
            case .stepper:
                ActionField(title: zone.slidesVertically ? "Sliding up" : "Sliding right", action: binding.forward)
                ActionField(title: zone.slidesVertically ? "Sliding down" : "Sliding left", action: binding.backward)
                LabeledContent("Travel per step") {
                    Slider(value: binding.stepSize, in: 0.02...0.4)
                }
            default:
                Text("This edge leaves the cursor alone.").foregroundStyle(.secondary)
            }
        }
    }

    private func cornerFields(_ binding: Binding<ZoneBinding>) -> some View {
        Group {
            ActionField(title: "Tap", action: buttonAction(binding, \.tap))
            ActionField(title: "Double-tap", action: buttonAction(binding, \.doubleTap))
            ActionField(title: "Hold", action: buttonAction(binding, \.hold))
        }
    }

    /// Editing a corner action also puts the zone in buttons mode.
    private func buttonAction(_ binding: Binding<ZoneBinding>, _ path: WritableKeyPath<ZoneBinding, Action>) -> Binding<Action> {
        Binding(
            get: { binding.wrappedValue[keyPath: path] },
            set: {
                binding.wrappedValue[keyPath: path] = $0
                binding.wrappedValue.mode = .buttons
            })
    }
}

private struct ActionField: View {
    let title: String
    @Binding var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $action.kind) {
                ForEach(ActionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let hint = action.kind.valueHint {
                TextField(hint, text: $action.value)
                    .font(.system(.body, design: .monospaced))
                if action.kind == .keyCombo, !action.value.isEmpty, KeyCombo(action.value) == nil {
                    Text("Not a recognized key combination.").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: ConfigStore
    @ObservedObject private var updates: UpdateChecker

    init(model: AppModel) {
        self.model = model
        store = model.store
        updates = model.updates
    }

    var body: some View {
        Form {
            if let warning = store.loadWarning {
                Section { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section("Status") {
                LabeledContent("Trackpad") {
                    Text(model.deviceCount > 0 ? "Connected" : "Not found")
                }
                LabeledContent("Accessibility") {
                    if model.accessibilityGranted {
                        Text("Granted")
                    } else {
                        Button("Grant Access…") { model.requestAccessibility() }
                    }
                }
                if !model.accessibilityGranted {
                    Text("Needed for key shortcuts, media keys and scrolling, and for holding the cursor still. Sliders for volume and brightness work without it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Behavior") {
                Toggle("Enabled", isOn: $store.config.enabled)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                if UpdateChecker.feedURL != nil {
                    Toggle("Check for updates", isOn: $updates.enabled)
                }
                Toggle("Show on-screen readout", isOn: $store.config.hud)
                Picker("Trackpad haptics", selection: $store.config.haptics) {
                    ForEach(HapticLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Hold the cursor during edge gestures", isOn: $store.config.holdCursor)
            }
            Section("Zones") {
                tuningSlider("Edge width", $store.config.tuning.edgeWidth, Tuning.edgeWidthRange, percent: true)
                tuningSlider("Edge height", $store.config.tuning.edgeHeight, Tuning.edgeHeightRange, percent: true)
                tuningSlider("Corner width", $store.config.tuning.cornerWidth, Tuning.cornerWidthRange, percent: true)
                tuningSlider("Corner height", $store.config.tuning.cornerHeight, Tuning.cornerHeightRange, percent: true)
            }
            Section("Timing") {
                tuningSlider("Rest before sliding", $store.config.tuning.dwellMs, Tuning.dwellRange, unit: "ms")
                tuningSlider("Longest tap", $store.config.tuning.tapMaxMs, Tuning.tapMaxRange, unit: "ms")
                tuningSlider("Hold after", $store.config.tuning.holdMs, Tuning.holdRange, unit: "ms")
                tuningSlider("Palm size", $store.config.tuning.palmMajorAxis, Tuning.palmRange, unit: "")
            }
            Section("Config file") {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL]) }
                    Button("Reload") { store.reload() }
                    Spacer()
                    Button("Restore Defaults") {
                        store.config = .standard
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func tuningSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, percent: Bool = false, unit: String = "") -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : "\(Int(value.wrappedValue.rounded()))\(unit.isEmpty ? "" : " " + unit)")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
    }
}

// MARK: - Snapshots

/// `Margin --snapshot <dir>` renders the UI to PNGs without touching any
/// system state, so layouts can be checked without Screen Recording access.
@MainActor
enum Snapshot {
    private static func write<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    nonisolated static func run(directory: String) {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let base = URL(fileURLWithPath: directory)
            let model = AppModel(persist: false)
            NowPlaying.shared.current = Track(title: "Long Way Home", artist: "The Sample Band", isPlaying: true, player: "com.spotify.client")
            let panel = PanelState()
            panel.brightness = 0.56
            panel.volume = 0.51
            let config = model.store.config
            let live = LiveTouches()
            live.touches = [TouchSample(id: 1, x: 0.96, y: 0.55)]
            var profile = config.base
            let binding = Binding(get: { profile }, set: { profile = $0 })
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                write(ProfilePane(profile: binding, isBase: true, config: config, model: model, onUpgrade: {}, onDelete: {}),
                      size: NSSize(width: 680, height: 520), appearance: appearance, to: base.appendingPathComponent("profile-\(name).png"))
                panel.page = .glance
                write(PanelView(model: model, state: panel), size: NSSize(width: PanelView.size.width, height: PanelView.glanceHeight), appearance: appearance, to: base.appendingPathComponent("panel-glance-\(name).png"))
                panel.page = .settings
                write(PanelView(model: model, state: panel), size: PanelView.size, appearance: appearance, to: base.appendingPathComponent("panel-settings-\(name).png"))
            }
        }
    }
}
