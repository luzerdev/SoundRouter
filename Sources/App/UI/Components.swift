import AppKit
import SwiftUI

/// Stereo peak meter that polls the engine ~20 times a second.
struct LevelMeterView: View {
    @Environment(AppState.self) private var state
    let keyPrefix: String
    var height: CGFloat = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { _ in
            let (left, right) = state.engine.levels(keyPrefix: keyPrefix)
            VStack(spacing: 2) {
                bar(left)
                bar(right)
            }
        }
        .frame(height: height * 2 + 2)
        .accessibilityHidden(true)
    }

    private func bar(_ level: Float) -> some View {
        GeometryReader { proxy in
            let db = 20 * log10(max(level, 1e-5))
            let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.95 ? Color.red : (level > 0.5 ? Color.yellow : Color.green))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}

/// Volume slider from 0 to `maximum` (4 = 400%), with the boosted part tinted.
struct VolumeSlider: View {
    @Binding var value: Float
    var maximum: Float = 4
    var showsPercent = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: value == 0 ? "speaker.slash" : "speaker.wave.1")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { Double(value) }, set: { value = Float($0) }), in: 0...Double(maximum))
                .tint(value > 1 ? .orange : .accentColor)
            if showsPercent {
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(value > 1 ? .orange : .secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .contextMenu {
            Button("Reset to 100%") { value = 1 }
        }
    }
}

struct StatusBadge: View {
    let state: RouteState?

    var body: some View {
        if let state {
            Label(text(state), systemImage: symbol(state.kind))
                .font(.caption)
                .foregroundStyle(color(state.kind))
                .help(state.message ?? "")
                .lineLimit(1)
        }
    }

    private func text(_ state: RouteState) -> String {
        switch state.kind {
        case .disabled: "Off"
        case .notRunning: "Not running"
        case .passthrough: "Default"
        case .routed: state.outputs.joined(separator: " + ")
        case .fallback: "Fallback: " + state.outputs.joined(separator: ", ")
        case .silenced: "Silenced"
        case .waitingForInput: "Waiting for input"
        case .unavailable: "Output unavailable"
        }
    }

    private func symbol(_ kind: RouteState.Kind) -> String {
        switch kind {
        case .disabled: "pause.circle"
        case .notRunning: "moon.zzz"
        case .passthrough: "arrow.right.circle"
        case .routed: "arrow.triangle.branch"
        case .fallback: "exclamationmark.triangle"
        case .silenced: "speaker.slash"
        case .waitingForInput: "hourglass"
        case .unavailable: "exclamationmark.octagon"
        }
    }

    private func color(_ kind: RouteState.Kind) -> Color {
        switch kind {
        case .routed: .accentColor
        case .fallback, .unavailable: .orange
        case .silenced: .red
        default: .secondary
        }
    }
}

/// Edits an ordered list of devices (priority order), allowing the "System Default" sentinel.
struct DevicePriorityList: View {
    @Environment(AppState.self) private var state
    @Binding var devices: [DeviceRef]
    var input = false
    var allowSystemDefault = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, ref in
                HStack {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    Image(systemName: symbol(ref))
                        .frame(width: 18)
                    Text(ref.name)
                    if !ref.isSystemDefault && state.devices.device(uid: ref.uid) == nil {
                        Text("disconnected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == devices.count - 1)
                    Button(role: .destructive) { devices.remove(at: index) } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }
            Menu {
                if allowSystemDefault && !devices.contains(.systemDefault) {
                    Button("System Default") { devices.append(.systemDefault) }
                    Divider()
                }
                ForEach(input ? state.devices.inputs : state.devices.outputs) { device in
                    if !devices.contains(where: { $0.uid == device.uid }) {
                        Button { devices.append(device.ref) } label: { Label(device.name, systemImage: device.symbolName) }
                    }
                }
            } label: {
                Label(input ? "Add Input" : "Add Output", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func symbol(_ ref: DeviceRef) -> String {
        if ref.isSystemDefault { return "gearshape" }
        return state.devices.device(uid: ref.uid)?.symbolName ?? "questionmark.circle"
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard devices.indices.contains(target) else { return }
        devices.swapAt(index, target)
    }
}

/// Quick single-output picker: sets the route's output list to exactly one device.
struct OutputMenu: View {
    @Environment(AppState.self) private var state
    @Binding var outputs: [DeviceRef]

    var body: some View {
        Menu {
            Button { outputs = [.systemDefault] } label: {
                Label("System Default", systemImage: outputs == [.systemDefault] ? "checkmark" : "gearshape")
            }
            Divider()
            ForEach(state.devices.outputs) { device in
                Button { outputs = [device.ref] } label: {
                    Label(device.name, systemImage: outputs.first?.uid == device.uid ? "checkmark" : device.symbolName)
                }
            }
        } label: {
            Text(summary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 200)
    }

    private var summary: String {
        guard let first = outputs.first else { return "None" }
        return outputs.count > 1 ? "\(first.name) +\(outputs.count - 1)" : first.name
    }
}

struct FallbackEditor: View {
    @Environment(AppState.self) private var state
    @Binding var fallback: Fallback
    var allowKeepOriginal = true

    var body: some View {
        Picker("If no preferred output is connected", selection: $fallback.action) {
            ForEach(FallbackAction.allCases.filter { allowKeepOriginal || $0 != .keepOriginal }) { action in
                Text(action.label).tag(action)
            }
        }
        if fallback.action == .useDevice {
            Picker("Fallback device", selection: $fallback.device) {
                Text("System Default").tag(DeviceRef.systemDefault)
                ForEach(state.devices.outputs) { Text($0.name).tag($0.ref) }
                if !fallback.device.isSystemDefault && state.devices.device(uid: fallback.device.uid) == nil {
                    Text("\(fallback.device.name) (disconnected)").tag(fallback.device)
                }
            }
        }
        Toggle("Show an alert", isOn: $fallback.alert)
    }
}

struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: size, height: size)
    }

    private var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
