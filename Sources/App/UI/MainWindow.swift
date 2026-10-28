import SwiftUI

struct MainWindow: View {
    static let id = "main"

    enum Section: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case inputs = "Inputs"
        case devices = "Devices"
        case rules = "Rules"
        case tools = "Tools"
        case settings = "Settings"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .apps: "square.grid.2x2"
            case .inputs: "ipad.and.arrow.forward"
            case .devices: "hifispeaker.2"
            case .rules: "list.bullet.rectangle"
            case .tools: "wrench.and.screwdriver"
            case .settings: "gearshape"
            }
        }
    }

    @Environment(AppState.self) private var state
    @State private var selection: Section? = .apps

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch selection ?? .apps {
                case .apps: AppsView()
                case .inputs: InputsView()
                case .devices: DevicesView()
                case .rules: RulesView()
                case .tools: ToolsView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle((selection ?? .apps).rawValue)
            .toolbar {
                ToolbarItem(placement: .navigation) { ProfilePicker() }
                ToolbarItem {
                    Toggle(isOn: Binding(get: { state.panicMuted }, set: { state.panicMuted = $0 })) {
                        Label("Mute All", systemImage: state.panicMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    }
                    .help("Panic mute: silence all routed audio (⌃⌥⌘M)")
                }
            }
        }
    }
}

struct ProfilePicker: View {
    @Environment(AppState.self) private var state
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        @Bindable var state = state
        Menu {
            Picker("Profile", selection: $state.config.activeProfileID) {
                ForEach(state.config.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New Profile…") {
                newName = "Profile \(state.config.profiles.count + 1)"
                renaming = true
            }
            Button("Duplicate Current Profile") {
                var copy = state.profile
                copy.id = UUID()
                copy.name += " Copy"
                state.config.profiles.append(copy)
                state.config.activeProfileID = copy.id
            }
            Button("Delete Current Profile", role: .destructive) {
                let id = state.profile.id
                state.config.profiles.removeAll { $0.id == id }
                state.config.activeProfileID = state.config.profiles.first?.id
            }
            .disabled(state.config.profiles.count < 2)
        } label: {
            Label(state.profile.name, systemImage: "person.crop.rectangle.stack")
        }
        .alert("New Profile", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let profile = Profile(name: newName.isEmpty ? "Untitled" : newName)
                state.config.profiles.append(profile)
                state.config.activeProfileID = profile.id
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
