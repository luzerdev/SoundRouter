import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: AppEntry?

    struct AppEntry: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let isRunning: Bool
        let isPlaying: Bool
    }

    private var running: [AppEntry] {
        state.processes.apps.map { AppEntry(bundleID: $0.bundleID, name: $0.name, isRunning: true, isPlaying: $0.isPlaying) }
    }

    private var saved: [AppEntry] {
        let runningIDs = Set(state.processes.apps.map(\.bundleID))
        return state.profile.appRoutes
            .filter { !runningIDs.contains($0.bundleID) }
            .map { AppEntry(bundleID: $0.bundleID, name: $0.appName, isRunning: false, isPlaying: false) }
    }

    var body: some View {
        List {
            Section("Apps using audio") {
                if running.isEmpty {
                    Text("No apps are using audio right now. Start playback in an app and it appears here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(running) { entry in
                    AppRow(entry: entry) { editing = entry }
                }
            }
            if !saved.isEmpty {
                Section("Saved routes (app not running)") {
                    ForEach(saved) { entry in
                        AppRow(entry: entry) { editing = entry }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .toolbar {
            ToolbarItem {
                Button { addApp() } label: { Label("Add App", systemImage: "plus") }
                    .help("Create a route for an app that isn't playing yet")
            }
        }
        .sheet(item: $editing) { entry in
            AppRouteEditor(bundleID: entry.bundleID, name: entry.name)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        if state.appRoute(bundleID: bundleID) == nil {
            state.profile.appRoutes.append(AppRoute(bundleID: bundleID, appName: name))
        }
        editing = AppEntry(bundleID: bundleID, name: name, isRunning: false, isPlaying: false)
    }
}

private struct AppRow: View {
    @Environment(AppState.self) private var state
    let entry: AppsView.AppEntry
    let edit: () -> Void

    var body: some View {
        let route = state.appRouteBinding(bundleID: entry.bundleID, name: entry.name)
        let routeID = state.appRoute(bundleID: entry.bundleID)?.id
        HStack(spacing: 12) {
            AppIcon(bundleID: entry.bundleID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).fontWeight(.medium)
                    if entry.isPlaying {
                        Image(systemName: "waveform").foregroundStyle(.green).symbolEffect(.variableColor.iterative)
                    }
                }
                StatusBadge(state: routeID.flatMap { state.routeStates[$0] } ?? (entry.isRunning ? RouteState(kind: .passthrough) : nil))
                if let routeID, let error = state.engine.error(keyPrefix: "app.\(routeID)") {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            if let routeID, state.engine.isRunning(keyPrefix: "app.\(routeID)") {
                LevelMeterView(keyPrefix: "app.\(routeID)")
                    .frame(width: 60)
            }

            VolumeSlider(value: route.effects.volume)
                .frame(width: 230)

            Button {
                route.wrappedValue.effects.muted.toggle()
            } label: {
                Image(systemName: route.wrappedValue.effects.muted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(route.wrappedValue.effects.muted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Mute")

            OutputMenu(outputs: route.outputs)
                .frame(width: 170)

            Button(action: edit) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Outputs, fallback, EQ and effects")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit Route…", action: edit)
            Button("Reset to Default") { state.removeAppRoute(bundleID: entry.bundleID) }
        }
    }
}

struct AppRouteEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let bundleID: String
    let name: String

    var body: some View {
        let route = state.appRouteBinding(bundleID: bundleID, name: name)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(bundleID: bundleID, size: 36)
                VStack(alignment: .leading) {
                    Text(name).font(.title2.weight(.semibold))
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: route.enabled).toggleStyle(.switch)
            }
            .padding()

            Divider()

            Form {
                Section {
                    DevicePriorityList(devices: route.outputs)
                    Toggle("Play on all connected outputs in the list (instead of only the first)", isOn: route.playOnAll)
                } header: {
                    Text("Outputs")
                } footer: {
                    Text("SoundRouter uses the first connected device in this list. Plug in a higher device and the app moves to it automatically.")
                }

                Section("When unavailable") {
                    FallbackEditor(fallback: route.fallback)
                }

                EffectsEditor(settings: route.effects, maxVolume: 4)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Remove Route", role: .destructive) {
                    state.removeAppRoute(bundleID: bundleID)
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 720)
    }
}
