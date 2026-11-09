import AppKit
import MarginCore
import SwiftUI

/// The one page a new person needs: the single permission, then each app they
/// have, with what it needs. Almost always that's nothing.
struct SetupPane: View {
    @ObservedObject var model: AppModel
    let apps: [InstalledApp]
    let sites: [SitePack]
    let onOpen: (String) -> Void

    private var supported: [(app: InstalledApp, connection: AppConnection)] {
        apps.compactMap { app in AppConnection.of(bundleID: app.id).map { (app, $0) } }
    }

    var body: some View {
        Form {
            Section {
                step(1, "Turn on Accessibility", done: model.accessibilityGranted,
                     detail: "Margin uses this to press shortcuts and menu commands in the app you're using. You only do this once.") {
                    Button("Turn On…") { model.requestAccessibility() }
                }
                step(2, "Slide a finger along an edge of your trackpad", done: model.deviceCount > 0,
                     detail: model.deviceCount > 0
                        ? "The right edge changes the volume unless an app has its own controls."
                        : "Margin can't find a trackpad yet. Reconnect it, or restart Margin.") { EmptyView() }
                step(3, "Search for an app in the sidebar and add it", done: false,
                     detail: "Then pick a spot on the trackpad and add a feature. Your changes save by themselves.") { EmptyView() }
            } header: {
                Text("Get started").font(.title2.weight(.semibold)).foregroundStyle(.primary).textCase(nil)
            }
            Section("Ready-made for apps on this Mac") {
                if supported.isEmpty {
                    Text("None of your apps have a ready-made set yet. Every app still works, as below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(supported, id: \.app.id) { item in row(item.app, item.connection) }
            }
            Section("Websites in your browser") {
                Text("Nothing to install. Open one of these sites and the edges change to suit it, in Chrome, Safari and other browsers.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(sites, id: \.id) { site in
                    HStack(spacing: 8) {
                        Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 20, height: 20)
                        Text(site.name)
                        Spacer()
                        Button("Customize") { onOpen(Sites.profileID(site.id)) }.controlSize(.small)
                    }
                }
            }
            Section("Every other app") {
                Text("Search for it in the sidebar and add it. There's nothing to install. Open the app and its menu commands appear as features you can add. Its menus are read while you're choosing, and aren't saved or sent anywhere.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Margin talks to your apps only on this Mac. It checks your browser's address bar to recognize the sites above, and never saves or sends addresses. The Blender connection is signed with a key that only your Mac account can read.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func step<Accessory: View>(
        _ number: Int, _ title: String, done: Bool, detail: String, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? Color.green : Color.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { accessory() }
        }
    }

    private func row(_ app: InstalledApp, _ connection: AppConnection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.image(for: app.url)).resizable().frame(width: 20, height: 20)
                Text(app.name)
                Spacer()
                status(connection)
                Button("Customize") { onOpen(app.id) }.controlSize(.small)
            }
            if case .midi(let steps) = connection {
                DisclosureGroup("One step in \(app.name)") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            if case .connector = connection, model.blenderLink != .notInstalled {
                Toggle("Keep Blender connected", isOn: Binding(
                    get: { model.blenderLink != .off },
                    set: { model.setBlenderConnector(on: $0) }))
                    .font(.callout).toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    @ViewBuilder private func status(_ connection: AppConnection) -> some View {
        switch connection {
        case .connector:
            Text(model.blenderLink.title).font(.caption)
                .foregroundStyle(model.blenderLink == .connected ? Color.green : model.blenderLink.needsAttention ? Color.orange : Color.secondary)
        case .midi:
            Text("Margin appears as a controller").font(.caption).foregroundStyle(.secondary)
        case .ready:
            Text(model.accessibilityGranted ? "Ready" : "Needs Accessibility").font(.caption)
                .foregroundStyle(model.accessibilityGranted ? Color.green : Color.orange)
        }
    }
}
