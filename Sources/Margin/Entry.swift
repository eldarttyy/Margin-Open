import AppKit
import MarginCore
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
#if MARGIN_DEV
        // Test tools only exist in a developer's own copy. In a public build they
        // would let any program borrow the Accessibility permission Margin holds.
        if ProDiagnose.run(arguments) { return }
#endif
        if arguments.contains("--diagnose") {
            Diagnose.run()
        } else if let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 1 {
            Snapshot.run(directory: arguments[index + 1])
        } else {
            MarginApp.main()
        }
    }
}

struct MarginApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelHost(model: delegate.model)
        } label: {
            MenuLabel(store: delegate.model.store, song: NowPlaying.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

/// App-wide state shared by the menu and the settings window.
@MainActor
final class AppModel: ObservableObject {
    let store: ConfigStore
    let controller: Controller
    let liveTouches = LiveTouches()
    let updates = UpdateChecker()
    let learn = LearnMode()

    @Published private(set) var context = AppContext()
    @Published var capsUnavailable = false
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var deviceCount: Int32 = 0

    private let sites = SiteWatcher()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var settingsWindow: NSWindow?
    private var settingsObserver: NSObjectProtocol?
    private var terminateSignal: DispatchSourceSignal?

    /// True for snapshots, where no hardware or permissions are in play.
    let isPreview: Bool

    init(persist: Bool = true) {
        isPreview = !persist
        store = ConfigStore(persist: persist)
        controller = Controller(config: store.config)
        store.onChange = { [weak self] config in
            guard let self else { return }
            controller.update(config: running, context: context)
            CursorGuard.shared.setActive(running.enabled)
            applyAppearance(config.appearance)
            applyCapsLayer(running.capsLayer)
        }
    }

    /// The config everything that acts on touches reads.
    var running: MarginConfig { store.config }

    /// What's driving the edges right now, for the panel.
    var activeProfileName: String {
        let config = running
        if let site = context.site.flatMap(Sites.pack(id:)) { return site.name }
        if let name = config.profile(forBundleID: context.bundleID)?.name { return name }
        guard config.smartEdges else { return "System controls" }
        if let pack = Packs.pack(forBundleID: context.bundleID) {
            let mode = context.mode.map { " · \(Packs.modeTitle($0))" } ?? ""
            return pack.name + mode
        }
        return context.bundleID.map(Layers.systemApps.contains) ?? true ? "System controls" : (context.name ?? "Universal")
    }

    /// Where the Blender connection stands. Margin keeps it working by itself.
    @Published private(set) var blenderLink = BlenderLink.closed
    private var connectorSynced = false

    /// Installs or updates the Blender connector, off the main thread.
    func syncBlender() {
        connectorSynced = true
        Task.detached(priority: .utility) { BlenderSetup.sync() }
    }

    func refreshBlenderLink() {
        if !connectorSynced { syncBlender() }
        let link = BlenderSetup.link(connected: PluginBridge.shared.isConnected)
        if link != blenderLink {
            blenderLink = link
#if MARGIN_DEV
            FileHandle.standardError.write(Data("LINK \(link)\n".utf8))
#endif
        }
    }

    func setBlenderConnector(on: Bool) {
        if on {
            BlenderSetup.isEnabled = true
            syncBlender()
        } else {
            BlenderSetup.remove()
        }
        refreshBlenderLink()
    }

    /// Starts unset so the first call also clears a remap a crash left behind.
    private var capsWanted: Bool?

    private func applyCapsLayer(_ enabled: Bool) {
        guard enabled != capsWanted else { return }
        capsWanted = enabled
        CapsLayer.queue.async { [weak self] in
            let available = enabled ? CapsLayer.enable() : { CapsLayer.disable(); return true }()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.capsWanted == enabled { self?.capsUnavailable = !available }
                }
            }
        }
    }

    func startLearning() { learn.start(model: self) }

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// True on the very first launch, so Settings opens on Setup.
    private(set) var isFirstRun = false

    func start() {
        // Two copies would fight over the trackpad and the plugin port.
        if !isPreview, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0 != .current }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        applyAppearance(store.config.appearance)
        // `kill` and a shutdown from a script skip the normal quit otherwise.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler { NSApp.terminate(nil) }
        terminate.resume()
        terminateSignal = terminate
        applyCapsLayer(running.capsLayer)
        NowPlaying.shared.start()
        updates.onChange = { [weak self] in self?.objectWillChange.send() }
        updates.start()
        PluginBridge.shared.onModeChange = { [weak self] mode in
            MainActor.assumeIsolated { self?.pluginModeChanged(mode) }
        }
        PluginBridge.shared.start()
        sites.onChange = { [weak self] site in
            MainActor.assumeIsolated { self?.siteChanged(site) }
        }
        // A music app only lists the Margin controller if it exists when the app looks.
        _ = MIDIOut.shared
        refreshBlenderLink()
        controller.onRested = { [weak self] zone, context in
            MainActor.assumeIsolated {
                guard let self else { return }
                // While the toast is up it shows the same thing, so it lights up instead.
                if Toast.shared.zoneRested(zone) { return }
                CheatSheet.shared.show(app: self.activeProfileName, current: zone, bindings: self.running.resolve(context))
            }
        }
        controller.onRestEnded = { MainActor.assumeIsolated { CheatSheet.shared.hide() } }
        controller.onZoneUsed = { zone in MainActor.assumeIsolated { Toast.shared.zoneUsed(zone) } }
        let learn = learn
        controller.learnWantsTouch = { learn.wantsTouch }
        controller.onLearnTouch = { zone in MainActor.assumeIsolated { learn.touched(zone) } }
        controller.start()
        deviceCount = controller.deviceCount
        CursorGuard.shared.setActive(running.enabled)
        CursorGuard.shared.installTap()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostChanged(app) }
        })
        // Blender makes a new folder for each version, so check as it starts.
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Packs.blender.bundleIDs[0] else { return }
            MainActor.assumeIsolated { self?.syncBlender() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartInput() }
        })
        frontmostChanged(NSWorkspace.shared.frontmostApplication)

        // No notification exists for this permission, so it's polled. It can be
        // taken away as well as granted, so this keeps going once it's on.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        permissionTimer?.tolerance = 1

        // Asks once per launch until granted. Nearly everything beyond sliders needs it.
        if !accessibilityGranted { requestAccessibility() }

