import AppKit
import CMargin
import MarginCore

/// `Margin --diagnose`: reports what works on this Mac, then logs touches for
/// a few seconds. This is the check that private-API assumptions still hold.
enum Diagnose {
    private nonisolated(unsafe) static var frames = 0
    private nonisolated(unsafe) static var maxMajor = 0.0
    private nonisolated(unsafe) static var lastPrint = 0.0
    private nonisolated(unsafe) static var outOfRange = 0

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "unavailable"
    }

    private static func frame(_ touches: UnsafePointer<MRTouch>?, _ count: Int) {
        frames += 1
        guard let touches else { return }
        for i in 0..<count {
            let t = touches[i]
            maxMajor = max(maxMajor, Double(t.majorAxis))
            let p = t.normalized.position
            if p.x < -0.01 || p.x > 1.01 || p.y < -0.01 || p.y > 1.01 { outOfRange += 1 }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPrint > 0.15 {
                lastPrint = now
                print(String(format: "  id %d state %d  x %.3f y %.3f  major %.1f minor %.1f  size %.2f density %.2f", t.identifier, t.state, p.x, p.y, t.majorAxis, t.minorAxis, t.size, t.density))
            }
        }
    }

    static func run() {
        print("frameworks loaded:   \(MRLoad())")
        print("accessibility:       \(AXIsProcessTrusted())")
        print("output volume:       \(format(Audio.volume(input: false)))  muted: \(String(describing: Audio.isMuted(input: false)))")
        print("input volume:        \(format(Audio.volume(input: true)))  muted: \(String(describing: Audio.isMuted(input: true)))")
        print("display brightness:  \(format(Display.brightness()))")
        print("keyboard backlight:  \(format(KeyboardBacklight.shared.level()))")

        // Writes each current value straight back: proves the setter, changes nothing.
        print("write-back volume:   \(Audio.volume(input: false).map { Audio.setVolume($0, input: false) } ?? false)")
        print("write-back mic:      \(Audio.volume(input: true).map { Audio.setVolume($0, input: true) } ?? false)")
        print("write-back display:  \(Display.brightness().map { Display.setBrightness($0) } ?? false)")
        print("write-back keyboard: \(KeyboardBacklight.shared.level().map { KeyboardBacklight.shared.setLevel($0) } ?? false)")

        let seconds = CommandLine.arguments.contains("--no-wait") ? 0.0 : 12.0
        let count = MRStart({ _, touches, count, _, _ in Diagnose.frame(touches, Int(count)) }, nil)
        print("multitouch devices:  \(count)")
        print("haptic:              \(MRHaptic(3))")
        guard seconds > 0 else { MRStop(); return }

        print("Move a finger around the trackpad, then rest your palm on it, for \(Int(seconds)) seconds…")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        MRStop()
        print("frames: \(frames)  largest major axis: \(String(format: "%.1f", maxMajor))  out-of-range points: \(outOfRange)")
        print(frames > 0 && outOfRange == 0 ? "Touch layout looks right." : "Touch data looks wrong, or no touches were seen.")
    }
}
