import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import Observation
import SwiftUI

struct RouteState: Equatable {
    enum Kind { case disabled, notRunning, passthrough, routed, fallback, silenced, waitingForInput, unavailable }
    var kind: Kind
    var outputs: [String] = []
    var message: String?
}

/// The app's root model: owns the configuration and the audio services, reacts to device/app
/// events, runs rules, and turns the active profile into running streams.
@MainActor
@Observable
final class AppState {
    private var storedConfig: AppConfig
    var config: AppConfig {
        get { storedConfig }
        set {
            let old = storedConfig
            storedConfig = newValue
            configDidChange(from: old)
        }
    }
    let devices = DeviceManager()
    let processes = ProcessMonitor()
    let engine = RouteEngine()
    let helper = HelperClient()

    private(set) var routeStates: [UUID: RouteState] = [:]
    private var storedPanicMuted = false
    var panicMuted: Bool {
        get { storedPanicMuted }
        set {
            storedPanicMuted = newValue
            engine.panicMuted = newValue
            if let output = devices.defaultOutput, devices.canMute(output) { devices.setMuted(output, newValue) }
        }
    }
    var statusMessage: String?
    var isRestartingAudio = false

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private let hotKeys = HotKeyCenter()
    @ObservationIgnored private let volumeKeys = VolumeKeyInterceptor()
    @ObservationIgnored private let hud = VolumeHUD()
    @ObservationIgnored private var knownDeviceUIDs: Set<String> = []
    @ObservationIgnored private var unavailableRoutes: Set<UUID> = []
    @ObservationIgnored private var reconcileQueued = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        var loaded = Persistence.load()
        if loaded.profiles.isEmpty { loaded.profiles = [Profile(name: "Default")] }
        if loaded.activeProfileID == nil || !loaded.profiles.contains(where: { $0.id == loaded.activeProfileID }) {
            loaded.activeProfileID = loaded.profiles[0].id
        }
        storedConfig = loaded
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        notifier.enabled = config.settings.notifications
        notifier.requestAuthorization()
        applyDockIcon()
        LaunchService.apply(config.settings.launchMode)
        if config.settings.enableIOSDevices { IOSDeviceEnabler.enable() }

        devices.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        devices.onDefaultsChanged = { [weak self] in self?.setNeedsReconcile() }
        devices.onServiceRestarted = { [weak self] in self?.recoverFromAudioServiceRestart() }
        processes.onAudioProcessesChanged = { [weak self] in self?.setNeedsReconcile() }
        processes.onAppLaunched = { [weak self] bundleID, _ in
            self?.runRules { if case .appLaunched(let id, _) = $0 { return id == bundleID }; return false }
        }
        processes.onAppTerminated = { [weak self] bundleID, _ in
            self?.runRules { if case .appQuit(let id, _) = $0 { return id == bundleID }; return false }
        }

