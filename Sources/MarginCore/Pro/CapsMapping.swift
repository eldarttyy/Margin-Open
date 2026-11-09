import Foundation

/// Reads what `hidutil property --get UserKeyMapping` prints. The table itself
/// is the only record that survives a restart or a crash, so it's what decides
/// whether the remap is on and whose it is.
public enum CapsMapping {
    public enum State: Equatable, Sendable {
        case empty
        /// Holds Margin's Caps Lock to F18 remap and nothing else.
        case margin
        /// Holds a mapping some other tool made.
        case other
    }

    /// `hidutil` prints these usages in decimal.
    static let caps = "30064771129"
    static let f18 = "30064771181"

    public static func state(of output: String) -> State {
        var found = false
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { " ;=\t".contains($0) })
            guard fields.count == 2 else { continue }
            let expected: String
            switch fields[0] {
            case "HIDKeyboardModifierMappingSrc": expected = caps
            case "HIDKeyboardModifierMappingDst": expected = f18
            default: continue
            }
            guard fields[1] == expected else { return .other }
            found = true
        }
        return found ? .margin : .empty
    }
}
