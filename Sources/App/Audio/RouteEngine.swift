import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Observation

/// What the planner wants playing. The engine diffs these against what is running.
struct StreamSpec: Equatable {
    enum Source: Equatable {
        /// Tap these app processes.
        case processes([AudioObjectID])
        /// Tap everything except these processes ("process all audio").
        case globalExcluding([AudioObjectID])
        /// Play an input device through.
        case input(uid: String, channelOffset: Int, mono: Bool)
    }

    /// Stable identity, e.g. "app.<routeID>.<outputUID>".
    let key: String
    let label: String
    let source: Source
    let outputUID: String
    /// Effect stages applied in order (app/input effects, then the output device's effects).
    var stages: [EffectSettings]

    /// Changes that need a new tap/aggregate rather than an in-place update.
    func requiresRebuild(from old: StreamSpec) -> Bool {
        guard outputUID == old.outputUID, stages.count == old.stages.count else { return true }
        switch (source, old.source) {
        case (.processes, .processes), (.globalExcluding, .globalExcluding): return false
        case let (.input(newUID, _, _), .input(oldUID, _, _)): return newUID != oldUID
        default: return true
        }
    }
}

/// Owns the running taps, aggregate devices and IOProcs.
@MainActor
@Observable
final class RouteEngine {
    static let aggregateUIDPrefix = "app.soundrouter.aggregate."

    /// Last error per stream key, for display.
    private(set) var errors: [String: String] = [:]
    private(set) var runningKeys: Set<String> = []

    @ObservationIgnored private var streams: [String: RunningStream] = [:]
    @ObservationIgnored private var silenceTaps: [String: ProcessTap] = [:]
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored var panicMuted = false {
        didSet { streams.values.forEach { $0.processor.forceMute = panicMuted } }
    }

    // MARK: Reconcile

