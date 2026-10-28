import SwiftUI

struct DevicesView: View {
    @Environment(AppState.self) private var state
    @State private var selectedUID: String?

    var body: some View {
        HSplitView {
            List(selection: $selectedUID) {
                Section("Outputs") {
                    ForEach(state.devices.outputs) { row($0, isDefault: $0.id == state.devices.defaultOutputID).tag($0.uid) }
                }
                Section("Inputs") {
                    ForEach(state.devices.inputs.filter { !$0.hasOutput }) { row($0, isDefault: $0.id == state.devices.defaultInputID).tag($0.uid) }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            Group {
                if let uid = selectedUID, let device = state.devices.device(uid: uid) {
                    DeviceDetail(device: device)
                } else {
                    ContentUnavailableView("Select a device", systemImage: "hifispeaker.2",
                                           description: Text("Set defaults, volume, sample rate and per-device EQ."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedUID == nil { selectedUID = state.devices.defaultOutput?.uid } }
    }

    private func row(_ device: AudioDevice, isDefault: Bool) -> some View {
        HStack {
            Image(systemName: device.symbolName).frame(width: 22)
            VStack(alignment: .leading) {
                Text(device.name)
                Text(device.transportName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isDefault { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("System default") }
        }
    }
}

private struct DeviceDetail: View {
    @Environment(AppState.self) private var state
    let device: AudioDevice

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: device.name)
                LabeledContent("Manufacturer", value: device.manufacturer.isEmpty ? "—" : device.manufacturer)
                LabeledContent("Connection", value: device.transportName)
                LabeledContent("Channels", value: "\(device.outputChannels) out · \(device.inputChannels) in")
                LabeledContent("UID") { Text(device.uid).textSelection(.enabled).font(.caption.monospaced()) }
            }

            Section("Use as") {
                HStack {
                    if device.hasOutput {
                        Button("Default Output") { state.devices.setDefaultOutput(device) }
                            .disabled(device.id == state.devices.defaultOutputID)
                        Button("Sound Effects Output") { state.devices.setSystemOutput(device) }
                            .disabled(device.id == state.devices.systemOutputID)
                    }
                    if device.hasInput {
                        Button("Default Input") { state.devices.setDefaultInput(device) }
                            .disabled(device.id == state.devices.defaultInputID)
                    }
                }
            }

            if device.hasOutput {
                Section("Output volume") {
                    hardwareVolume(input: false)
                }
            }
            if device.hasInput {
                Section("Input level") {
                    hardwareVolume(input: true)
                }
            }

            Section("Format") {
                if device.availableSampleRates.count > 1 {
                    Picker("Sample rate", selection: Binding(
                        get: { device.sampleRate },
                        set: { state.devices.setSampleRate(device, $0) }
                    )) {
                        ForEach(device.availableSampleRates, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                    }
                } else {
                    LabeledContent("Sample rate", value: "\(Int(device.sampleRate)) Hz")
                }
                Picker("Buffer size", selection: Binding(
                    get: { state.devices.bufferSize(device) },
                    set: { state.devices.setBufferSize(device, $0) }
                )) {
                    ForEach([UInt32(32), 64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) frames").tag($0) }
                    let current = state.devices.bufferSize(device)
                    if ![32, 64, 128, 256, 512, 1024, 2048].contains(current) { Text("\(current) frames").tag(current) }
                }
                .help("Smaller buffers lower latency (useful for iPad play-through) at the cost of CPU")
            }

            if device.hasOutput {
                Section {
                    Text("Applied to everything SoundRouter sends to this device — set up headphone EQ here. Turn on “Process all audio” in Settings to apply it to apps without a route too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                EffectsEditor(settings: state.outputEffectsBinding(uid: device.uid), maxVolume: 2)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hardwareVolume(input: Bool) -> some View {
        if let volume = state.devices.volume(device, input: input), state.devices.hasVolumeControl(device, input: input) {
            HStack {
                Slider(value: Binding(get: { Double(volume) }, set: { state.devices.setVolume(device, Float($0), input: input) }), in: 0...1)
                Text("\(Int(volume * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        } else {
            Text(input ? "This device has no input gain control." : "No hardware volume. Use the software volume below, or turn on software volume keys in Settings.")
                .foregroundStyle(.secondary)
        }
        if state.devices.canMute(device, input: input) {
            Toggle("Mute", isOn: Binding(get: { state.devices.isMuted(device, input: input) },
                                         set: { state.devices.setMuted(device, $0, input: input) }))
        }
    }
}
