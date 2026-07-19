import Foundation
import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// CGEventTap-based interceptor for bindings that must swallow the key event.
final class HotkeyInterceptor: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var suppressed: [SuppressedChord] = []

    var onSuppressedBinding: ((UUID) -> Void)?

    private struct SuppressedChord {
        let bindingID: UUID
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    func updateSuppressedBindings(_ bindings: [ShortcutBinding]) {
        lock.lock()
        defer { lock.unlock() }
        suppressed = bindings.compactMap { binding in
            guard binding.requiresSuppression else { return nil }
            guard let shortcut = KeyboardShortcuts.getShortcut(for: .binding(binding.id)) else { return nil }
            return SuppressedChord(
                bindingID: binding.id,
                keyCode: UInt16(shortcut.carbonKeyCode),
                modifiers: shortcut.modifiers.intersection([.command, .shift, .option, .control])
            )
        }
    }

    func start() {
        guard eventTap == nil else { return }

        let mask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let refcon = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let interceptor = Unmanaged<HotkeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Unmanaged<HotkeyInterceptor>.fromOpaque(refcon).release()
            NSLog("MacV: failed to create CGEventTap — grant Input Monitoring permission")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reenableTap),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    @objc private func reenableTap() {
        guard let tap = eventTap else {
            start()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let mods = Self.normalizedModifiers(flags)

        lock.lock()
        let match = suppressed.first { chord in
            chord.keyCode == keyCode && chord.modifiers == mods
        }
        lock.unlock()

        guard let match else {
            return Unmanaged.passUnretained(event)
        }

        // Swallow both keyDown and keyUp. Dispatch only on keyDown.
        if type == .keyDown {
            let bindingID = match.bindingID
            DispatchQueue.main.async { [weak self] in
                self?.onSuppressedBinding?(bindingID)
            }
        }
        return nil
    }

    private static func normalizedModifiers(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result.intersection([.command, .shift, .option, .control])
    }
}
