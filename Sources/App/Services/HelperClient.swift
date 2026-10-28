import AppKit
import Foundation
import Observation
import ServiceManagement

/// Installs and talks to the privileged helper daemon. Falls back to an administrator prompt when
/// the helper isn't installed, so "Restart Audio" always works.
@MainActor
@Observable
final class HelperClient {
    private(set) var status: SMAppService.Status = .notRegistered
    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)

    init() { refresh() }

    func refresh() { status = service.status }

    var statusText: String {
        switch status {
        case .enabled: "Installed"
        case .requiresApproval: "Waiting for approval in System Settings › Login Items"
        case .notRegistered: "Not installed"
        case .notFound: "Not found in app bundle"
        @unknown default: "Unknown"
        }
    }

    func install() throws {
        try service.register()
        refresh()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func uninstall() async throws {
        try await service.unregister()
        refresh()
    }

    func restartCoreAudio() async throws {
        refresh()
        if status == .enabled {
            try await restartViaHelper()
        } else {
            try restartViaAdminPrompt()
        }
    }

    private func restartViaHelper() async throws {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SoundRouterHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The error handler and the reply can both fire; resume exactly once.
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: error)
            } as? SoundRouterHelperProtocol
            guard let proxy else {
                once.resume(throwing: HelperError.unavailable)
                return
            }
            proxy.restartCoreAudio { ok, message in
                if ok { once.resume(throwing: nil) } else { once.resume(throwing: HelperError.failed(message ?? "Unknown error")) }
            }
        }
    }

    private func restartViaAdminPrompt() throws {
        let script = NSAppleScript(source: "do shell script \"/usr/bin/killall coreaudiod\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            throw HelperError.failed(error[NSAppleScript.errorMessage] as? String ?? "Cancelled")
        }
    }

    enum HelperError: LocalizedError {
        case unavailable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The helper is not available."
            case .failed(let message): message
            }
        }
    }
}

private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func resume(throwing error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

/// Start-at-login and always-on (KeepAlive LaunchAgent) registration.
@MainActor
enum LaunchService {
    private static var agent: SMAppService { SMAppService.agent(plistName: HelperConstants.agentPlistName) }

    static func apply(_ mode: LaunchMode) {
        do {
            switch mode {
            case .manual:
                try? SMAppService.mainApp.unregister()
                try? agent.unregister()
            case .atLogin:
                try? agent.unregister()
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            case .alwaysOn:
                try? SMAppService.mainApp.unregister()
                if agent.status != .enabled { try agent.register() }
            }
        } catch {
            NSLog("SoundRouter: launch registration failed: \(error)")
        }
        if SMAppService.mainApp.status == .requiresApproval || agent.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
