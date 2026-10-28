import CoreMediaIO
import Foundation

/// Does what the "Enable" button in Audio MIDI Setup's iOS Device Browser does: lets CoreMediaIO
/// publish wired (and optionally wireless) iPhones/iPads, whose audio then shows up as a Core Audio
/// input device. The setting lives as long as this process, which is why SoundRouter keeps running.
enum IOSDeviceEnabler {
    static func enable(wireless: Bool = false) {
        set(kCMIOHardwarePropertyAllowScreenCaptureDevices, true)
        if wireless {
            set(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, true)
        }
    }

    static func disable() {
        set(kCMIOHardwarePropertyAllowScreenCaptureDevices, false)
        set(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, false)
    }

    static var isEnabled: Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr && value != 0
    }

    private static func set<Selector: BinaryInteger>(_ selector: Selector, _ on: Bool) {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value: UInt32 = on ? 1 : 0
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
