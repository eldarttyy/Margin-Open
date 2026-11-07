import AppKit
import AudioToolbox
import CMargin
import CoreAudio
import MarginCore

/// Volume and mute on the default devices, through public CoreAudio APIs.
enum Audio {
    private static func device(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector, input: Bool) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func volume(input: Bool) -> Double? {
        guard let id = device(input: input) else { return nil }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, input: input)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    @discardableResult
    static func setVolume(_ volume: Double, input: Bool) -> Bool {
        guard let id = device(input: input) else { return false }
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, input: input)
        var value = Float32(volume)
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func isMuted(input: Bool) -> Bool? {
        guard let id = device(input: input) else { return nil }
        var a = address(kAudioDevicePropertyMute, input: input)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, input: Bool) -> Bool {
        guard let id = device(input: input) else { return false }
        var a = address(kAudioDevicePropertyMute, input: input)
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}

enum Display {
    /// The built-in panel, or the main display on a desktop Mac.
    private static var target: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count = UInt32(0)
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static func brightness() -> Double? {
        var value = Float(0)
        return MRGetBrightness(target, &value) ? Double(value) : nil
    }

    @discardableResult
    static func setBrightness(_ value: Double) -> Bool {
        MRSetBrightness(target, Float(value))
    }
}

/// The keyboard backlight, reached through CoreBrightness's private client class.
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    private let client: NSObject?
    private let keyboard: UInt64

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            client = nil
            keyboard = 0
            return
        }
        let instance = type.init()
        let ids = instance.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        client = instance
        keyboard = ids?.first?.uint64Value ?? 1
    }

    func level() -> Double? {
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard let client, client.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let get = unsafeBitCast(client.method(for: selector), to: Getter.self)
        return Double(get(client, selector, keyboard))
    }

    @discardableResult
    func setLevel(_ level: Double) -> Bool {
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, client.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let set = unsafeBitCast(client.method(for: selector), to: Setter.self)
        return set(client, selector, Float(level), keyboard)
    }
}

/// Synthesized input. Posting events needs the Accessibility permission.
enum Input {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Sends a shortcut to one app whichever window has focus. Keys posted to the
    /// system event stream are ignored by some apps, so naming the app is safer.
    static func post(_ combo: KeyCombo, to pid: pid_t = 0) {
        var flags: CGEventFlags = []
        if combo.command { flags.insert(.maskCommand) }
        if combo.shift { flags.insert(.maskShift) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.control { flags.insert(.maskControl) }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down)
            event?.flags = flags
            if pid != 0 {
                event?.postToPid(pid)
            } else {
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    enum MediaKey: Int { case play = 16, next = 17, previous = 18 }

    static func post(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: key.rawValue << 16 | state << 8,
                data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func scroll(pixels: Int32, vertical: Bool) {
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: vertical ? pixels : 0,
            wheel2: vertical ? 0 : pixels,
            wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }
}

enum Haptics {
    static func play(_ actuation: Int32) {
        if !MRHaptic(actuation) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

/// What this Mac has, so nothing is offered that can't work on it.
enum Hardware {
    /// Feature ids to leave out. Checked once, off the main thread.
    static let missingFeatures: Set<String> = {
        var missing: Set<String> = []
        if Audio.volume(input: true) == nil { missing.formUnion(["system.micVolume", "system.toggleMic"]) }
        if Display.brightness() == nil { missing.insert("system.brightness") }
        if KeyboardBacklight.shared.level() == nil { missing.insert("system.keyboardBacklight") }
        return missing
    }()
}
