import AppKit
import CoreAudio
import Foundation
import Observation

struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    /// The app this process belongs to (helpers like "Google Chrome Helper" or WebKit's WebContent
    /// are attributed to the app responsible for them).
    let appBundleID: String
}

struct AudioApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    var processes: [AudioProcess]
    var isPlaying: Bool

    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

/// `responsibility_get_pid_responsible_for_pid` is what Activity Monitor uses to group helper
/// processes with their app. It is not in a public header, so resolve it dynamically.
private let responsiblePID: ResponsiblePIDFunction? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
}()

/// Tracks which processes have Core Audio process objects (i.e. use audio) and groups them by app.
@MainActor
@Observable
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []

    @ObservationIgnored var onAudioProcessesChanged: (() -> Void)?
    @ObservationIgnored var onAppLaunched: ((String, String) -> Void)?
    @ObservationIgnored var onAppTerminated: ((String, String) -> Void)?

    @ObservationIgnored private var listener: PropertyListener?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    @ObservationIgnored private let ownBundleID = Bundle.main.bundleIdentifier ?? ""
    @ObservationIgnored private var nameCache: [String: String] = [:]

    init() {
        refresh()
        listener = PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onAudioProcessesChanged?()
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            let name = app.localizedName ?? bundleID
            MainActor.assumeIsolated { self?.onAppLaunched?(bundleID, name) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            let name = app.localizedName ?? bundleID
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onAppTerminated?(bundleID, name)
            }
        })

        // "Is playing" isn't covered by the process-list notification; poll it cheaply.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayingState() }
        }
    }

    var ownProcessObject: AudioObjectID { CA.processObject(for: ownPID) }

    func app(bundleID: String) -> AudioApp? { apps.first { $0.bundleID == bundleID } }

    func processObjects(forApp bundleID: String) -> [AudioObjectID] {
        app(bundleID: bundleID)?.processes.map(\.objectID) ?? []
    }

    func refresh() {
        let objects = CA.array(.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        var grouped: [String: [AudioProcess]] = [:]
        for object in objects {
            guard let pid = try? CA.get(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0, pid != ownPID else { continue }
            let bundleID = CA.string(object, kAudioProcessPropertyBundleID) ?? ""
            let appBundleID = owningAppBundleID(pid: pid, fallback: bundleID)
            guard !appBundleID.isEmpty, appBundleID != ownBundleID else { continue }
            grouped[appBundleID, default: []].append(AudioProcess(objectID: object, pid: pid, bundleID: bundleID, appBundleID: appBundleID))
        }

        let newApps = grouped.map { bundleID, processes in
            AudioApp(bundleID: bundleID, name: displayName(for: bundleID, pid: processes.first?.pid),
                     processes: processes, isPlaying: processes.contains { Self.isRunningOutput($0.objectID) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if newApps != apps { apps = newApps }
    }

    private func refreshPlayingState() {
        var changed = false
        var updated = apps
        for index in updated.indices {
            let playing = updated[index].processes.contains { Self.isRunningOutput($0.objectID) }
            if playing != updated[index].isPlaying {
                updated[index].isPlaying = playing
                changed = true
            }
        }
        if changed { apps = updated }
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        ((try? CA.get(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
    }

    private func owningAppBundleID(pid: pid_t, fallback: String) -> String {
        if let responsiblePID {
            let owner = responsiblePID(pid)
            if owner > 0, let id = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier {
                return id
            }
        }
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return id }
        return fallback
    }

    private func displayName(for bundleID: String, pid: pid_t?) -> String {
        if let cached = nameCache[bundleID] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) }
            ?? bundleID
        let clean = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        nameCache[bundleID] = clean
        return clean
    }
}
