import Foundation
import MarginCore

/// Turns Caps Lock into a held modifier by remapping it to F18, a key nothing
/// uses. macOS clears this remap at restart, and `disable` clears it on quit.
/// A crash can't clear it, so Caps Lock is put back the next time Margin opens.
enum CapsLayer {
    static let f18KeyCode: Int64 = 79

    /// Runs `hidutil`, which can take a moment, off the main thread and in order.
    static let queue = DispatchQueue(label: "margin.caps", qos: .utility)

    private static let capsUsage = "0x700000039"
    private static let f18Usage = "0x70000006D"
    private static let activeKey = "capsRemapActive"

    private static func hidutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static var table: CapsMapping.State? {
        hidutil(["property", "--get", "UserKeyMapping"]).map(CapsMapping.state)
    }

    /// False when another tool already has a key mapping. Margin stays out of
    /// it, because there's only one mapping table and setting it replaces it.
    /// Checks the table itself, since a saved flag can't know about a restart.
    @discardableResult
    static func enable() -> Bool {
        switch table {
        case .margin:
            UserDefaults.standard.set(true, forKey: activeKey)
            return true
        case .empty:
            let mapping = "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(capsUsage),\"HIDKeyboardModifierMappingDst\":\(f18Usage)}]}"
            guard hidutil(["property", "--set", mapping]) != nil else { return false }
            UserDefaults.standard.set(true, forKey: activeKey)
            return true
        case .other, nil:
            return false
        }
    }

    /// Only ever clears a mapping Margin set itself, and leaves the table alone
    /// if something else has added to it since.
    static func disable() {
        guard UserDefaults.standard.bool(forKey: activeKey) else { return }
        if table == .margin { _ = hidutil(["property", "--set", "{\"UserKeyMapping\":[]}"]) }
        UserDefaults.standard.set(false, forKey: activeKey)
    }
}