    func apply(specs: [StreamSpec], silenced: [String: [AudioObjectID]]) {
        let wanted = Dictionary(specs.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for (key, stream) in streams where wanted[key] == nil {
            stop(stream)
            streams[key] = nil
        }

        for spec in specs {
            if let stream = streams[spec.key] {
                if spec.requiresRebuild(from: stream.spec) {
                    stop(stream)
                    streams[spec.key] = nil
                } else {
                    update(stream, to: spec)
                    continue
                }
            }
            if let failed = failedAt[spec.key], Date().timeIntervalSince(failed) < 5 { continue }
            do {
                streams[spec.key] = try start(spec)
                errors[spec.key] = nil
                failedAt[spec.key] = nil
            } catch {
                errors[spec.key] = error.localizedDescription
                failedAt[spec.key] = Date()
            }
        }

        applySilence(silenced)
        runningKeys = Set(streams.keys)
        errors = errors.filter { wanted[$0.key] != nil }
    }

    func teardownAll() {
        streams.values.forEach(stop)
        streams.removeAll()
        silenceTaps.values.forEach { $0.destroy() }
        silenceTaps.removeAll()
        failedAt.removeAll()
        runningKeys = []
    }

    /// Allows streams that failed recently to be retried on the next `apply` (e.g. after a device change).
    func clearFailures() {
        failedAt.removeAll()
    }

    // MARK: Queries

    func levels(keyPrefix: String) -> (Float, Float) {
        streams.reduce((Float(0), Float(0))) { result, entry in
            guard entry.key.hasPrefix(keyPrefix) else { return result }
            return (max(result.0, entry.value.processor.meter.left), max(result.1, entry.value.processor.meter.right))
        }
    }

    func isRunning(keyPrefix: String) -> Bool {
        runningKeys.contains { $0.hasPrefix(keyPrefix) }
    }

    func error(keyPrefix: String) -> String? {
        errors.first { $0.key.hasPrefix(keyPrefix) }?.value
    }

    /// Live Audio Unit instances for an effect config (one per stream that uses it).
    func audioUnits(for configID: UUID) -> [AUAudioUnit] {
        streams.values.flatMap { $0.renderers.flatMap { $0 } }.filter { $0.configID == configID }.map(\.audioUnit)
    }

    // MARK: Stream lifecycle

    private func start(_ spec: StreamSpec) throws -> RunningStream {
        guard CA.deviceID(forUID: spec.outputUID).isValid else {
            throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "Find output device")
        }

        var tap: ProcessTap?
        var subDevices = [AggregateDevice.SubDevice(uid: spec.outputUID, driftCompensation: false)]
        switch spec.source {
        case .processes(let objects):
            tap = try ProcessTap(processes: objects, mute: .mutedWhenTapped, name: "SoundRouter \(spec.label)")
        case .globalExcluding(let objects):
            tap = try ProcessTap(globalExcluding: objects, name: "SoundRouter System")
        case .input(let uid, _, _):
            guard CA.deviceID(forUID: uid).isValid else {
                throw CoreAudioError(status: kAudioHardwareBadDeviceError, operation: "Find input device")
            }
            if uid != spec.outputUID {
                // Input first so its channels come first in the IOProc's input buffers.
                subDevices.insert(.init(uid: uid, driftCompensation: true), at: 0)
            }
        }

        let aggregateID: AudioObjectID
        do {
            aggregateID = try AggregateDevice.create(
                name: "SoundRouter \(spec.label)",
                uid: Self.aggregateUIDPrefix + UUID().uuidString,
                mainSubDeviceUID: spec.outputUID,
                subDevices: subDevices,
                tapUUIDs: tap.map { [$0.uuid] } ?? []
            )
        } catch {
            tap?.destroy()
            throw error
        }

        let sampleRate = (try? CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(48000))) ?? 48000
        let processor = StreamProcessor(stageCount: spec.stages.count, sampleRate: sampleRate)
        processor.forceMute = panicMuted
        switch spec.source {
        case .processes, .globalExcluding:
            let totalInputs = CA.channelCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
            processor.inputOffset = max(0, totalInputs - (tap?.channelCount ?? 2))
        case .input(_, let offset, let mono):
            processor.inputOffset = offset
            processor.mono = mono
        }

