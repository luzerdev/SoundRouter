import Foundation

/// Shared between the app and the privileged helper daemon.
enum HelperConstants {
    static let machServiceName = "app.soundrouter.helper"
    static let daemonPlistName = "app.soundrouter.helper.plist"
    static let agentPlistName = "app.soundrouter.keepalive.plist"
    static let version = "1"
}

@objc protocol SoundRouterHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Kills coreaudiod; launchd restarts it immediately.
    func restartCoreAudio(reply: @escaping (Bool, String?) -> Void)
}
