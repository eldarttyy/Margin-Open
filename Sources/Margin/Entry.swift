import AppKit
import MarginCore
import ServiceManagement
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
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

    @Published private(set) var context = AppContext()
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var deviceCount: Int32 = 0

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
        controller = Controller(config: store.config.limited(to: .free))
        store.onChange = { [weak self] config in
            guard let self else { return }
            controller.update(config: running, context: context)
            CursorGuard.shared.setActive(running.enabled)
            applyAppearance(config.appearance)
        }
    }

    /// The config as the plan allows it. Settings edit `store.config`; everything
    /// that acts on touches reads this, so a Pro setup survives a lapsed plan.
    var running: MarginConfig { store.config.limited(to: plan) }

    var plan: Plan {
        .free
    }


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
        NowPlaying.shared.start()
        updates.onChange = { [weak self] in self?.objectWillChange.send() }
        updates.start()
        controller.start()
        deviceCount = controller.deviceCount
        CursorGuard.shared.setActive(running.enabled)
        CursorGuard.shared.installTap()

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostChanged(app) }
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
        context = AppContext(bundleID: app?.bundleIdentifier, name: app?.localizedName)
        controller.update(config: running, context: context)
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
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func customizeCurrentApp() { showSettings() }

    var customizeTitle: String { "Customize Edges…" }

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