        let stream = RunningStream(spec: spec, tap: tap, aggregateID: aggregateID, processor: processor, sampleRate: sampleRate)
        do {
            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                processor.render(input, output)
            }, "Create IOProc")
            stream.procID = procID
            try check(AudioDeviceStart(aggregateID, procID), "Start device")
        } catch {
            stop(stream)
            throw error
        }

        for (index, settings) in spec.stages.enumerated() {
            pushParameters(stream, stage: index, settings: settings)
            syncAudioUnits(stream, stage: index, settings: settings)
        }
        return stream
    }

    private func update(_ stream: RunningStream, to spec: StreamSpec) {
        let old = stream.spec
        stream.spec = spec

        switch (spec.source, old.source) {
        case let (.processes(current), .processes(previous)) where current != previous:
            if stream.tap?.update(processes: current) == false {
                rebuild(stream, spec)
                return
            }
        case let (.globalExcluding(current), .globalExcluding(previous)) where current != previous:
            if stream.tap?.update(processes: current) == false {
                rebuild(stream, spec)
                return
            }
        case let (.input(_, offset, mono), _):
            stream.processor.inputOffset = offset
            stream.processor.mono = mono
        default:
            break
        }

        for (index, settings) in spec.stages.enumerated() where index >= old.stages.count || old.stages[index] != settings {
            pushParameters(stream, stage: index, settings: settings)
            syncAudioUnits(stream, stage: index, settings: settings)
        }
    }

    private func rebuild(_ stream: RunningStream, _ spec: StreamSpec) {
        stop(stream)
        streams[spec.key] = try? start(spec)
    }

    private func stop(_ stream: RunningStream) {
        if let procID = stream.procID {
            AudioDeviceStop(stream.aggregateID, procID)
            AudioDeviceDestroyIOProcID(stream.aggregateID, procID)
            stream.procID = nil
        }
        AggregateDevice.destroy(stream.aggregateID)
        stream.tap?.destroy()
        stream.isStopped = true
    }

    private func applySilence(_ silenced: [String: [AudioObjectID]]) {
        for (key, tap) in silenceTaps where silenced[key] == nil {
            tap.destroy()
            silenceTaps[key] = nil
        }
        for (key, processes) in silenced {
            if let tap = silenceTaps[key] {
                if tap.description.processes != processes, !tap.update(processes: processes) {
                    tap.destroy()
                    silenceTaps[key] = try? ProcessTap(processes: processes, mute: .muted, name: "SoundRouter Silence")
                }
            } else {
                silenceTaps[key] = try? ProcessTap(processes: processes, mute: .muted, name: "SoundRouter Silence")
            }
        }
    }

    // MARK: Effects

    private func pushParameters(_ stream: RunningStream, stage: Int, settings: EffectSettings) {
        guard stage < stream.processor.stages.count else { return }
        let active = Set(settings.audioUnits.filter { !$0.bypassed }.map(\.id))
        let units = stream.renderers[stage].filter { active.contains($0.configID) }
        let flat = settings.eqBands.allSatisfy { $0 == 0 }
        stream.processor.stages[stage].update(.init(
            gain: settings.volume,
            muted: settings.muted,
            balance: settings.balance,
            eq: settings.eqEnabled && !flat ? GraphicEQ.coefficients(gains: settings.eqBands, sampleRate: stream.sampleRate) : nil,
            boost: settings.magicBoost,
            units: units
        ))
    }

    /// Instantiates Audio Units for a stage when its list of effects changes (not on bypass/state edits).
    private func syncAudioUnits(_ stream: RunningStream, stage: Int, settings: EffectSettings) {
        let ids = settings.audioUnits.map(\.id)
        guard ids != stream.renderers[stage].map(\.configID) else { return }
        stream.generation[stage] += 1
        let generation = stream.generation[stage]

        Task { @MainActor in
            var renderers: [AURenderer] = []
            for config in settings.audioUnits {
                if let existing = stream.renderers[stage].first(where: { $0.configID == config.id }) {
                    renderers.append(existing)
                    continue
                }
                let description = AudioComponentDescription(
                    componentType: config.componentType,
                    componentSubType: config.componentSubType,
                    componentManufacturer: config.componentManufacturer,
                    componentFlags: 0,
                    componentFlagsMask: 0
                )
                do {
                    let unit = try await AUAudioUnit.instantiate(with: description, options: .loadInProcess)
                    if let data = config.state,
                       let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        unit.fullState = state
                    }
                    renderers.append(try AURenderer(configID: config.id, audioUnit: unit, sampleRate: stream.sampleRate, maxFrames: StreamProcessor.maxFrames))
                } catch {
                    errors[stream.spec.key] = "\(config.name): \(error.localizedDescription)"
                }
            }
            guard !stream.isStopped, stream.generation[stage] == generation else { return }
            stream.renderers[stage] = renderers
            pushParameters(stream, stage: stage, settings: stream.spec.stages[stage])
        }
    }
}

private final class RunningStream {
    var spec: StreamSpec
    let tap: ProcessTap?
    let aggregateID: AudioObjectID
    var procID: AudioDeviceIOProcID?
    let processor: StreamProcessor
    let sampleRate: Double
    var renderers: [[AURenderer]]
    var generation: [Int]
    var isStopped = false

    init(spec: StreamSpec, tap: ProcessTap?, aggregateID: AudioObjectID, processor: StreamProcessor, sampleRate: Double) {
        self.spec = spec
        self.tap = tap
        self.aggregateID = aggregateID
        self.processor = processor
        self.sampleRate = sampleRate
        renderers = Array(repeating: [], count: spec.stages.count)
        generation = Array(repeating: 0, count: spec.stages.count)
    }
}
