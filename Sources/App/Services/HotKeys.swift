import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// System-wide keyboard shortcuts via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKeyCenter {
    struct Shortcut {
        let keyCode: Int
        let modifiers: Int
        let title: String
        let display: String
    }

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let signature: OSType = 0x5352_7472 // 'SRtr'

    static let hyper = controlKey | optionKey | cmdKey

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers),
                                         EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs.append(ref)
        actions[id] = action
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

/// Intercepts the keyboard's volume keys so they can drive software volume for devices macOS
/// can't control (HDMI, many USB interfaces). Needs Accessibility permission.
/// The event tap runs on the main run loop, so the handler is always called on the main thread.
final class VolumeKeyInterceptor {
    enum Key { case up, down, mute }

    /// Return true to consume the key press.
    var handler: (@MainActor (Key, _ fine: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeys: Set<Int> = []

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else {
            Self.promptForAccess()
            return false
        }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<VolumeKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA
        let key: Key
        switch keyCode {
        case 0: key = .up        // NX_KEYTYPE_SOUND_UP
        case 1: key = .down      // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute      // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }
        if !isDown {
            return swallowedKeys.remove(keyCode) != nil ? nil : Unmanaged.passUnretained(event)
        }
        let fine = nsEvent.modifierFlags.contains([.option, .shift])
        let consumed = MainActor.assumeIsolated { handler?(key, fine) ?? false }
        if consumed {
            swallowedKeys.insert(keyCode)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

/// Small on-screen volume indicator, shown when SoundRouter handles the volume keys or a hot key.
@MainActor
final class VolumeHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(title: String, level: Float?, muted: Bool, symbol: String = "speaker.wave.2.fill") {
        let view = HUDView(title: title, level: level, muted: muted, symbol: symbol)
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let size = NSSize(width: 220, height: 200)
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 140, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.panel?.animator().alphaValue = 0 }, completionHandler: nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private struct HUDView: View {
        let title: String
        let level: Float?
        let muted: Bool
        let symbol: String

        var body: some View {
            VStack(spacing: 14) {
                Image(systemName: muted ? "speaker.slash.fill" : symbol)
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.primary)
                if let level {
                    ProgressView(value: Double(muted ? 0 : min(level, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 160)
                }
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
