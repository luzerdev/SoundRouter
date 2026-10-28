import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let manufacturer: String
    let transportType: UInt32
    let outputChannels: Int
    let inputChannels: Int
    let sampleRate: Double
    let availableSampleRates: [Double]

    var hasOutput: Bool { outputChannels > 0 }
    var hasInput: Bool { inputChannels > 0 }
    var ref: DeviceRef { DeviceRef(uid: uid, name: name) }

    /// iPad / iPhone audio exposed through CoreMediaIO (after "Enable" in Audio MIDI Setup or SoundRouter).
    var isIOSDevice: Bool {
        let lower = name.lowercased()
        return lower.contains("ipad") || lower.contains("iphone") || uid.lowercased().contains("ios")
    }

    var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "Continuity"
        default: "Other"
        }
    }

    var symbolName: String {
        if isIOSDevice { return "ipad.landscape" }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return hasOutput ? "laptopcomputer" : "mic"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "cable.connector"
        case kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        default: return hasOutput ? "hifispeaker" : "mic"
        }
    }
}

/// Enumerates audio devices, tracks hot-plug and default-device changes, and exposes device controls.
@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [AudioDevice] = []
    private(set) var defaultOutputID: AudioObjectID = .unknown
    private(set) var defaultInputID: AudioObjectID = .unknown
    private(set) var systemOutputID: AudioObjectID = .unknown
    /// Bumped whenever a hardware volume/mute changes, so views re-read values.
    private(set) var volumeRevision = 0

    @ObservationIgnored var onDevicesChanged: (() -> Void)?
    @ObservationIgnored var onDefaultsChanged: (() -> Void)?
    @ObservationIgnored var onServiceRestarted: (() -> Void)?

    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []

    var outputs: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputs: [AudioDevice] { devices.filter(\.hasInput) }
    var defaultOutput: AudioDevice? { device(id: defaultOutputID) }
    var defaultInput: AudioDevice? { device(id: defaultInputID) }
    var systemOutput: AudioDevice? { device(id: systemOutputID) }

    init() {
        refresh()
        let changed: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onDevicesChanged?()
            }
        }
        let defaults: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDefaults()
                self?.onDefaultsChanged?()
            }
        }
        systemListeners = [
            PropertyListener(.system, kAudioHardwarePropertyDevices, handler: changed),
            PropertyListener(.system, kAudioHardwarePropertyDefaultOutputDevice, handler: defaults),
            PropertyListener(.system, kAudioHardwarePropertyDefaultInputDevice, handler: defaults),
            PropertyListener(.system, kAudioHardwarePropertyDefaultSystemOutputDevice, handler: defaults),
            PropertyListener(.system, kAudioHardwarePropertyServiceRestarted) { [weak self] in
                MainActor.assumeIsolated { self?.onServiceRestarted?() }
            },
        ]
    }

    func refresh() {
        let ids = CA.array(.system, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        let updated = ids.compactMap(Self.makeDevice)
            .sorted { ($0.transportType == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $0.name) < ($1.transportType == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $1.name) }
        refreshDefaults()
        // Creating our own aggregates also triggers a refresh; avoid churning the UI when nothing changed.
        guard updated != devices else { return }
        devices = updated
        installDeviceListeners()
    }

    private func refreshDefaults() {
        defaultOutputID = (try? CA.get(.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown)) ?? .unknown
        defaultInputID = (try? CA.get(.system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown)) ?? .unknown
        systemOutputID = (try? CA.get(.system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID.unknown)) ?? .unknown
    }

    private func installDeviceListeners() {
        let bump: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.volumeRevision &+= 1 } }
        deviceListeners = devices.flatMap { device -> [PropertyListener] in
            var list: [PropertyListener] = []
            for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
                if CA.has(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) {
                    list.append(PropertyListener(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, handler: bump))
                }
                if CA.has(device.id, kAudioDevicePropertyMute, scope: scope) {
                    list.append(PropertyListener(device.id, kAudioDevicePropertyMute, scope: scope, handler: bump))
                }
            }
            return list
        }
    }

    private static func makeDevice(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = CA.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        // Hide our own private aggregates.
        if uid.hasPrefix(RouteEngine.aggregateUIDPrefix) { return nil }
        let name = CA.string(id, kAudioObjectPropertyName) ?? "Unknown Device"
        let rates = CA.array(id, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)
            .flatMap { range -> [Double] in
                range.mMinimum == range.mMaximum ? [range.mMinimum]
                    : [44100, 48000, 88200, 96000, 176400, 192000].filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
            }
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            manufacturer: CA.string(id, kAudioObjectPropertyManufacturer) ?? "",
            transportType: (try? CA.get(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0,
            outputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            inputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeInput),
            sampleRate: (try? CA.get(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0,
            availableSampleRates: Array(Set(rates)).sorted()
        )
    }

    // MARK: Lookup

    func device(id: AudioObjectID) -> AudioDevice? { devices.first { $0.id == id } }
    func device(uid: String) -> AudioDevice? { devices.first { $0.uid == uid } }

    /// Resolves a saved reference to a connected device. The system-default sentinel resolves to the current default.
    func resolveOutput(_ ref: DeviceRef) -> AudioDevice? {
        if ref.isSystemDefault { return defaultOutput }
        return device(uid: ref.uid).flatMap { $0.hasOutput ? $0 : nil }
    }

    func resolveInput(_ ref: DeviceRef) -> AudioDevice? {
        if ref.isSystemDefault { return defaultInput }
        return device(uid: ref.uid).flatMap { $0.hasInput ? $0 : nil }
    }

    // MARK: Defaults

    func setDefaultOutput(_ device: AudioDevice) {
        try? CA.set(.system, kAudioHardwarePropertyDefaultOutputDevice, device.id)
    }

    func setDefaultInput(_ device: AudioDevice) {
        try? CA.set(.system, kAudioHardwarePropertyDefaultInputDevice, device.id)
    }

    func setSystemOutput(_ device: AudioDevice) {
        try? CA.set(.system, kAudioHardwarePropertyDefaultSystemOutputDevice, device.id)
    }

    // MARK: Hardware volume

    func hasVolumeControl(_ device: AudioDevice, input: Bool = false) -> Bool {
        CA.isSettable(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
    }

    func volume(_ device: AudioDevice, input: Bool = false) -> Float? {
        _ = volumeRevision
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        guard CA.has(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope) else { return nil }
        return try? CA.get(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, initial: Float32(0))
    }

    func setVolume(_ device: AudioDevice, _ value: Float, input: Bool = false) {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        try? CA.set(device.id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, Float32(min(max(value, 0), 1)))
    }

    func isMuted(_ device: AudioDevice, input: Bool = false) -> Bool {
        _ = volumeRevision
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return ((try? CA.get(device.id, kAudioDevicePropertyMute, scope: scope, initial: UInt32(0))) ?? 0) != 0
    }

    func canMute(_ device: AudioDevice, input: Bool = false) -> Bool {
        CA.isSettable(device.id, kAudioDevicePropertyMute, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
    }

    func setMuted(_ device: AudioDevice, _ muted: Bool, input: Bool = false) {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        try? CA.set(device.id, kAudioDevicePropertyMute, scope: scope, UInt32(muted ? 1 : 0))
    }

    // MARK: Format

    func setSampleRate(_ device: AudioDevice, _ rate: Double) {
        try? CA.set(device.id, kAudioDevicePropertyNominalSampleRate, Float64(rate))
        refresh()
    }

    func bufferSize(_ device: AudioDevice) -> UInt32 {
        (try? CA.get(device.id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))) ?? 0
    }

    func setBufferSize(_ device: AudioDevice, _ frames: UInt32) {
        try? CA.set(device.id, kAudioDevicePropertyBufferFrameSize, frames)
        volumeRevision &+= 1
    }
}
