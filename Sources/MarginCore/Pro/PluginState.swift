import Foundation

/// One value a plugin exposes. Sent back so readouts and detents show the
/// app's real numbers rather than Margin's guess at them.
public struct PluginParameter: Codable, Equatable, Sendable {
    public var value: Double
    public var min: Double
    public var max: Double
    public var unit: String
    public var integer: Bool
    /// Values worth a haptic tick, such as keyframes.
    public var detents: [Double]
    /// True when messages carry a change rather than a new value.
    public var relative: Bool

    public init(value: Double, min: Double, max: Double, unit: String = "", integer: Bool = false, detents: [Double] = [], relative: Bool = false) {
        self.value = value
        self.min = min
        self.max = max
        self.unit = unit
        self.integer = integer
        self.detents = detents
        self.relative = relative
    }

    public func format(_ number: Double) -> String {
        let text = String(format: integer ? "%.0f" : "%.2f", number)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    /// `value` as a 0...1 position, for the readout bar.
    public func fraction(_ number: Double) -> Double? {
        guard max > min else { return nil }
        return Swift.min(1, Swift.max(0, (number - min) / (max - min)))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(Double.self, forKey: .value)
        min = try c.decodeIfPresent(Double.self, forKey: .min) ?? 0
        max = try c.decodeIfPresent(Double.self, forKey: .max) ?? 1
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        integer = try c.decodeIfPresent(Bool.self, forKey: .integer) ?? false
        detents = try c.decodeIfPresent([Double].self, forKey: .detents) ?? []
        relative = try c.decodeIfPresent(Bool.self, forKey: .relative) ?? false
    }
}

/// A state report from a plugin.
public struct PluginReport: Codable, Equatable, Sendable {
    public var app: String
    public var mode: String?
    public var parameters: [String: PluginParameter]

    public init(app: String, mode: String?, parameters: [String: PluginParameter]) {
        self.app = app
        self.mode = mode
        self.parameters = parameters
    }

    public static func decode(_ data: Data) -> PluginReport? {
        try? JSONDecoder().decode(PluginReport.self, from: data)
    }
}
