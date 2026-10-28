import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import SwiftUI

/// Shows an Audio Unit's own editor (or a generic parameter list when it has none). Closing the
/// window saves the unit's state into the configuration and copies it to its other live instances.
@MainActor
final class AUEditorWindow: NSObject, NSWindowDelegate {
    private static var openEditors: [UUID: AUEditorWindow] = [:]

    private let config: AUEffectConfig
    private weak var state: AppState?
    private var window: NSWindow?
    private var unit: AUAudioUnit?

    static func open(_ config: AUEffectConfig, state: AppState) {
        if let existing = openEditors[config.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let editor = AUEditorWindow(config: config, state: state)
        openEditors[config.id] = editor
        editor.show()
    }

    private init(config: AUEffectConfig, state: AppState) {
        self.config = config
        self.state = state
    }

    private func show() {
        Task { @MainActor in
            guard let unit = await resolveUnit() else {
                Self.openEditors[config.id] = nil
                return
            }
            self.unit = unit
            let content = await viewController(for: unit)
            let window = NSWindow(contentViewController: content)
            window.title = "\(config.name) — \(config.manufacturerName)"
            window.styleMask.insert([.closable, .resizable])
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            self.window = window
        }
    }

    /// Prefer the instance that's currently processing audio, so edits are heard live.
    private func resolveUnit() async -> AUAudioUnit? {
        if let live = state?.engine.audioUnits(for: config.id).first { return live }
        let description = AudioComponentDescription(componentType: config.componentType, componentSubType: config.componentSubType,
                                                    componentManufacturer: config.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
        guard let unit = try? await AUAudioUnit.instantiate(with: description, options: .loadInProcess) else { return nil }
        if let data = config.state,
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            unit.fullState = saved
        }
        return unit
    }

    private func viewController(for unit: AUAudioUnit) async -> NSViewController {
        let custom: NSViewController? = await withCheckedContinuation { continuation in
            unit.requestViewController { continuation.resume(returning: $0) }
        }
        if let custom {
            if custom.preferredContentSize == .zero { custom.preferredContentSize = NSSize(width: 480, height: 320) }
            return custom
        }
        let generic = NSHostingController(rootView: GenericAUView(unit: unit))
        generic.preferredContentSize = NSSize(width: 440, height: 420)
        return generic
    }

    func windowWillClose(_ notification: Notification) {
        if let unit { state?.storeAudioUnitState(configID: config.id, from: unit) }
        Self.openEditors[config.id] = nil
    }
}

/// Fallback UI: one slider per parameter.
private struct GenericAUView: View {
    let unit: AUAudioUnit
    @State private var values: [AUParameterAddress: AUValue] = [:]

    private var parameters: [AUParameter] {
        unit.parameterTree?.allParameters.filter { $0.flags.contains(.flag_IsWritable) } ?? []
    }

    var body: some View {
        Form {
            if parameters.isEmpty {
                Text("This effect has no adjustable parameters.").foregroundStyle(.secondary)
            }
            ForEach(parameters, id: \.address) { parameter in
                LabeledContent(parameter.displayName) {
                    HStack {
                        Slider(value: Binding(
                            get: { values[parameter.address] ?? parameter.value },
                            set: {
                                parameter.value = $0
                                values[parameter.address] = $0
                            }
                        ), in: parameter.minValue...max(parameter.maxValue, parameter.minValue + 0.0001))
                        Text(parameter.string(fromValue: nil))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                            .id(values[parameter.address])
                        Text(parameter.unitName ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
