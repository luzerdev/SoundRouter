import AudioToolbox
import AVFoundation
import SwiftUI

/// Volume / balance / Magic Boost / 10-band EQ / Audio Unit chain. Used for apps, inputs and outputs.
struct EffectsEditor: View {
    @Environment(AppState.self) private var state
    @Binding var settings: EffectSettings
    var maxVolume: Float = 4
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        Section("Volume") {
            VolumeSlider(value: $settings.volume, maximum: maxVolume)
            Toggle("Mute", isOn: $settings.muted)
            LabeledContent("Balance") {
                HStack {
                    Text("L").foregroundStyle(.secondary)
                    Slider(value: $settings.balance, in: -1...1)
                    Text("R").foregroundStyle(.secondary)
                }
                .contextMenu { Button("Center") { settings.balance = 0 } }
            }
            LabeledContent("Magic Boost") {
                HStack {
                    Slider(value: $settings.magicBoost, in: 0...1)
                    Text(settings.magicBoost == 0 ? "Off" : "\(Int(settings.magicBoost * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .help("Compresses and lifts quiet audio, like dialogue in videos")
        }

        Section {
            HStack {
                Toggle("Equalizer", isOn: $settings.eqEnabled)
                Spacer()
                Menu(settings.eqPresetName ?? "Custom") {
                    ForEach(state.allEQPresets) { preset in
                        Button(preset.name) {
                            settings.eqBands = preset.bands
                            settings.eqPresetName = preset.name
                            settings.eqEnabled = true
                        }
                    }
                    Divider()
                    Button("Save as Preset…") {
                        presetName = ""
                        savingPreset = true
                    }
                    if !state.config.customEQPresets.isEmpty {
                        Menu("Delete Preset") {
                            ForEach(state.config.customEQPresets) { preset in
                                Button(preset.name) { state.config.customEQPresets.removeAll { $0.name == preset.name } }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            EQBandsView(bands: Binding(
                get: { settings.eqBands },
                set: {
                    settings.eqBands = $0
                    settings.eqPresetName = nil
                    settings.eqEnabled = true
                }
            ))
            .opacity(settings.eqEnabled ? 1 : 0.45)
        } header: {
            Text("Equalizer")
        }
        .alert("Save EQ Preset", isPresented: $savingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                state.config.customEQPresets.removeAll { $0.name == name }
                state.config.customEQPresets.append(EQPreset(name: name, bands: settings.eqBands))
                settings.eqPresetName = name
            }
            Button("Cancel", role: .cancel) {}
        }

        Section {
            if settings.audioUnits.isEmpty {
                Text("No Audio Unit effects. Add any installed effect — Apple's reverb, delay, dynamics, or third-party plug-ins.")
                    .foregroundStyle(.secondary)
            }
            ForEach($settings.audioUnits) { $unit in
                HStack {
                    Toggle("", isOn: Binding(get: { !unit.bypassed }, set: { unit.bypassed = !$0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    VStack(alignment: .leading) {
                        Text(unit.name)
                        Text(unit.manufacturerName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { AUEditorWindow.open(unit, state: state) }
                    Button(role: .destructive) {
                        settings.audioUnits.removeAll { $0.id == unit.id }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
            .onMove { settings.audioUnits.move(fromOffsets: $0, toOffset: $1) }
            AddAudioUnitMenu { settings.audioUnits.append($0) }
        } header: {
            Text("Audio Unit Effects")
        }
    }
}

struct EQBandsView: View {
    @Binding var bands: [Float]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack {
                Text("+12").font(.caption2)
                Spacer()
                Text("0").font(.caption2)
                Spacer()
                Text("-12").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(height: 140)
            .padding(.bottom, 18)

            ForEach(GraphicEQ.frequencies.indices, id: \.self) { index in
                VStack(spacing: 4) {
                    VerticalSlider(value: Binding(
                        get: { index < bands.count ? bands[index] : 0 },
                        set: { value in
                            var copy = bands
                            while copy.count < GraphicEQ.frequencies.count { copy.append(0) }
                            copy[index] = value
                            bands = copy
                        }
                    ), range: GraphicEQ.range)
                    .frame(width: 22, height: 140)
                    Text(GraphicEQ.labels[index])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = CGFloat((value - range.lowerBound) / span)
            let zero = CGFloat((0 - range.lowerBound) / span)
            ZStack(alignment: .bottom) {
                Capsule().fill(.quaternary).frame(width: 4)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: abs(fraction - zero) * height)
                    .offset(y: -min(fraction, zero) * height)
                Circle()
                    .fill(.background)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .offset(y: -fraction * height + 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = Float(1 - max(0, min(height, drag.location.y)) / height)
                value = ((range.lowerBound + f * span) * 2).rounded() / 2
            })
            .onTapGesture(count: 2) { value = 0 }
            .help("\(value, specifier: "%+.1f") dB — double-click to reset")
        }
    }
}

struct AddAudioUnitMenu: View {
    let add: (AUEffectConfig) -> Void

    private var components: [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        return types.flatMap { type in
            manager.components(matching: AudioComponentDescription(componentType: type, componentSubType: 0,
                                                                    componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    var body: some View {
        Menu {
            let grouped = Dictionary(grouping: components, by: \.manufacturerName)
            ForEach(grouped.keys.sorted(), id: \.self) { manufacturer in
                Menu(manufacturer) {
                    ForEach(grouped[manufacturer] ?? [], id: \.self) { component in
                        Button(component.name) {
                            let d = component.audioComponentDescription
                            add(AUEffectConfig(name: component.name, manufacturerName: component.manufacturerName,
                                               componentType: d.componentType, componentSubType: d.componentSubType,
                                               componentManufacturer: d.componentManufacturer))
                        }
                    }
                }
            }
        } label: {
            Label("Add Effect", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
