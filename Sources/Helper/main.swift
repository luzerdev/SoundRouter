import Foundation
import Security

/// Privileged LaunchDaemon registered by the app through SMAppService.daemon.
/// It exposes exactly one privileged operation: restarting coreaudiod.
final class HelperService: NSObject, NSXPCListenerDelegate, SoundRouterHelperProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SoundRouterHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func version(reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    func restartCoreAudio(reply: @escaping (Bool, String?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["coreaudiod"]
        do {
            try task.run()
            task.waitUntilExit()
            reply(task.terminationStatus == 0, task.terminationStatus == 0 ? nil : "killall exited with \(task.terminationStatus)")
        } catch {
            reply(false, error.localizedDescription)
        }
    }
}

/// Only accept connections from the app that embeds us: same team, identifier = ours minus ".Helper".
func clientRequirement() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
          identifier.hasSuffix(".Helper")
    else { return nil }

    let appIdentifier = String(identifier.dropLast(".Helper".count))
    if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String {
        return "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
    return "identifier \"\(appIdentifier)\""
}

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
if let requirement = clientRequirement() {
    listener.setConnectionCodeSigningRequirement(requirement)
} else {
    NSLog("SoundRouterHelper: could not derive a client code-signing requirement; accepting any client")
}
listener.delegate = service
listener.resume()
RunLoop.main.run()