        knownDeviceUIDs = Set(devices.devices.map(\.uid))
        if config.settings.runRulesAtLaunch {
            for uid in knownDeviceUIDs {
                runRules { if case .deviceConnected(let d) = $0 { return d.uid == uid }; return false }
            }
        }
        applyDevicePriority()
        requestMicrophoneAccessIfNeeded()
        configureHotKeys()
        configureVolumeKeys()
        reconcile()
    }

    func shutdown() {
        Persistence.save(config)
        engine.teardownAll()
        volumeKeys.stop()
        hotKeys.unregisterAll()
    }

    // MARK: Profile access

    var activeProfileIndex: Int {
        config.profiles.firstIndex { $0.id == config.activeProfileID } ?? 0
    }

    var profile: Profile {
        get { config.profiles[activeProfileIndex] }
        set { config.profiles[activeProfileIndex] = newValue }
    }

    func appRoute(bundleID: String) -> AppRoute? {
        profile.appRoutes.first { $0.bundleID == bundleID }
    }

    /// A binding that creates the route the first time it is written to.
    func appRouteBinding(bundleID: String, name: String) -> Binding<AppRoute> {
        Binding(
            get: { self.appRoute(bundleID: bundleID) ?? AppRoute(bundleID: bundleID, appName: name) },
            set: { route in
                if let index = self.profile.appRoutes.firstIndex(where: { $0.bundleID == bundleID }) {
                    self.profile.appRoutes[index] = route
                } else {
                    self.profile.appRoutes.append(route)
                }
            }
        )
    }

    func removeAppRoute(bundleID: String) {
        profile.appRoutes.removeAll { $0.bundleID == bundleID }
    }

    func outputEffectsBinding(uid: String) -> Binding<EffectSettings> {
        Binding(
            get: { self.config.outputEffects[uid] ?? EffectSettings() },
            set: { self.config.outputEffects[uid] = $0.isNeutral ? nil : $0 }
        )
    }

    var allEQPresets: [EQPreset] { EQPreset.builtIn + config.customEQPresets }

    // MARK: Config changes

    private func configDidChange(from old: AppConfig) {
        guard started else { return }
        scheduleSave()
        if old.settings.showDockIcon != config.settings.showDockIcon { applyDockIcon() }
        if old.settings.launchMode != config.settings.launchMode { LaunchService.apply(config.settings.launchMode) }
        if old.settings.notifications != config.settings.notifications { notifier.enabled = config.settings.notifications }
        if old.settings.globalHotKeys != config.settings.globalHotKeys { configureHotKeys() }
        if old.settings.softwareVolumeKeys != config.settings.softwareVolumeKeys { configureVolumeKeys() }
        if old.settings.enableIOSDevices != config.settings.enableIOSDevices {
            config.settings.enableIOSDevices ? IOSDeviceEnabler.enable() : IOSDeviceEnabler.disable()
        }
        if old.activeProfileID != config.activeProfileID || old.profiles.map(\.devicePriority) != config.profiles.map(\.devicePriority) {
            applyDevicePriority()
        }
        if profile.inputRoutes.count > (old.profiles.first { $0.id == config.activeProfileID }?.inputRoutes.count ?? 0) {
            requestMicrophoneAccessIfNeeded()
        }
        setNeedsReconcile()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            Persistence.save(self.config)
        }
    }

    private func applyDockIcon() {
        NSApp.setActivationPolicy(config.settings.showDockIcon ? .regular : .accessory)
    }

    // MARK: Events

    private func devicesChanged() {
        let current = Set(devices.devices.map(\.uid))
        let added = current.subtracting(knownDeviceUIDs)
        let removed = knownDeviceUIDs.subtracting(current)
        knownDeviceUIDs = current

        for uid in added {
            runRules { if case .deviceConnected(let d) = $0 { return d.uid == uid }; return false }
        }
        for uid in removed {
            runRules { if case .deviceDisconnected(let d) = $0 { return d.uid == uid }; return false }
        }
        // Our own private aggregates also fire this notification; only real hot-plugs count.
        guard !added.isEmpty || !removed.isEmpty else { return }
        applyDevicePriority()
        engine.clearFailures()
        setNeedsReconcile()
    }

    private func recoverFromAudioServiceRestart() {
        engine.teardownAll()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            devices.refresh()
            processes.refresh()
            if config.settings.enableIOSDevices { IOSDeviceEnabler.enable() }
            reconcile()
        }
    }

    // MARK: Device priority

    func applyDevicePriority() {
        let priority = profile.devicePriority
        if priority.autoSwitchOutput,
           let best = priority.outputs.lazy.compactMap({ self.devices.device(uid: $0.uid) }).first(where: \.hasOutput),
           best.id != devices.defaultOutputID {
            devices.setDefaultOutput(best)
            if priority.alertWhenSwitching { notifier.post("Output switched", "Now playing through \(best.name).") }
        }
        if priority.autoSwitchInput,
           let best = priority.inputs.lazy.compactMap({ self.devices.device(uid: $0.uid) }).first(where: \.hasInput),
           best.id != devices.defaultInputID {
            devices.setDefaultInput(best)
            if priority.alertWhenSwitching { notifier.post("Input switched", "Now recording from \(best.name).") }
        }
    }

    // MARK: Rules

    private func runRules(_ matches: (RuleTrigger) -> Bool) {
        for rule in config.rules where rule.enabled && matches(rule.trigger) {
            rule.actions.forEach(perform)
        }
    }

    func perform(_ action: RuleAction) {
        switch action {
        case .setDefaultOutput(let ref):
            if let device = devices.device(uid: ref.uid), device.hasOutput { devices.setDefaultOutput(device) }
        case .setDefaultInput(let ref):
            if let device = devices.device(uid: ref.uid), device.hasInput { devices.setDefaultInput(device) }
        case .setSoundEffectsOutput(let ref):
            if let device = devices.device(uid: ref.uid), device.hasOutput { devices.setSystemOutput(device) }
        case .setDeviceVolume(let ref, let volume):
            if let device = devices.resolveOutput(ref) { devices.setVolume(device, volume) }
        case .activateProfile(let id):
            if config.profiles.contains(where: { $0.id == id }) { config.activeProfileID = id }
        case .enableInputRoute(let id, let on):
            if let index = profile.inputRoutes.firstIndex(where: { $0.id == id }) { profile.inputRoutes[index].enabled = on }
        case .enableAppRoute(let id, let on):
            if let index = profile.appRoutes.firstIndex(where: { $0.id == id }) { profile.appRoutes[index].enabled = on }
        case .notify(let message):
            notifier.post("SoundRouter", message)
        }
    }

    // MARK: Reconcile

    func setNeedsReconcile() {
        guard !reconcileQueued else { return }
        reconcileQueued = true
        Task { @MainActor [weak self] in
            self?.reconcileQueued = false
            self?.reconcile()
        }
    }

    /// Turns the active profile + connected devices + running apps into the set of streams to run.
    func reconcile() {
        var specs: [StreamSpec] = []
        var silenced: [String: [AudioObjectID]] = [:]
        var states: [UUID: RouteState] = [:]
        var routedProcesses: Set<AudioObjectID> = []
        var seenApps: Set<String> = []

        for route in profile.appRoutes {
            guard seenApps.insert(route.bundleID).inserted else { continue }
            guard route.enabled else { states[route.id] = .init(kind: .disabled); continue }
            let objects = processes.processObjects(forApp: route.bundleID).sorted()
            guard !objects.isEmpty else { states[route.id] = .init(kind: .notRunning); continue }
            if route.isPassthrough { states[route.id] = .init(kind: .passthrough); continue }

            let resolution = resolveTargets(id: route.id, name: route.appName, outputs: route.outputs,
                                            playOnAll: route.playOnAll, fallback: route.fallback)
            states[route.id] = resolution.state
            if resolution.silence {
                silenced["app.\(route.id)"] = objects
                routedProcesses.formUnion(objects)
            }
            for device in resolution.targets {
                specs.append(StreamSpec(key: "app.\(route.id).\(device.uid)", label: route.appName,
                                        source: .processes(objects), outputUID: device.uid,
                                        stages: [route.effects, outputEffects(device.uid)]))
            }
            if !resolution.targets.isEmpty { routedProcesses.formUnion(objects) }
        }

        for route in profile.inputRoutes {
            guard route.enabled else { states[route.id] = .init(kind: .disabled); continue }
            guard let input = devices.resolveInput(route.input) else {
                states[route.id] = .init(kind: .waitingForInput, message: "Waiting for \(route.input.name)")
                unavailableRoutes.remove(route.id)
                continue
            }
            let resolution = resolveTargets(id: route.id, name: route.name, outputs: route.outputs,
                                            playOnAll: route.playOnAll, fallback: route.fallback)
            states[route.id] = resolution.state
            for device in resolution.targets {
                specs.append(StreamSpec(key: "input.\(route.id).\(device.uid)", label: route.name,
                                        source: .input(uid: input.uid, channelOffset: route.channelOffset, mono: route.mono),
                                        outputUID: device.uid,
                                        stages: [route.effects, outputEffects(device.uid)]))
            }
        }

        if config.settings.processAllAudio, let output = devices.defaultOutput {
            let own = processes.ownProcessObject
            if own.isValid {
                let excluded = (routedProcesses.union([own])).sorted()
                specs.append(StreamSpec(key: "system.\(output.uid)", label: "System", source: .globalExcluding(excluded),
                                        outputUID: output.uid, stages: [outputEffects(output.uid)]))
            } else {
                // Without our own process object we'd capture our own output; try again shortly.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.setNeedsReconcile()
                }
            }
        }

        engine.apply(specs: specs, silenced: silenced)
        if routeStates != states { routeStates = states }
    }

    private func outputEffects(_ uid: String) -> EffectSettings {
        config.outputEffects[uid] ?? EffectSettings()
    }

    private struct Resolution {
        var targets: [AudioDevice]
        var state: RouteState
        var silence = false
    }

    /// Picks connected outputs by priority and applies the fallback policy when none is connected.
    private func resolveTargets(id: UUID, name: String, outputs: [DeviceRef], playOnAll: Bool, fallback: Fallback) -> Resolution {
        var seen: Set<String> = []
        let available = outputs.compactMap(devices.resolveOutput).filter { seen.insert($0.uid).inserted }
        let targets = playOnAll ? available : Array(available.prefix(1))

        if !targets.isEmpty {
            if unavailableRoutes.remove(id) != nil, fallback.alert {
                notifier.post(name, "Back on \(targets.map(\.name).joined(separator: ", ")).")
            }
            return Resolution(targets: targets, state: .init(kind: .routed, outputs: targets.map(\.name)))
        }

        let wanted = outputs.map(\.name).joined(separator: ", ")
        var resolution: Resolution
        switch fallback.action {
        case .keepOriginal:
            resolution = .init(targets: [], state: .init(kind: .unavailable, message: "\(wanted) unavailable — left on current output"))
        case .useDevice:
            if let device = devices.resolveOutput(fallback.device) {
                resolution = .init(targets: [device], state: .init(kind: .fallback, outputs: [device.name], message: "\(wanted) unavailable — using \(device.name)"))
            } else {
                resolution = .init(targets: [], state: .init(kind: .unavailable, message: "\(wanted) and fallback unavailable"))
            }
        case .silence:
            resolution = .init(targets: [], state: .init(kind: .silenced, message: "\(wanted) unavailable — silenced"), silence: true)
        }

        if unavailableRoutes.insert(id).inserted, fallback.alert {
            notifier.post("\(name): output unavailable", resolution.state.message ?? wanted)
        }
        return resolution
    }

    // MARK: Tools

    func restartAudio() {
        guard !isRestartingAudio else { return }
        isRestartingAudio = true
        statusMessage = "Restarting Core Audio…"
        engine.teardownAll()
        Task { @MainActor in
            defer { isRestartingAudio = false }
            do {
                try await helper.restartCoreAudio()
                try? await Task.sleep(for: .seconds(2))
                devices.refresh()
                processes.refresh()
                if config.settings.enableIOSDevices { IOSDeviceEnabler.enable() }
                engine.clearFailures()
                reconcile()
                statusMessage = "Core Audio restarted."
            } catch {
                statusMessage = "Restart failed: \(error.localizedDescription)"
                reconcile()
            }
        }
    }

    func rebuildRoutes() {
        engine.teardownAll()
        devices.refresh()
        processes.refresh()
        reconcile()
        statusMessage = "Routes rebuilt."
    }

    func nextProfile() {
        guard config.profiles.count > 1 else { return }
        let next = config.profiles[(activeProfileIndex + 1) % config.profiles.count]
        config.activeProfileID = next.id
        hud.show(title: next.name, level: nil, muted: false, symbol: "person.crop.rectangle.stack")
    }

    func cycleDefaultOutput() {
        let outputs = devices.outputs
        guard !outputs.isEmpty else { return }
        let index = outputs.firstIndex { $0.id == devices.defaultOutputID } ?? -1
        let next = outputs[(index + 1) % outputs.count]
        devices.setDefaultOutput(next)
        hud.show(title: next.name, level: nil, muted: false, symbol: next.symbolName)
    }

    /// Copies a live Audio Unit's state into every config that uses it and into its other instances.
    func storeAudioUnitState(configID: UUID, from unit: AUAudioUnit) {
        guard let state = unit.fullState,
              let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { return }

        func update(_ settings: inout EffectSettings) {
            for index in settings.audioUnits.indices where settings.audioUnits[index].id == configID {
                settings.audioUnits[index].state = data
            }
        }
        var newConfig = config
        for p in newConfig.profiles.indices {
            for r in newConfig.profiles[p].appRoutes.indices { update(&newConfig.profiles[p].appRoutes[r].effects) }
            for r in newConfig.profiles[p].inputRoutes.indices { update(&newConfig.profiles[p].inputRoutes[r].effects) }
        }
        for key in newConfig.outputEffects.keys { update(&newConfig.outputEffects[key]!) }
        config = newConfig

        for other in engine.audioUnits(for: configID) where other !== unit {
            other.fullState = state
        }
    }

    // MARK: Permissions

    private func requestMicrophoneAccessIfNeeded() {
        guard !profile.inputRoutes.isEmpty, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Keyboard

    private func configureHotKeys() {
        hotKeys.unregisterAll()
        guard config.settings.globalHotKeys else { return }
        hotKeys.register(.init(keyCode: kVK_ANSI_P, modifiers: HotKeyCenter.hyper, title: "Next profile", display: "⌃⌥⌘P")) { [weak self] in
            self?.nextProfile()
        }
        hotKeys.register(.init(keyCode: kVK_ANSI_M, modifiers: HotKeyCenter.hyper, title: "Panic mute", display: "⌃⌥⌘M")) { [weak self] in
            guard let self else { return }
            self.panicMuted.toggle()
            self.hud.show(title: self.panicMuted ? "All routed audio muted" : "Unmuted", level: nil, muted: self.panicMuted)
        }
        hotKeys.register(.init(keyCode: kVK_ANSI_O, modifiers: HotKeyCenter.hyper, title: "Next output", display: "⌃⌥⌘O")) { [weak self] in
            self?.cycleDefaultOutput()
        }
        hotKeys.register(.init(keyCode: kVK_ANSI_R, modifiers: HotKeyCenter.hyper, title: "Rebuild routes", display: "⌃⌥⌘R")) { [weak self] in
            self?.rebuildRoutes()
        }
    }

    static let hotKeyList: [(String, String)] = [
        ("⌃⌥⌘P", "Switch to next profile"),
        ("⌃⌥⌘M", "Panic mute all routed audio"),
        ("⌃⌥⌘O", "Cycle default output device"),
        ("⌃⌥⌘R", "Rebuild all routes"),
    ]

    private func configureVolumeKeys() {
        guard config.settings.softwareVolumeKeys else {
            volumeKeys.stop()
            return
        }
        volumeKeys.handler = { [weak self] key, fine in
            self?.handleVolumeKey(key, fine: fine) ?? false
        }
        volumeKeys.start()
    }

    /// Software volume for the default output when the hardware has no volume control.
    private func handleVolumeKey(_ key: VolumeKeyInterceptor.Key, fine: Bool) -> Bool {
        guard let output = devices.defaultOutput, !devices.hasVolumeControl(output) else { return false }
        var effects = config.outputEffects[output.uid] ?? EffectSettings()
        let step: Float = fine ? 1 / 64 : 1 / 16
        switch key {
        case .up: effects.volume = min(1, effects.volume + step); effects.muted = false
        case .down: effects.volume = max(0, effects.volume - step)
        case .mute: effects.muted.toggle()
        }
        config.outputEffects[output.uid] = effects
        hud.show(title: output.name, level: effects.volume, muted: effects.muted, symbol: output.symbolName)
        return true
    }

    var accessibilityTrusted: Bool { VolumeKeyInterceptor.isTrusted }
}
