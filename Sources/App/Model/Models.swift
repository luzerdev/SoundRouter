import Foundation

/// A saved reference to an audio device. Matched by UID (stable across reboots); the name is for display
/// while the device is disconnected.
struct DeviceRef: Codable, Hashable, Identifiable {
    var uid: String
    var name: String
    var id: String { uid }

    static let systemDefaultUID = "__system_default__"
    static let systemDefault = DeviceRef(uid: systemDefaultUID, name: "System Default")
    var isSystemDefault: Bool { uid == Self.systemDefaultUID }
}

struct AUEffectConfig: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var manufacturerName: String
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var bypassed = false
    /// `AUAudioUnit.fullState`, serialized as a binary plist.
    var state: Data?
}

struct EffectSettings: Codable, Hashable {
    /// Linear gain, 0...4 (400% boost).
    var volume: Float = 1
    var muted = false
    /// -1 (left) ... 1 (right)
    var balance: Float = 0
    var eqEnabled = false
    var eqBands: [Float] = Array(repeating: 0, count: GraphicEQ.frequencies.count)
    var eqPresetName: String?
    /// 0 = off, 1 = maximum. Compressor + makeup gain to lift quiet audio.
    var magicBoost: Float = 0
    var audioUnits: [AUEffectConfig] = []

    /// Neutral settings need no processing, so an app routed to the system default can be left alone.
    var isNeutral: Bool {
        volume == 1 && !muted && balance == 0 && (!eqEnabled || eqBands.allSatisfy { $0 == 0 })
            && magicBoost == 0 && audioUnits.allSatisfy(\.bypassed)
    }
}

struct EQPreset: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var bands: [Float]

    static let builtIn: [EQPreset] = [
        .init(name: "Flat", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(name: "Bass Boost", bands: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        .init(name: "Bass Reducer", bands: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        .init(name: "Treble Boost", bands: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        .init(name: "Voice", bands: [-4, -3, -1, 1, 3, 4, 4, 3, 1, 0]),
        .init(name: "Loudness", bands: [5, 4, 2, 0, -1, 0, 0, 2, 4, 5]),
        .init(name: "Headphones", bands: [3, 2, 1, 0, 0, -1, -1, 1, 2, 2]),
        .init(name: "Small Speakers", bands: [-6, -3, 3, 4, 2, 0, 0, 1, 2, 1]),
        .init(name: "Late Night", bands: [-4, -3, -1, 0, 1, 2, 2, 1, 0, -1]),
    ]
}

enum FallbackAction: String, Codable, CaseIterable, Identifiable {
    /// Don't touch the app: it plays wherever macOS sends it.
    case keepOriginal
    /// Send it to another device instead.
    case useDevice
    /// Mute it until a preferred output comes back.
    case silence

    var id: String { rawValue }
    var label: String {
        switch self {
        case .keepOriginal: "Leave on current output"
        case .useDevice: "Use another device"
        case .silence: "Silence"
        }
    }
}

/// What to do when none of a route's preferred outputs is connected.
struct Fallback: Codable, Hashable {
    var action: FallbackAction = .useDevice
    var device: DeviceRef = .systemDefault
    var alert = true
}

struct AppRoute: Codable, Hashable, Identifiable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var enabled = true
    /// In priority order. The first connected one is used (or all connected ones when `playOnAll`).
    var outputs: [DeviceRef] = [.systemDefault]
    var playOnAll = false
    var effects = EffectSettings()
    var fallback = Fallback()

    /// True when the route does nothing that macOS wouldn't already do.
    var isPassthrough: Bool {
        outputs == [.systemDefault] && effects.isNeutral
    }
}

struct InputRoute: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var enabled = true
    var input: DeviceRef
    /// Zero-based first input channel to read.
    var channelOffset = 0
    var mono = false
    var outputs: [DeviceRef] = [.systemDefault]
    var playOnAll = false
    var effects = EffectSettings()
    var fallback = Fallback()
}

/// Auto-switch the system default devices to the highest-priority connected one.
struct DevicePriority: Codable, Hashable {
    var autoSwitchOutput = false
    var outputs: [DeviceRef] = []
    var autoSwitchInput = false
    var inputs: [DeviceRef] = []
    var alertWhenSwitching = true
}

struct Profile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var appRoutes: [AppRoute] = []
    var inputRoutes: [InputRoute] = []
    var devicePriority = DevicePriority()
}

enum RuleTrigger: Codable, Hashable {
    case deviceConnected(DeviceRef)
    case deviceDisconnected(DeviceRef)
    case appLaunched(bundleID: String, name: String)
    case appQuit(bundleID: String, name: String)

    var label: String {
        switch self {
        case .deviceConnected(let d): "When \(d.name) connects"
        case .deviceDisconnected(let d): "When \(d.name) disconnects"
        case .appLaunched(_, let name): "When \(name) launches"
        case .appQuit(_, let name): "When \(name) quits"
        }
    }
}

enum RuleAction: Codable, Hashable {
    case setDefaultOutput(DeviceRef)
    case setDefaultInput(DeviceRef)
    case setSoundEffectsOutput(DeviceRef)
    case setDeviceVolume(DeviceRef, Float)
    case activateProfile(UUID)
    case enableInputRoute(UUID, Bool)
    case enableAppRoute(UUID, Bool)
    case notify(String)
}

struct Rule: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var enabled = true
    var trigger: RuleTrigger
    var actions: [RuleAction] = []
}

enum LaunchMode: String, Codable, CaseIterable, Identifiable {
    case manual, atLogin, alwaysOn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Don't start automatically"
        case .atLogin: "Start at login"
        case .alwaysOn: "Always on (start at login, relaunch if it crashes)"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var showDockIcon = true
    var launchMode: LaunchMode = .manual
    /// Route every app that has no explicit route through SoundRouter too, so output effects
    /// (headphone EQ, software volume) apply to all audio.
    var processAllAudio = false
    /// Handle the keyboard volume keys in software for outputs that have no hardware volume.
    var softwareVolumeKeys = false
    /// Publish wired iPads/iPhones as audio devices (what Audio MIDI Setup's "Enable" does).
    var enableIOSDevices = false
    var globalHotKeys = true
    var notifications = true
    var runRulesAtLaunch = true
}

struct AppConfig: Codable, Hashable {
    var version = 1
    var profiles: [Profile] = [Profile(name: "Default")]
    var activeProfileID: UUID?
    var rules: [Rule] = []
    /// Per-output-device effects (headphone EQ, software master volume), keyed by device UID.
    var outputEffects: [String: EffectSettings] = [:]
    var customEQPresets: [EQPreset] = []
    var settings = AppSettings()
}
