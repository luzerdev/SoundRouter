import CoreAudio
import Foundation

/// A Core Audio process tap (macOS 14.2+). With `.mutedWhenTapped` the app's original output is
/// silenced while we read it, so the only audible copy is the one we route.
final class ProcessTap {
    let id: AudioObjectID
    let description: CATapDescription
    var uuid: UUID { description.uuid }

    /// Tap specific processes (mixed down to stereo).
    convenience init(processes: [AudioObjectID], mute: CATapMuteBehavior, name: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        try self.init(description: description, mute: mute, name: name)
    }

    /// Tap everything except the given processes.
    convenience init(globalExcluding processes: [AudioObjectID], name: String) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        try self.init(description: description, mute: .mutedWhenTapped, name: name)
    }

    private init(description: CATapDescription, mute: CATapMuteBehavior, name: String) throws {
        description.uuid = UUID()
        description.name = name
        description.muteBehavior = mute
        description.isPrivate = true
        var tapID = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")
        self.id = tapID
        self.description = description
    }

    var channelCount: Int {
        let format = try? CA.get(id, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        return Int(format?.mChannelsPerFrame ?? 2)
    }

    /// Changes the tapped (or excluded) process list in place. Returns false if the HAL refused,
    /// in which case the caller should rebuild the tap.
    func update(processes: [AudioObjectID]) -> Bool {
        description.processes = processes
        var addr = CA.address(kAudioTapPropertyDescription)
        var object: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &object) {
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        return status == noErr
    }

    func destroy() {
        AudioHardwareDestroyProcessTap(id)
    }
}

enum AggregateDevice {
    struct SubDevice {
        let uid: String
        let driftCompensation: Bool
    }

    /// Creates a private aggregate device (visible only to this process, removed automatically if we die).
    static func create(name: String, uid: String, mainSubDeviceUID: String, subDevices: [SubDevice], tapUUIDs: [UUID]) throws -> AudioObjectID {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: mainSubDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices.map {
                [kAudioSubDeviceUIDKey: $0.uid, kAudioSubDeviceDriftCompensationKey: $0.driftCompensation] as [String: Any]
            },
        ]
        if !tapUUIDs.isEmpty {
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = tapUUIDs.map {
                [kAudioSubTapUIDKey: $0.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]
            }
        }
        var deviceID = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "Create aggregate device")
        return deviceID
    }

    static func destroy(_ id: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
