import AppKit
import SwiftUI

/// The menu bar panel: quick device switching, per-app volume and routing, input routes.
struct MenuBarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SoundRouter").font(.headline)
                Spacer()
                Menu {
                    Picker("Profile", selection: $state.config.activeProfileID) {
                        ForEach(state.config.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(state.profile.name, systemImage: "person.crop.rectangle.stack")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            deviceSection(title: "Output", devices: state.devices.outputs, current: state.devices.defaultOutput) {
                state.devices.setDefaultOutput($0)
            }
            if let output = state.devices.defaultOutput {
                if let volume = state.devices.volume(output), state.devices.hasVolumeControl(output) {
                    Slider(value: Binding(get: { Double(volume) }, set: { state.devices.setVolume(output, Float($0)) }), in: 0...1) {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .labelsHidden()
                } else {
                    VolumeSlider(value: state.outputEffectsBinding(uid: output.uid).volume, maximum: 1)
                        .help("Software volume (this device has no hardware volume)")
                }
            }
            deviceSection(title: "Input", devices: state.devices.inputs, current: state.devices.defaultInput) {
                state.devices.setDefaultInput($0)
            }

            Divider()

            Text("Apps").font(.subheadline).foregroundStyle(.secondary)
            if state.processes.apps.isEmpty {
                Text("No apps are using audio.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(state.processes.apps) { app in
                        MenuAppRow(app: app)
                    }
                }
            }
            .frame(maxHeight: 280)

            if !state.profile.inputRoutes.isEmpty {
                Divider()
                Text("Inputs").font(.subheadline).foregroundStyle(.secondary)
                ForEach($state.profile.inputRoutes) { $route in
                    HStack {
                        Toggle(isOn: $route.enabled) { Text(route.name).lineLimit(1) }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        Spacer()
                        StatusBadge(state: state.routeStates[route.id])
                    }
                }
            }

            Divider()

            HStack {
                Button { state.panicMuted.toggle() } label: {
                    Label(state.panicMuted ? "Unmute All" : "Mute All", systemImage: state.panicMuted ? "speaker.wave.2" : "speaker.slash")
                }
                Button { state.restartAudio() } label: { Label("Restart Audio", systemImage: "arrow.clockwise") }
                    .disabled(state.isRestartingAudio)
                Spacer()
                Button {
                    openWindow(id: MainWindow.id)
                    NSApp.activate()
                } label: { Image(systemName: "macwindow") }
                    .help("Open SoundRouter")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit SoundRouter (routed apps return to normal)")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func deviceSection(title: String, devices: [AudioDevice], current: AudioDevice?, select: @escaping (AudioDevice) -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Menu {
                ForEach(devices) { device in
                    Button { select(device) } label: {
                        Label(device.name, systemImage: device.id == current?.id ? "checkmark" : device.symbolName)
                    }
                }
            } label: {
                Label(current?.name ?? "None", systemImage: current?.symbolName ?? "questionmark")
            }
            .menuStyle(.borderlessButton)
        }
    }
}

private struct MenuAppRow: View {
    @Environment(AppState.self) private var state
    let app: AudioApp

    var body: some View {
        let route = state.appRouteBinding(bundleID: app.bundleID, name: app.name)
        let routeID = state.appRoute(bundleID: app.bundleID)?.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AppIcon(bundleID: app.bundleID, size: 18)
                Text(app.name).lineLimit(1)
                if app.isPlaying {
                    Image(systemName: "waveform").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                OutputMenu(outputs: route.outputs).frame(width: 130)
            }
            HStack {
                VolumeSlider(value: route.effects.volume)
                Button { route.wrappedValue.effects.muted.toggle() } label: {
                    Image(systemName: route.wrappedValue.effects.muted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(route.wrappedValue.effects.muted ? .red : .secondary)
                }
                .buttonStyle(.borderless)
            }
            if let routeID, state.engine.isRunning(keyPrefix: "app.\(routeID)") {
                LevelMeterView(keyPrefix: "app.\(routeID)", height: 2)
            }
        }
    }
}