#if MARGIN_DEV
        // Opens Settings on one app, for checking the real window from a script.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--show"), arguments.count > index + 1 {
            customize(bundleID: arguments[index + 1])
        }
        if arguments.contains("--setup") {
            isFirstRun = true
            showSettings()
        }
#endif

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            isFirstRun = true
            showSettings()
        }
    }

    private func frontmostChanged(_ app: NSRunningApplication?) {
        // Opening Margin's own windows shouldn't change what the edges do.
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let lsCategory = app?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["LSApplicationCategoryType"] as? String }
        // The plugin only speaks when its mode changes, so this keeps what it last said.
        let mode = hasModes(app?.bundleIdentifier) ? PluginBridge.shared.currentMode : nil
        context = AppContext(bundleID: app?.bundleIdentifier, name: app?.localizedName, category: AppCategory(lsCategory: lsCategory), mode: mode)
        controller.update(config: running, context: context)
        controller.setFrontmost(pid: app?.processIdentifier ?? 0)
        let isBrowser = app?.bundleIdentifier.map(Sites.browsers.contains) ?? false
        sites.watch(pid: running.smartEdges && isBrowser ? app?.processIdentifier : nil, bundleID: app?.bundleIdentifier)

        guard running.smartEdges, let bundleID = context.bundleID, let name = context.name,
              !Layers.systemApps.contains(bundleID)
        else { return }
        scheduleToast(id: bundleID, app: name)
    }

    private var pendingToast: DispatchWorkItem?

    /// Explains a new app's edges once it has settled in front. Flicking
    /// through apps with Cmd-Tab shouldn't leave a trail of toasts.
    private func scheduleToast(id: String, app: String) {
        pendingToast?.cancel()
        guard running.explainNewApps else { return }
        let expected = context
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.context == expected else { return }
            Toast.shared.showIfNew(id: id, app: app, rows: self.running.guide(for: expected),
                                   fingerprint: ToastMemory.fingerprint(for: expected)) { [weak self] in
                self?.customize(bundleID: id)
            }
        }
        pendingToast = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: task)
    }

    /// Blender keeps reporting from behind other apps, so only its own pack listens.
    private func hasModes(_ bundleID: String?) -> Bool {
        Packs.pack(forBundleID: bundleID)?.modes.isEmpty == false
    }

    private func pluginModeChanged(_ mode: String?) {
        guard hasModes(context.bundleID) else { return }
        context.mode = mode
        controller.update(config: running, context: context)
    }

    private func siteChanged(_ site: String?) {
        // A reading from a browser that has since left the front arrives late.
        guard site != context.site, context.bundleID.map(Sites.browsers.contains) == true else { return }
        context.site = site
        controller.update(config: running, context: context)
        if let site, let pack = Sites.pack(id: site) {
            scheduleToast(id: Sites.profileID(site), app: pack.name)
        }
    }

    func restartInput() {
        controller.restart()
        deviceCount = controller.deviceCount
    }

    private func refreshPermission() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted {
            CursorGuard.shared.installTap()
        } else {
            CursorGuard.shared.removeTap()
        }
        refreshBlenderLink()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The app Settings should show next.
    @Published var requestedApp: String?

    /// Opens Settings on an app.
    func customize(bundleID: String) {
        requestedApp = bundleID
        showSettings()
    }

    /// The app the edges are working in, for the panel.
    func customizeCurrentApp() {
        if let bundleID = context.bundleID {
            customize(bundleID: bundleID)
        } else {
            showSettings()
        }
    }

    var customizeTitle: String { "Customize \(context.name ?? "Apps")…" }

    /// Brings back the first-launch toast for the app in front, for anyone who missed it.
    func showEdgeGuide() {
        Toast.shared.show(app: context.name ?? "This app", rows: running.guide(for: context)) { [weak self] in
            self?.customizeCurrentApp()
        }
    }

    var edgeGuideTitle: String { "What the Edges Do in \(context.name ?? "This App")" }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.title = "Margin"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 860, height: 620)
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.center()
            settingsWindow = window
            // A closed window would otherwise keep its whole view tree in memory,
            // app lists and all, for as long as Margin runs.
            settingsObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.releaseSettings() } }
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func releaseSettings() {
        // Reopened in the moment since it closed.
        guard settingsWindow?.isVisible != true else { return }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        settingsWindow?.contentView = nil
        settingsWindow = nil
        requestedApp = nil
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Opening Margin again from Finder or Spotlight shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.store.save()
        model.controller.stop()
        CapsLayer.queue.sync { CapsLayer.disable() }
    }
}

/// The menu bar item: the mark, plus the current song while one is playing.
private struct MenuLabel: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var song: NowPlaying

    private var title: String? {
        guard store.config.songInMenuBar, let track = song.current, track.isPlaying else { return nil }
        return track.title.count > 28 ? track.title.prefix(27) + "…" : track.title
    }

    var body: some View {
        Image(systemName: store.config.enabled ? "hand.point.up.left" : "hand.raised.slash")
        if let title { Text(title) }
    }
}
