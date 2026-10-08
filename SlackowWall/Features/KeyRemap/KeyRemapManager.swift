//
//  KeyRemapManager.swift
//  SlackowWall
//

import AppKit
import Combine
import CoreGraphics

/// Rewrites key presses system-wide (or only in Minecraft) using a CGEvent tap,
/// so pressing one key sends another, e.g. A → O.
final class KeyRemapManager {
    static let shared = KeyRemapManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var settingsObserver: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    private var retryTimer: Timer?
    private var loggedTapFailure = false
    private var requestedInputMonitoring = false

    /// Keyboard event taps need both Accessibility and Input Monitoring.
    static var hasPermissions: Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    /// from-key → to-key, rebuilt whenever settings change.
    private var mapping: [KeyCode: KeyCode] = [:]
    private var onlyInMinecraft = true

    /// Keys currently held down and the key they were sent as, so the key-up
    /// always matches the key-down even if settings or focus change mid-press.
    private var heldKeys: [KeyCode: KeyCode] = [:]

    private var minecraftPIDs: [pid_t: Bool] = [:]
    private var frontmostIsMinecraft = false

    private init() {}

    func start() {
        settingsObserver = Settings.shared.$preferences
            .map(\.remap)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateFrontmost(app)
        }
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    private func apply(_ section: Preferences.RemapSection) {
        mapping = [:]
        for remap in section.remaps where remap.isValid {
            if let from = remap.from, let to = remap.to, mapping[from] == nil {
                mapping[from] = to
            }
        }
        onlyInMinecraft = section.onlyInMinecraft

        if section.enabled && !mapping.isEmpty {
            startTap()
        } else {
            stopTap()
        }
        updateRetryTimer(wanted: section.enabled && !mapping.isEmpty)
    }

    /// If the tap couldn't be created (usually Accessibility permission not granted yet),
    /// keep trying so remapping starts as soon as permission is given, without a restart.
    private func updateRetryTimer(wanted: Bool) {
        guard wanted && eventTap == nil else {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, Self.hasPermissions else { return }
            startTap()
            updateRetryTimer(wanted: true)
        }
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier else {
            frontmostIsMinecraft = false
            return
        }
        if let cached = minecraftPIDs[pid] {
            frontmostIsMinecraft = cached
            return
        }
        let args = Utilities.processArguments(pid: pid) ?? []
        let isMinecraft = ["net.minecraft.client.main.Main", "-Djava.library.path="]
            .contains { marker in args.contains { $0.contains(marker) } }
        minecraftPIDs[pid] = isMinecraft
        frontmostIsMinecraft = isMinecraft
    }

    // MARK: - Event tap

    private func startTap() {
        guard eventTap == nil else { return }

        let eventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<KeyRemapManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            if !loggedTapFailure {
                loggedTapFailure = true
                LogManager.shared.appendLog(
                    "Key Remap: failed to create event tap. Accessibility:", AXIsProcessTrusted(),
                    "Input Monitoring:", CGPreflightListenEventAccess())
            }
            // Shows the system prompt and adds SlackowWall to the Input Monitoring list.
            if !CGPreflightListenEventAccess() && !requestedInputMonitoring {
                requestedInputMonitoring = true
                CGRequestListenEventAccess()
            }
            return
        }
        loggedTapFailure = false

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        LogManager.shared.appendLog("Key Remap: enabled with \(mapping.count) remap(s)")
    }

    private func stopTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFMachPortInvalidate(eventTap)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        self.runLoopSource = nil
        heldKeys = [:]
        LogManager.shared.appendLog("Key Remap: disabled")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns off taps that are slow or interrupted; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = KeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = type == .keyDown

        let target: KeyCode?
        if isDown {
            target = shouldRemap ? mapping[keyCode] : nil
            if let target {
                heldKeys[keyCode] = target
            }
        } else {
            target = heldKeys.removeValue(forKey: keyCode)
        }

        guard let target,
            let remapped = CGEvent(
                keyboardEventSource: CGEventSource(event: event), virtualKey: target,
                keyDown: isDown)
        else {
            return Unmanaged.passUnretained(event)
        }

        remapped.flags = event.flags
        remapped.setIntegerValueField(
            .keyboardEventAutorepeat, value: event.getIntegerValueField(.keyboardEventAutorepeat))
        return Unmanaged.passRetained(remapped)
    }

    private var shouldRemap: Bool {
        // Never remap while typing in SlackowWall's own settings, so keys can be recorded.
        if NSApp.isActive,
            NSApp.keyWindow?.identifier?.rawValue.hasPrefix(SWWindowID.settings.rawValue) == true
        {
            return false
        }
        return !onlyInMinecraft || frontmostIsMinecraft
    }
}
