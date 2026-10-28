import SwiftUI

struct RulesView: View {
    @Environment(AppState.self) private var state
    @State private var editingRule: Rule?

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Toggle("Automatically switch the default output", isOn: $state.profile.devicePriority.autoSwitchOutput)
                if state.profile.devicePriority.autoSwitchOutput {
                    DevicePriorityList(devices: $state.profile.devicePriority.outputs, allowSystemDefault: false)
                }
                Toggle("Automatically switch the default input", isOn: $state.profile.devicePriority.autoSwitchInput)
                if state.profile.devicePriority.autoSwitchInput {
                    DevicePriorityList(devices: $state.profile.devicePriority.inputs, input: true, allowSystemDefault: false)
                }
                Toggle("Notify when switching", isOn: $state.profile.devicePriority.alertWhenSwitching)
            } header: {
                Text("Device priority (\(state.profile.name) profile)")
            } footer: {
                Text("When a device connects or disconnects, the highest connected device in the list becomes the default. Per-app outputs are set on the Apps page.")
            }

            Section {
                if state.config.rules.isEmpty {
                    Text("Rules run actions when a device connects or disconnects, or an app launches or quits. For example: when the headset connects, switch to the “Headphones” profile.")
                        .foregroundStyle(.secondary)
                }
                ForEach($state.config.rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        VStack(alignment: .leading) {
                            Text(rule.name).fontWeight(.medium)
                            Text("\(rule.trigger.label) → \(rule.actions.count) action\(rule.actions.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit…") { editingRule = rule }
                    }
                }
                .onDelete { state.config.rules.remove(atOffsets: $0) }
                Button {
                    editingRule = Rule(name: "New Rule", trigger: .deviceConnected(state.devices.defaultOutput?.ref ?? .systemDefault))
                } label: { Label("Add Rule", systemImage: "plus") }
            } header: {
                Text("Rules (all profiles)")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule) { saved in
                if let index = state.config.rules.firstIndex(where: { $0.id == saved.id }) {
                    state.config.rules[index] = saved
                } else {
                    state.config.rules.append(saved)
                }
            }
        }
    }
}

