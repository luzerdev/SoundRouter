import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolsView: View {
    @Environment(AppState.self) private var state
    @State private var matchInputUID: String?
    @State private var matchOutputUID: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Restart Core Audio")
                        Text("Fixes crackling, missing devices or stuck audio. Routes rebuild automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isRestartingAudio { ProgressView().controlSize(.small) }
                    Button("Restart") { state.restartAudio() }.disabled(state.isRestartingAudio)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text("Privileged helper")
                        Text(state.helper.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.helper.status == .enabled {
                        Button("Uninstall") { Task { try? await state.helper.uninstall() } }
                    } else {
                        Button("Install") {
                            do { try state.helper.install() } catch { state.statusMessage = error.localizedDescription }
                        }
                    }
                }
                .help("With the helper installed, restarting Core Audio doesn't ask for your password")
                HStack {
                    VStack(alignment: .leading) {
                        Text("Rebuild all routes")
                        Text("Tears down every tap and stream and starts them again (⌃⌥⌘R).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rebuild") { state.rebuildRoutes() }
                }
                if let message = state.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio service")
            }

            Section {
                Picker("Input", selection: $matchInputUID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(state.devices.inputs) { Text("\($0.name) — \(Int($0.sampleRate)) Hz").tag(Optional($0.uid)) }
                }
                Picker("Output", selection: $matchOutputUID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(state.devices.outputs) { Text("\($0.name) — \(Int($0.sampleRate)) Hz").tag(Optional($0.uid)) }
                }
                HStack {
                    Spacer()
                    Button("Set Input to Output’s Rate") { matchRates() }
                        .disabled(matchInputUID == nil || matchOutputUID == nil)
                }
            } header: {
                Text("Match sample rates")
            } footer: {
                Text("Play-through sounds best when both devices run at the same rate (avoids resampling and drift).")
            }

            Section("Shortcuts") {
                Button("Open Audio MIDI Setup") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                }
                Button("Open Sound Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                Button("Reveal Configuration File") {
                    NSWorkspace.shared.activateFileViewerSelecting([Persistence.configURL])
                }
            }

            Section("Backup") {
                HStack {
                    Button("Export Configuration…") { exportConfig() }
                    Button("Import Configuration…") { importConfig() }
                    Spacer()
                    Button("Reset Everything…", role: .destructive) { reset() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func matchRates() {
        guard let input = matchInputUID.flatMap(state.devices.device(uid:)),
              let output = matchOutputUID.flatMap(state.devices.device(uid:)) else { return }
        if input.availableSampleRates.contains(output.sampleRate) || input.availableSampleRates.isEmpty {
            state.devices.setSampleRate(input, output.sampleRate)
            state.statusMessage = "\(input.name) set to \(Int(output.sampleRate)) Hz."
        } else if output.availableSampleRates.contains(input.sampleRate) {
            state.devices.setSampleRate(output, input.sampleRate)
            state.statusMessage = "\(input.name) can't run at \(Int(output.sampleRate)) Hz, so \(output.name) was set to \(Int(input.sampleRate)) Hz."
        } else {
            state.statusMessage = "These devices have no sample rate in common."
        }
        state.rebuildRoutes()
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SoundRouter.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Persistence.export(state.config, to: url) } catch { state.statusMessage = error.localizedDescription }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { state.config = try Persistence.importConfig(from: url) } catch { state.statusMessage = "Import failed: \(error.localizedDescription)" }
    }

    private func reset() {
        let alert = NSAlert()
        alert.messageText = "Reset SoundRouter?"
        alert.informativeText = "All profiles, routes, rules and effects will be deleted."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var fresh = AppConfig()
        fresh.activeProfileID = fresh.profiles.first?.id
        state.config = fresh
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Startup") {
                Picker("Launch", selection: $state.config.settings.launchMode) {
                    ForEach(LaunchMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Show in Dock (the menu bar icon is always shown)", isOn: $state.config.settings.showDockIcon)
                Toggle("Run “device connects” rules for devices already connected at launch", isOn: $state.config.settings.runRulesAtLaunch)
            }

            Section {
                Toggle("Process all audio", isOn: $state.config.settings.processAllAudio)
            } footer: {
                Text("Sends apps without their own route through SoundRouter as well, so per-device EQ and software volume apply to everything. Adds a few milliseconds of latency.")
            }

            Section {
                Toggle("Use volume keys for devices without hardware volume", isOn: $state.config.settings.softwareVolumeKeys)
                if state.config.settings.softwareVolumeKeys && !state.accessibilityTrusted {
                    HStack {
                        Text("Needs Accessibility permission.").foregroundStyle(.orange)
                        Spacer()
                        Button("Grant…") { VolumeKeyInterceptor.promptForAccess() }
                    }
                }
            } footer: {
                Text("HDMI displays and many USB interfaces have no volume control in macOS. With this on, the volume keys change SoundRouter’s software volume instead (⌥⇧ for fine steps). Works best with “Process all audio”.")
            }

            Section("Keyboard shortcuts") {
                Toggle("Enable global shortcuts", isOn: $state.config.settings.globalHotKeys)
                ForEach(AppState.hotKeyList, id: \.0) { shortcut, title in
                    LabeledContent(title) { Text(shortcut).monospaced() }
                }
            }

            Section("Notifications") {
                Toggle("Show alerts for fallbacks, device switches and rules", isOn: $state.config.settings.notifications)
            }
        }
        .formStyle(.grouped)
    }
}
