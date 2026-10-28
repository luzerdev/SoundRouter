import AppKit
import SwiftUI

/// Input device → output play-through (replaces LadioCast). The iPad card replaces the
/// Audio MIDI Setup "Enable" step.
struct InputsView: View {
    @Environment(AppState.self) private var state
    @State private var editingID: UUID?

    private var iosDevices: [AudioDevice] { state.devices.inputs.filter(\.isIOSDevice) }

    var body: some View {
        @Bindable var state = state
        List {
            Section {
                Toggle(isOn: $state.config.settings.enableIOSDevices) {
                    VStack(alignment: .leading) {
                        Text("Enable iPad & iPhone audio")
                        Text("Connect the device with a cable and unlock it. It then shows up as an input, just like after pressing “Enable” in Audio MIDI Setup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(iosDevices) { device in
                    HStack {
                        Label(device.name, systemImage: device.symbolName)
                        Spacer()
                        if let route = state.profile.inputRoutes.first(where: { $0.input.uid == device.uid }) {
                            StatusBadge(state: state.routeStates[route.id])
                        } else {
                            Button("Play Through…") { addRoute(for: device) }
                        }
                    }
                }
                if state.config.settings.enableIOSDevices && iosDevices.isEmpty {
                    Text("No iPad or iPhone detected yet. Plug it in, unlock it, and tap “Trust” if asked.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iPad & iPhone")
            }

            Section("Input routes") {
                if state.profile.inputRoutes.isEmpty {
                    Text("Play any input (iPad, microphone, audio interface, capture card) through any output, with its own volume and effects.")
                        .foregroundStyle(.secondary)
                }
                ForEach($state.profile.inputRoutes) { $route in
                    InputRouteRow(route: $route) { editingID = route.id }
                }
                .onDelete { state.profile.inputRoutes.remove(atOffsets: $0) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(state.devices.inputs) { device in
                        Button { addRoute(for: device) } label: { Label(device.name, systemImage: device.symbolName) }
                    }
                } label: {
                    Label("Add Input Route", systemImage: "plus")
                }
            }
        }
        .sheet(item: Binding(
            get: { editingID.map(IdentifiedID.init) },
            set: { editingID = $0?.id }
        )) { item in
            InputRouteEditor(routeID: item.id)
        }
    }

    private func addRoute(for device: AudioDevice) {
        let route = InputRoute(name: device.name, input: device.ref)
        state.profile.inputRoutes.append(route)
        editingID = route.id
    }
}

struct IdentifiedID: Identifiable {
    let id: UUID
}

private struct InputRouteRow: View {
    @Environment(AppState.self) private var state
    @Binding var route: InputRoute
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $route.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Image(systemName: state.devices.device(uid: route.input.uid)?.symbolName ?? "mic")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).fontWeight(.medium)
                StatusBadge(state: state.routeStates[route.id])
                if let error = state.engine.error(keyPrefix: "input.\(route.id)") {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .frame(minWidth: 160, alignment: .leading)
            Spacer()
            if state.engine.isRunning(keyPrefix: "input.\(route.id)") {
                LevelMeterView(keyPrefix: "input.\(route.id)").frame(width: 60)
            }
            VolumeSlider(value: $route.effects.volume).frame(width: 230)
            Button { route.effects.muted.toggle() } label: {
                Image(systemName: route.effects.muted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(route.effects.muted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            OutputMenu(outputs: $route.outputs).frame(width: 170)
            Button(action: edit) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct InputRouteEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let routeID: UUID

    var body: some View {
        if let index = state.profile.inputRoutes.firstIndex(where: { $0.id == routeID }) {
            let route = Binding(
                get: { state.profile.inputRoutes[index] },
                set: { state.profile.inputRoutes[index] = $0 }
            )
            VStack(spacing: 0) {
                Form {
                    Section("Input") {
                        TextField("Name", text: route.name)
                        Picker("Device", selection: route.input) {
                            ForEach(state.devices.inputs) { Text($0.name).tag($0.ref) }
                            if state.devices.device(uid: route.wrappedValue.input.uid) == nil {
                                Text("\(route.wrappedValue.input.name) (disconnected)").tag(route.wrappedValue.input)
                            }
                        }
                        let channels = state.devices.device(uid: route.wrappedValue.input.uid)?.inputChannels ?? 2
                        Picker("Channels", selection: Binding(
                            get: { ChannelChoice(offset: route.wrappedValue.channelOffset, mono: route.wrappedValue.mono) },
                            set: { route.wrappedValue.channelOffset = $0.offset; route.wrappedValue.mono = $0.mono }
                        )) {
                            ForEach(ChannelChoice.all(channels: channels), id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Section {
                        DevicePriorityList(devices: route.outputs)
                        Toggle("Play on all connected outputs in the list", isOn: route.playOnAll)
                    } header: {
                        Text("Outputs")
                    } footer: {
                        Text("Starts automatically whenever the input device is connected.")
                    }
                    Section("When no output is available") {
                        FallbackEditor(fallback: route.fallback, allowKeepOriginal: false)
                    }
                    EffectsEditor(settings: route.effects, maxVolume: 4)
                }
                .formStyle(.grouped)
                Divider()
                HStack {
                    Button("Delete Route", role: .destructive) {
                        state.profile.inputRoutes.removeAll { $0.id == routeID }
                        dismiss()
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 640, height: 720)
        } else {
            Text("Route not found").padding().onAppear { dismiss() }
        }
    }
}

private struct ChannelChoice: Hashable {
    let offset: Int
    let mono: Bool

    var label: String { mono ? "Mono \(offset + 1)" : "Stereo \(offset + 1)–\(offset + 2)" }

    static func all(channels: Int) -> [ChannelChoice] {
        let count = max(channels, 1)
        var choices: [ChannelChoice] = stride(from: 0, to: max(count - 1, 1), by: 2).map { ChannelChoice(offset: $0, mono: false) }
        choices += (0..<count).map { ChannelChoice(offset: $0, mono: true) }
        return choices
    }
}