private struct RuleEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let save: (Rule) -> Void

    enum TriggerKind: String, CaseIterable, Identifiable {
        case deviceConnected = "Device connects"
        case deviceDisconnected = "Device disconnects"
        case appLaunched = "App launches"
        case appQuit = "App quits"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $rule.name)
                Section("When") { triggerEditor }
                Section("Do") {
                    ForEach(rule.actions.indices, id: \.self) { index in
                        HStack(alignment: .top) {
                            ActionEditor(action: $rule.actions[index])
                            Button(role: .destructive) { rule.actions.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Menu {
                        let device = state.devices.defaultOutput?.ref ?? .systemDefault
                        Button("Set default output") { rule.actions.append(.setDefaultOutput(device)) }
                        Button("Set default input") { rule.actions.append(.setDefaultInput(state.devices.defaultInput?.ref ?? .systemDefault)) }
                        Button("Set sound effects output") { rule.actions.append(.setSoundEffectsOutput(device)) }
                        Button("Set device volume") { rule.actions.append(.setDeviceVolume(device, 0.5)) }
                        Button("Switch profile") { rule.actions.append(.activateProfile(state.profile.id)) }
                        if let first = state.profile.inputRoutes.first {
                            Button("Turn input route on/off") { rule.actions.append(.enableInputRoute(first.id, true)) }
                        }
                        if let first = state.profile.appRoutes.first {
                            Button("Turn app route on/off") { rule.actions.append(.enableAppRoute(first.id, true)) }
                        }
                        Button("Show notification") { rule.actions.append(.notify("Rule \(rule.name) ran")) }
                    } label: { Label("Add Action", systemImage: "plus") }
                    .fixedSize()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") { save(rule); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
    }

    private var triggerKind: Binding<TriggerKind> {
        Binding(
            get: {
                switch rule.trigger {
                case .deviceConnected: .deviceConnected
                case .deviceDisconnected: .deviceDisconnected
                case .appLaunched: .appLaunched
                case .appQuit: .appQuit
                }
            },
            set: { kind in
                let device = state.devices.devices.first?.ref ?? .systemDefault
                let app = state.processes.apps.first.map { ($0.bundleID, $0.name) } ?? ("com.apple.Music", "Music")
                switch kind {
                case .deviceConnected: rule.trigger = .deviceConnected(device)
                case .deviceDisconnected: rule.trigger = .deviceDisconnected(device)
                case .appLaunched: rule.trigger = .appLaunched(bundleID: app.0, name: app.1)
                case .appQuit: rule.trigger = .appQuit(bundleID: app.0, name: app.1)
                }
            }
        )
    }

    @ViewBuilder
    private var triggerEditor: some View {
        Picker("Trigger", selection: triggerKind) {
            ForEach(TriggerKind.allCases) { Text($0.rawValue).tag($0) }
        }
        switch rule.trigger {
        case .deviceConnected(let device), .deviceDisconnected(let device):
            Picker("Device", selection: Binding(
                get: { device },
                set: { new in
                    if case .deviceConnected = rule.trigger { rule.trigger = .deviceConnected(new) } else { rule.trigger = .deviceDisconnected(new) }
                }
            )) {
                ForEach(state.devices.devices) { Text($0.name).tag($0.ref) }
                if state.devices.device(uid: device.uid) == nil { Text("\(device.name) (disconnected)").tag(device) }
            }
        case .appLaunched(let bundleID, let name), .appQuit(let bundleID, let name):
            Picker("App", selection: Binding(
                get: { bundleID },
                set: { id in
                    let newName = state.processes.app(bundleID: id)?.name
                        ?? state.profile.appRoutes.first { $0.bundleID == id }?.appName ?? id
                    if case .appLaunched = rule.trigger { rule.trigger = .appLaunched(bundleID: id, name: newName) } else { rule.trigger = .appQuit(bundleID: id, name: newName) }
                }
            )) {
                let known = Dictionary(
                    (state.processes.apps.map { ($0.bundleID, $0.name) } + state.profile.appRoutes.map { ($0.bundleID, $0.appName) } + [(bundleID, name)]),
                    uniquingKeysWith: { first, _ in first }
                )
                ForEach(known.keys.sorted(), id: \.self) { Text(known[$0] ?? $0).tag($0) }
            }
        }
    }
}

private struct ActionEditor: View {
    @Environment(AppState.self) private var state
    @Binding var action: RuleAction

    var body: some View {
        switch action {
        case .setDefaultOutput(let ref):
            devicePicker("Set default output to", ref, outputs: true) { action = .setDefaultOutput($0) }
        case .setDefaultInput(let ref):
            devicePicker("Set default input to", ref, outputs: false) { action = .setDefaultInput($0) }
        case .setSoundEffectsOutput(let ref):
            devicePicker("Play alerts through", ref, outputs: true) { action = .setSoundEffectsOutput($0) }
        case .setDeviceVolume(let ref, let volume):
            VStack {
                devicePicker("Set volume of", ref, outputs: true) { action = .setDeviceVolume($0, volume) }
                Slider(value: Binding(get: { Double(volume) }, set: { action = .setDeviceVolume(ref, Float($0)) }), in: 0...1) {
                    Text("Volume \(Int(volume * 100))%")
                }
            }
        case .activateProfile(let id):
            Picker("Switch to profile", selection: Binding(get: { id }, set: { action = .activateProfile($0) })) {
                ForEach(state.config.profiles) { Text($0.name).tag($0.id) }
            }
        case .enableInputRoute(let id, let on):
            HStack {
                Picker("Input route", selection: Binding(get: { id }, set: { action = .enableInputRoute($0, on) })) {
                    ForEach(state.profile.inputRoutes) { Text($0.name).tag($0.id) }
                }
                Toggle("On", isOn: Binding(get: { on }, set: { action = .enableInputRoute(id, $0) }))
            }
        case .enableAppRoute(let id, let on):
            HStack {
                Picker("App route", selection: Binding(get: { id }, set: { action = .enableAppRoute($0, on) })) {
                    ForEach(state.profile.appRoutes) { Text($0.appName).tag($0.id) }
                }
                Toggle("On", isOn: Binding(get: { on }, set: { action = .enableAppRoute(id, $0) }))
            }
        case .notify(let message):
            TextField("Notification text", text: Binding(get: { message }, set: { action = .notify($0) }))
        }
    }

    private func devicePicker(_ title: String, _ ref: DeviceRef, outputs: Bool, set: @escaping (DeviceRef) -> Void) -> some View {
        Picker(title, selection: Binding(get: { ref }, set: set)) {
            ForEach(outputs ? state.devices.outputs : state.devices.inputs) { Text($0.name).tag($0.ref) }
            if state.devices.device(uid: ref.uid) == nil { Text("\(ref.name) (disconnected)").tag(ref) }
        }
    }
}
