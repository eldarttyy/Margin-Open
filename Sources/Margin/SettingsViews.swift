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
    let onDelete: () -> Void

    @StateObject private var zone = Selected(ZoneID.rightEdge)
    /// Nil means every mode.
    @StateObject private var mode = Selected<String?>(nil)

    private var bundleID: String? { profile.bundleIDs.first }

    private var context: AppContext {
        if let site = Sites.pack(profileID: bundleID) { return AppContext(bundleID: "com.google.Chrome", site: site.id) }
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let category = url.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
        return AppContext(bundleID: bundleID, category: AppCategory(lsCategory: category), mode: mode.value)
    }

    /// What this zone really does here, across all five layers.
    private func effective(_ zone: ZoneID) -> ResolvedBinding? {
        if isBase { return profile[zone].map { ResolvedBinding(binding: $0, layer: .system) } }
        return withEdits.resolve(context)[zone]
    }

    /// The saved config with this pane's unsaved profile in place.
    private var withEdits: MarginConfig {
        var resolved = config
        if let index = resolved.apps.firstIndex(where: { $0.id == profile.id }) { resolved.apps[index] = profile }
        else if !isBase { resolved.apps.append(profile) }
        return resolved
    }

    private var modes: [String] {
        (Packs.pack(forBundleID: bundleID)?.modes.keys.sorted() ?? []).filter { $0 != "GRAB" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if isBlender { blenderStatus }
                if !modes.isEmpty {
                    Picker("Edit bindings for", selection: $mode.value) {
                        Text("Every mode").tag(String?.none)
                        ForEach(modes, id: \.self) { Text(Packs.modeTitle($0)).tag(String?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }
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
                        effective: effective(zone.value),
                        accessibility: model.accessibilityGranted,
                        onGrant: { model.requestAccessibility() },
                        onBridgeFeature: {
                            model.syncBlender()
                        })
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if !isBase {
                    EdgeGuideList(rows: withEdits.guide(for: context), selection: $zone.value)
                }
            }
            .padding(24)
        }
    }

    private var isBlender: Bool { bundleID.map(Packs.blender.bundleIDs.contains) ?? false }

    private var blenderStatus: some View {
        let link = model.blenderLink
        return Label(link.title, systemImage: link == .connected ? "checkmark.circle.fill" : "puzzlepiece.extension")
            .foregroundStyle(link == .connected ? Color.green : Color.secondary)
    }

    private var subtitle: String {
        if isBase { return "Used in Finder and music apps, and everywhere when Smart Edges is off." }
        if Sites.pack(profileID: bundleID) != nil { return "Used while this site is in the front tab of your browser." }
        return profile.bundleIDs.joined(separator: ", ")
    }

    private var removeTitle: String {
        if Sites.pack(profileID: bundleID) != nil { return "Reset Site" }
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
    let accessibility: Bool
    let onGrant: () -> Void
    let onPick: (Feature, FeatureSlot) -> Void
    /// For snapshots: a search already typed, and the screen section open.
    var previewQuery = ""
    var previewOpen = false

    @StateObject private var query = Selected("")
    @StateObject private var notRunning = Selected(false)
    @StateObject private var needsAccess = Selected(false)
    @StateObject private var menus = Selected<[Feature]>([])
    /// Buttons, toggles, tabs and sliders in the app's windows.
    @StateObject private var screen = Selected<[Feature]>([])
    @StateObject private var menuNote = Selected<String?>(nil)
    @StateObject private var slot = Selected<FeatureSlot?>(nil)
    @StateObject private var hidden = Selected<Set<String>>([])

    private var appFeatures: [Feature] { FeatureCatalog.appFeatures(forBundleID: bundleID) }

    private var shelves: FeatureShelves {
        FeatureCatalog.shelves(app: appFeatures, menus: menus.value, system: FeatureCatalog.system, zone: zone, hidden: hidden.value,
            edgePicks: FeatureCatalog.edgePicks(forBundleID: bundleID))
    }

    private var results: [Feature] {
        FeatureCatalog.search(query.value, in: appFeatures + menus.value + screen.value + FeatureCatalog.system)
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
                        section("Everything on \(appName)'s screen", screen.value.filter { !$0.slots(on: zone).isEmpty }, folded: !previewOpen)
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
        .task(id: "\(bundleID ?? "")\(accessibility)") {
            if !previewQuery.isEmpty { query.value = previewQuery }
            await loadMenus()
        }
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

    private func row(_ feature: Feature) -> some View {
        let whole = feature.slots(on: zone).contains(.whole)
        return HStack(spacing: 6) {
            Text(feature.title).font(.body).foregroundStyle(.primary).lineLimit(1)
            if feature.isRisky {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .help("Easy to set off by accident")
            }
            Spacer(minLength: 8)
            Text(whole ? "Uses whole edge" : activeSlot.title(on: zone)).font(.caption).foregroundStyle(.secondary)
            Button("Add") { onPick(feature, whole ? .whole : activeSlot) }.controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private func loadMenus() async {
        menus.value = []
        screen.value = []
        menuNote.value = nil
        notRunning.value = false
        needsAccess.value = false
        // Blender draws its own menus, so there's nothing to read. Its catalog
        // covers it, and a website has no menus of its own.
        guard let bundleID, !Packs.blender.bundleIDs.contains(bundleID), Sites.pack(profileID: bundleID) == nil else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            notRunning.value = true
            menuNote.value = "Open \(appName) to add commands from its menus."
            return
        }
        guard accessibility else {
            needsAccess.value = true
            menuNote.value = "Accessibility is off, so \(appName)'s menus can't be listed."
            return
        }
        let pid = app.processIdentifier
        // Runs beside the menu reading, which can take seconds.
        Task { await loadScreen(bundleID: bundleID, pid: pid) }
        // A newly opened app builds its menus a moment after launching.
        for attempt in 0..<6 {
            guard !Task.isCancelled else { return }
            let paths = await Task.detached { SemanticRunner.menuPaths(pid: pid) }.value
            let found = FeatureCatalog.menuFeatures(paths)
            if !found.isEmpty {
                menus.value = found
                return
            }
            if attempt < 5 { try? await Task.sleep(for: .seconds(1)) }
        }
        menuNote.value = "\(appName) doesn't share its menus, so add shortcuts under Advanced."
    }

    /// Reads the app's windows. Electron apps fill theirs in only after being
    /// asked once, so an empty first look gets a second.
    private func loadScreen(bundleID: String, pid: pid_t) async {
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return }
            let controls = await Task.detached { ScreenReader.shared.controls(pid: pid, budget: 3).map(\.control) }.value
            let found = FeatureCatalog.screenFeatures(bundleID: bundleID, controls: controls, isBrowser: Sites.browsers.contains(bundleID))
            if !found.isEmpty || attempt == 2 {
                screen.value = found
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
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
                zone: zone, bundleID: profile.bundleIDs.first, appName: profile.name, isBase: isBase,
                accessibility: accessibility, onGrant: onGrant, onPick: add)
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    if !isBase {
                        Toggle(mode == nil ? "Customize for this app" : "Customize for \(Packs.modeTitle(mode!))", isOn: overrides)
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
                if binding.wrappedValue.slider == .plugin {
                    HStack {
                        TextField("Plugin value, such as brush_size", text: binding.parameter)
                            .font(.system(.body, design: .monospaced))
                        let names = PluginBridge.shared.parameterNames
                        if !names.isEmpty {
                            Menu("Choose") {
                                ForEach(names, id: \.self) { name in
                                    Button(name) {
                                        binding.wrappedValue.parameter = name
                                        binding.wrappedValue.name = ""
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
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
                LabeledContent {
                    Button("Show Again for Every App") { Toast.shared.forgetAll() }
                        .disabled(!store.config.explainNewApps)
                } label: {
                    Toggle("Explain the edges when I open an app for the first time", isOn: $store.config.explainNewApps)
                }
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
    private static func write<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL, wait: TimeInterval = 0.5) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: wait))
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
                write(ProfilePane(profile: binding, isBase: true, config: config, model: model, onDelete: {}),
                      size: NSSize(width: 680, height: 520), appearance: appearance, to: base.appendingPathComponent("profile-\(name).png"))
                var blender = Profile(name: "Blender", bundleIDs: Packs.blender.bundleIDs)
                let blenderBinding = Binding(get: { blender }, set: { blender = $0 })
                write(ProfilePane(profile: blenderBinding, isBase: false, config: config, model: model, onDelete: {}),
                      size: NSSize(width: 760, height: 640), appearance: appearance, to: base.appendingPathComponent("blender-\(name).png"))
                var safari = Profile(name: "Safari", bundleIDs: ["com.apple.Safari"])
                let safariBinding = Binding(get: { safari }, set: { safari = $0 })
                write(ProfilePane(profile: safariBinding, isBase: false, config: config, model: model, onDelete: {}),
                      size: NSSize(width: 760, height: 640), appearance: appearance, to: base.appendingPathComponent("safari-\(name).png"))
                var youtube = Profile(name: "YouTube", bundleIDs: [Sites.profileID("youtube")])
                let youtubeBinding = Binding(get: { youtube }, set: { youtube = $0 })
                write(ProfilePane(profile: youtubeBinding, isBase: false, config: config, model: model, onDelete: {}),
                      size: NSSize(width: 760, height: 640), appearance: appearance, to: base.appendingPathComponent("youtube-\(name).png"))
                // A real app's windows, so this needs it running and Accessibility.
                if let app = ProcessInfo.processInfo.environment["MARGIN_SNAPSHOT_APP"],
                   let name = NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName {
                    for (file, query, open) in [("screen", "", true), ("screen-search", ProcessInfo.processInfo.environment["MARGIN_SNAPSHOT_QUERY"] ?? "", false)] {
                        write(FeatureLibrary(zone: .topRight, bundleID: app, appName: name, isBase: false, accessibility: AXIsProcessTrusted(),
                                             onGrant: {}, onPick: { _, _ in }, previewQuery: query, previewOpen: open),
                              size: NSSize(width: 460, height: 420), appearance: appearance, to: base.appendingPathComponent("\(file)-\(name)-\(appearance == .aqua ? "light" : "dark").png"), wait: 6)
                    }
                }
                for (file, id, app) in [("toast", "com.microsoft.VSCode", "Visual Studio Code"), ("toast-blender", Packs.blender.bundleIDs[0], "Blender")] {
                    let fresh = ToastState()
                    fresh.app = app
                    fresh.rows = config.guide(for: AppContext(bundleID: id, category: .developer))
                    write(ToastView(state: fresh, onCustomize: {}, onClose: {}),
                          size: NSSize(width: 484, height: 290), appearance: appearance, to: base.appendingPathComponent("\(file)-\(name).png"))
                }
                let trying = ToastState()
                trying.app = "Visual Studio Code"
                trying.rows = config.guide(for: AppContext(bundleID: "com.microsoft.VSCode", category: .developer))
                trying.tried = [.rightEdge, .topEdge]
                trying.active = .topEdge
                write(ToastView(state: trying, onCustomize: {}, onClose: {}),
                      size: NSSize(width: 484, height: 290), appearance: appearance, to: base.appendingPathComponent("toast-trying-\(name).png"))
                write(CheatSheetView(app: "Blender · Sculpt", current: .rightEdge, bindings: config.resolve(AppContext(bundleID: Packs.blender.bundleIDs[0], category: .graphics, mode: "SCULPT"))),
                      size: NSSize(width: 316, height: 270), appearance: appearance, to: base.appendingPathComponent("cheat-\(name).png"))
                panel.page = .glance
                write(PanelView(model: model, state: panel), size: NSSize(width: PanelView.size.width, height: PanelView.glanceHeight), appearance: appearance, to: base.appendingPathComponent("panel-glance-\(name).png"))
                panel.page = .settings
                write(PanelView(model: model, state: panel), size: PanelView.size, appearance: appearance, to: base.appendingPathComponent("panel-settings-\(name).png"))
            }
        }
    }
}

/// Every zone's job in this app, in words, so nobody has to click each zone to
/// find out. A row selects its zone in the map above.
private struct EdgeGuideList: View {
    let rows: [EdgeGuideRow]
    @Binding var selection: ZoneID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the edges do here").font(.headline)
            if rows.isEmpty {
                Text("Nothing yet. Select a zone above and add a feature.").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.zone) { index, row in
                    if index > 0 { Divider() }
                    Button { selection = row.zone } label: { line(row) }
                        .buttonStyle(.plain)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func line(_ row: EdgeGuideRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.zone.title).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.what).fontWeight(row.zone == selection ? .semibold : .regular)
                Text(row.how).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(source(row.layer)).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Where the job comes from, in the words Settings uses elsewhere.
    private func source(_ layer: Layer) -> String {
        switch layer {
        case .system: return "Everywhere"
        case .universal, .category: return "Any app"
        case .pack: return "Ready-made"
        case .user: return "Yours"
        }
    }
}
