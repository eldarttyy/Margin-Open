import AppKit
import MarginCore
import SwiftUI

private enum Pane: Hashable {
    case setup
    case everywhere
    case app(String)
    case general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: ConfigStore
    @StateObject private var selected = Selected<Pane?>(.everywhere)
    @StateObject private var installed = Selected<[InstalledApp]>([])
    @StateObject private var query = Selected("")

    init(model: AppModel) {
        self.model = model
        store = model.store
    }

    private func profile(for bundleID: String) -> Profile? {
        store.config.apps.first { $0.bundleIDs.contains(bundleID) }
    }

    /// Every app on this Mac, plus any added from an unusual place.
    private var allApps: [InstalledApp] {
        let known = Set(installed.value.map(\.id))
        let extras = store.config.apps.compactMap { profile -> InstalledApp? in
            guard let id = profile.bundleIDs.first, !known.contains(id),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return InstalledApp(id: id, name: profile.name, url: url)
        }
        let words = query.value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return (installed.value + extras)
            .filter { app in words.allSatisfy { app.name.lowercased().contains($0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var sites: [SitePack] {
        let words = query.value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return Sites.all
            .filter { site in words.allSatisfy { site.name.lowercased().contains($0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var isSearching: Bool { !query.value.trimmingCharacters(in: .whitespaces).isEmpty }

    private func isAdded(_ app: InstalledApp) -> Bool { profile(for: app.id) != nil }

    /// An added app has no bindings yet, so its edges stay as they were until
    /// a feature is put on one.
    private func add(_ app: InstalledApp) {
        if !isAdded(app) { store.config.apps.append(Profile(name: app.name, bundleIDs: [app.id])) }
        query.value = ""
        selected.value = .app(app.id)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search apps to add", text: $query.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if isSearching, let first = allApps.first { add(first) } }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                List(selection: $selected.value) {
                    Section("Everywhere") {
                        Label("Setup", systemImage: "checklist").tag(Pane.setup)
                        Label(store.config.base.name, systemImage: "rectangle.on.rectangle").tag(Pane.everywhere)
                        Label("General", systemImage: "gearshape").tag(Pane.general)
                    }
                    let apps = allApps
                    let added = apps.filter(isAdded)
                    if !added.isEmpty {
                        Section("Your Apps") {
                            ForEach(added) { AppRow(app: $0).tag(Pane.app($0.id)) }
                        }
                    }
                    let others = apps.filter { !isAdded($0) }
                    let readyMade = others.filter { AppConnection.of(bundleID: $0.id) != nil }
                    if !readyMade.isEmpty {
                        Section("Ready-Made") {
                            ForEach(readyMade) { app in
                                AppRow(app: app, onAdd: isSearching ? { add(app) } : nil).tag(Pane.app(app.id))
                            }
                        }
                    }
                    if !sites.isEmpty {
                        Section("Websites") {
                            ForEach(sites, id: \.id) { site in
                                Label(site.name, systemImage: "globe").lineLimit(1).tag(Pane.app(Sites.profileID(site.id)))
                            }
                        }
                    }
                    if isSearching {
                        let plain = others.filter { AppConnection.of(bundleID: $0.id) == nil }
                        if !plain.isEmpty {
                            Section("Add an App") {
                                ForEach(plain) { app in
                                    AppRow(app: app, onAdd: { add(app) }).tag(Pane.app(app.id))
                                }
                            }
                        }
                        if apps.isEmpty && sites.isEmpty {
                            Text("No match. Try Other App…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Other App…") { chooseApp() }.padding(10)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            switch selected.value {
            case .setup:
                SetupPane(model: model, apps: allApps, sites: Sites.all) { selected.value = .app($0) }
            case .general:
                GeneralPane(model: model)
            case .everywhere:
                pane($store.config.base, isBase: true, id: "everywhere")
            case .app(let id):
                if let site = Sites.pack(profileID: id) {
                    pane(profileBinding(id: id, name: site.name), isBase: false, id: id)
                } else if let app = allApps.first(where: { $0.id == id }) ?? installed.value.first(where: { $0.id == id }) {
                    pane(profileBinding(id: app.id, name: app.name), isBase: false, id: id)
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
            case nil:
                Text("Choose an app").foregroundStyle(.secondary)
            }
        }
        .onReceive(model.$requestedApp) { id in
            if let id { selected.value = .app(id) }
        }
        .task {
            installed.value = await Task.detached { InstalledApps.scan() }.value
        }
        .onAppear {
            startLiveTouches()
            if model.isFirstRun || !model.accessibilityGranted { selected.value = .setup }
        }
        .onDisappear { model.controller.setTouchObserver(nil) }
    }

    private func pane(_ profile: Binding<Profile>, isBase: Bool, id: String) -> some View {
        ProfilePane(
            profile: profile,
            isBase: isBase,
            config: store.config,
            model: model,
            onDelete: { store.config.apps.removeAll { $0.bundleIDs.contains(id) } })
            .id(id)
    }

    /// An app only joins the config once something is changed for it, so
    /// looking through apps leaves nothing behind.
    private func profileBinding(id: String, name: String) -> Binding<Profile> {
        Binding(
            get: { profile(for: id) ?? Profile(name: name, bundleIDs: [id]) },
            set: { new in
                if let index = store.config.apps.firstIndex(where: { $0.bundleIDs.contains(id) }) {
                    store.config.apps[index] = new
                } else {
                    store.config.apps.append(new)
                }
            })
    }

    private func startLiveTouches() {
        let live = model.liveTouches
        model.controller.setTouchObserver { live.post($0) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let app = InstalledApp(id: id, name: url.deletingPathExtension().lastPathComponent, url: url)
        if !installed.value.contains(where: { $0.id == id }) { installed.value.append(app) }
        add(app)
    }
}

/// An app in the sidebar, with its real icon.
private struct AppRow: View {
    let app: InstalledApp
    var onAdd: (() -> Void)?

    var body: some View {
        HStack {
            Label {
                Text(app.name).lineLimit(1)
            } icon: {
                Image(nsImage: AppIcons.image(for: app.url)).resizable().frame(width: 18, height: 18)
            }
            if let onAdd {
                Spacer()
                Button("Add", action: onAdd).controlSize(.small)
            }
        }
    }
}
