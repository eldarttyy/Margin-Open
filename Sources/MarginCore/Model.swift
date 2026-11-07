import Foundation

/// A region of the trackpad that can carry a binding.
public enum ZoneID: String, Codable, CaseIterable, Sendable {
    case leftEdge, rightEdge, topEdge, bottomEdge
    case topLeft, topRight, bottomLeft, bottomRight

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    /// Left and right edges slide along Y, top and bottom along X.
    public var slidesVertically: Bool { self == .leftEdge || self == .rightEdge }

    public var title: String {
        switch self {
        case .leftEdge: return "Left edge"
        case .rightEdge: return "Right edge"
        case .topEdge: return "Top edge"
        case .bottomEdge: return "Bottom edge"
        case .topLeft: return "Top-left corner"
        case .topRight: return "Top-right corner"
        case .bottomLeft: return "Bottom-left corner"
        case .bottomRight: return "Bottom-right corner"
        }
    }
}

public enum BindingMode: String, Codable, CaseIterable, Sendable {
    case off
    case slider     // edge: continuous value
    case stepper    // edge: fires an action per detent of travel
    case buttons    // corner: tap, double-tap and hold actions
    case semantic   // edge: a meaning, resolved against the app in front
}

public enum SliderTarget: String, Codable, CaseIterable, Sendable {
    case volume, micVolume, brightness, keyboardBacklight, scroll, shell, plugin, midi

    public var title: String {
        switch self {
        case .volume: return "Output volume"
        case .micVolume: return "Microphone level"
        case .brightness: return "Display brightness"
        case .keyboardBacklight: return "Keyboard backlight"
        case .scroll: return "Scroll"
        case .shell: return "Custom command"
        case .plugin: return "App plugin value"
        case .midi: return "MIDI controller"
        }
    }
}

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case none, playPause, nextTrack, previousTrack, toggleMute, toggleMic
    case keyCombo, menuItem, shell, shortcut, openApp, openURL, plugin

    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .playPause: return "Play / pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .toggleMute: return "Mute output"
        case .toggleMic: return "Mute microphone"
        case .keyCombo: return "Key combination"
        case .menuItem: return "Menu command"
        case .shell: return "Shell command"
        case .shortcut: return "Run Shortcut"
        case .openApp: return "Open app"
        case .openURL: return "Open URL"
        case .plugin: return "App plugin command"
        }
    }

    public var valueHint: String? {
        switch self {
        case .keyCombo: return "cmd+shift+]"
        case .menuItem: return "View > Zoom In"
        case .shell: return "say hello"
        case .shortcut: return "Shortcut name"
        case .openApp: return "Raycast"
        case .openURL: return "https://example.com"
        case .plugin: return "xray_toggle"
        default: return nil
        }
    }
}

public struct Action: Codable, Equatable, Sendable {
    public var kind: ActionKind
    public var value: String

    public init(_ kind: ActionKind = .none, _ value: String = "") {
        self.kind = kind
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lenient(ActionKind.self, forKey: .kind) ?? .none
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    /// The link for `.openURL`. A `file:` link would run whatever it points at,
    /// and no gesture needs one when opening an app is its own action.
    public var openableURL: URL? {
        guard kind == .openURL, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme != "file" else { return nil }
        return url
    }

    /// False for a name that the command it's passed to would read as an option.
    public var isSafeArgument: Bool { !value.isEmpty && !value.hasPrefix("-") }
}

/// Everything a zone can do. Fields not used by `mode` are kept, so switching
/// modes back and forth in the UI doesn't lose what was typed.
public struct ZoneBinding: Codable, Equatable, Sendable {
    public var mode: BindingMode = .off
    public var slider: SliderTarget = .volume
    /// Run for a `.shell` slider, with the 0...1 value in `$VALUE`.
    public var command: String = ""
    /// 1.0 maps the full length of the pad to the full range of the value.
    public var sensitivity: Double = 1.4
    public var invert: Bool = false
    public var forward: Action = Action()
    public var backward: Action = Action()
    /// Stepper travel per detent, as a fraction of the pad.
    public var stepSize: Double = 0.15
    public var tap: Action = Action()
    public var hold: Action = Action()
    public var doubleTap: Action = Action()
    public var semantic: SemanticAction = .scroll
    /// The value a `.plugin` slider sets, such as `brush_size`.
    public var parameter: String = ""
    /// Controller number for a `.midi` slider.
    public var cc: Int = 7
    /// Overrides the generated name in readouts and cheat sheets.
    public var name: String = ""

    public init(mode: BindingMode = .off) { self.mode = mode }

    public static func semantic(_ action: SemanticAction, step: Double? = nil) -> ZoneBinding {
        var b = ZoneBinding(mode: .semantic)
        b.semantic = action
        b.stepSize = step ?? action.defaultStep
        b.sensitivity = 1.0
        return b
    }

    public static func plugin(_ parameter: String, name: String, sensitivity: Double = 1.0) -> ZoneBinding {
        var b = ZoneBinding.slider(.plugin, sensitivity: sensitivity)
        b.parameter = parameter
        b.name = name
        return b
    }

    public static func midi(cc: Int, name: String) -> ZoneBinding {
        var b = ZoneBinding.slider(.midi, sensitivity: 1.4)
        b.cc = cc
        b.name = name
        return b
    }

    /// Slides as a continuous value rather than in detents.
    public var isContinuous: Bool {
        switch mode {
        case .slider: return true
        case .semantic: return semantic.isContinuous
        default: return false
        }
    }

    /// What this binding does, for readouts and cheat sheets.
    public var label: String {
        if !name.isEmpty { return name }
        switch mode {
        case .off: return "Off"
        case .slider: return slider.title
        case .semantic: return semantic.title
        case .stepper: return forward.kind == .keyCombo ? forward.value : forward.kind.title
        case .buttons:
            return [doubleTap, tap, hold].first { $0.kind != .none }?.kind.title ?? "Off"
        }
    }

    public static func slider(_ target: SliderTarget, sensitivity: Double = 1.4, invert: Bool = false) -> ZoneBinding {
        var b = ZoneBinding(mode: .slider)
        b.slider = target
        b.sensitivity = sensitivity
        b.invert = invert
        return b
    }

    public static func stepper(forward: Action, backward: Action, step: Double = 0.15) -> ZoneBinding {
        var b = ZoneBinding(mode: .stepper)
        b.forward = forward
        b.backward = backward
        b.stepSize = step
        return b
    }

    public static func buttons(tap: Action = Action(), hold: Action = Action()) -> ZoneBinding {
        var b = ZoneBinding(mode: .buttons)
        b.tap = tap
        b.hold = hold
        return b
    }

    public var hasTap: Bool { mode == .buttons && tap.kind != .none }
    public var hasHold: Bool { mode == .buttons && hold.kind != .none }
    public var hasDoubleTap: Bool { mode == .buttons && doubleTap.kind != .none }

    public var isActive: Bool {
        switch mode {
        case .off: return false
        case .slider, .stepper, .semantic: return true
        case .buttons: return hasTap || hasHold || hasDoubleTap
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ZoneBinding()
        let decodedSlider = c.lenient(SliderTarget.self, forKey: .slider)
        let decodedSemantic = c.lenient(SemanticAction.self, forKey: .semantic)
        mode = c.lenient(BindingMode.self, forKey: .mode) ?? d.mode
        slider = decodedSlider ?? d.slider
        semantic = decodedSemantic ?? d.semantic
        // A slider or meaning this version doesn't know turns the zone off,
        // rather than quietly becoming the default volume slider.
        if (mode == .slider && decodedSlider == nil && c.contains(.slider))
            || (mode == .semantic && decodedSemantic == nil && c.contains(.semantic)) {
            mode = .off
        }
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? d.command
        // The file can be edited by hand, and a slider multiplies by this every frame.
        sensitivity = min(100, max(0, try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity))
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? d.invert
        forward = try c.decodeIfPresent(Action.self, forKey: .forward) ?? d.forward
        backward = try c.decodeIfPresent(Action.self, forKey: .backward) ?? d.backward
        stepSize = try c.decodeIfPresent(Double.self, forKey: .stepSize) ?? d.stepSize
        tap = try c.decodeIfPresent(Action.self, forKey: .tap) ?? d.tap
        hold = try c.decodeIfPresent(Action.self, forKey: .hold) ?? d.hold
        doubleTap = try c.decodeIfPresent(Action.self, forKey: .doubleTap) ?? d.doubleTap
        parameter = try c.decodeIfPresent(String.self, forKey: .parameter) ?? d.parameter
        cc = try c.decodeIfPresent(Int.self, forKey: .cc) ?? d.cc
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
    }
}

/// Gesture thresholds. Lengths are fractions of the pad.
public struct Tuning: Codable, Equatable, Sendable {
    public var edgeWidth = 0.07
    public var edgeHeight = 0.10
    public var cornerWidth = 0.12
    public var cornerHeight = 0.18
    /// A finger must rest this long before an edge takes over from the cursor.
    public var dwellMs = 80.0
    /// Movement below this counts as resting.
    public var slop = 0.012
    public var tapMaxMs = 250.0
    public var holdMs = 450.0
    /// A second tap inside this window makes a double-tap.
    public var doubleTapMs = 300.0
    /// Resting this long on an edge without sliding opens the cheat sheet.
    public var restMs = 500.0
    /// Edges ignore new touches for this long after a key press.
    public var typingGuardMs = 400.0
    /// Contacts with a longer major axis are treated as a palm.
    public var palmMajorAxis = 20.0
    /// Limits the left and right edges to the lower quarter of the pad.
    public var lowerQuarterOnly = false

    /// What Settings offers, and what a hand-edited file is held to.
    public static let edgeWidthRange = 0.03...0.15
    public static let edgeHeightRange = 0.04...0.2
    public static let cornerWidthRange = 0.06...0.25
    public static let cornerHeightRange = 0.08...0.3
    public static let dwellRange = 0.0...300
    public static let tapMaxRange = 100.0...500
    public static let holdRange = 250.0...1200
    public static let palmRange = 8.0...40
    /// Not in Settings, so these are only kept within sensible bounds.
    public static let slopRange = 0.002...0.05
    public static let doubleTapRange = 150.0...600
    public static let restRange = 200.0...3000
    public static let typingGuardRange = 0.0...2000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Tuning()
        // The file can be edited by hand, and an edge as wide as half the pad
        // would take the cursor away from ordinary use. Values outside what
        // Settings offers are pulled back into range.
        func value(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            let raw = try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
            return min(range.upperBound, max(range.lowerBound, raw))
        }
        edgeWidth = try value(.edgeWidth, d.edgeWidth, Self.edgeWidthRange)
        edgeHeight = try value(.edgeHeight, d.edgeHeight, Self.edgeHeightRange)
        cornerWidth = try value(.cornerWidth, d.cornerWidth, Self.cornerWidthRange)
        cornerHeight = try value(.cornerHeight, d.cornerHeight, Self.cornerHeightRange)
        dwellMs = try value(.dwellMs, d.dwellMs, Self.dwellRange)
        slop = try value(.slop, d.slop, Self.slopRange)
        tapMaxMs = try value(.tapMaxMs, d.tapMaxMs, Self.tapMaxRange)
        holdMs = try value(.holdMs, d.holdMs, Self.holdRange)
        doubleTapMs = try value(.doubleTapMs, d.doubleTapMs, Self.doubleTapRange)
        restMs = try value(.restMs, d.restMs, Self.restRange)
        typingGuardMs = try value(.typingGuardMs, d.typingGuardMs, Self.typingGuardRange)
        palmMajorAxis = try value(.palmMajorAxis, d.palmMajorAxis, Self.palmRange)
        lowerQuarterOnly = try c.decodeIfPresent(Bool.self, forKey: .lowerQuarterOnly) ?? d.lowerQuarterOnly
    }
}

/// A named set of bindings. App profiles only list the zones they override,
/// and can override again for a mode a plugin reports, such as Blender's Sculpt.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bundleIDs: [String]
    public var bindings: [String: ZoneBinding]
    public var modes: [String: [String: ZoneBinding]]

    public init(id: UUID = UUID(), name: String, bundleIDs: [String] = [], bindings: [ZoneID: ZoneBinding] = [:]) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        self.modes = [:]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        bindings = try c.decodeIfPresent([String: ZoneBinding].self, forKey: .bindings) ?? [:]
        modes = try c.decodeIfPresent([String: [String: ZoneBinding]].self, forKey: .modes) ?? [:]
    }

    public subscript(zone: ZoneID) -> ZoneBinding? {
        get { bindings[zone.rawValue] }
        set { bindings[zone.rawValue] = newValue }
    }

    /// The override for a zone in one mode, or in every mode when `mode` is nil.
    public subscript(zone: ZoneID, mode mode: String?) -> ZoneBinding? {
        get { mode.map { modes[$0]?[zone.rawValue] } ?? self[zone] }
        set {
            guard let mode else { return self[zone] = newValue }
            modes[mode, default: [:]][zone.rawValue] = newValue
            if modes[mode]?.isEmpty == true { modes[mode] = nil }
        }
    }
}

public enum HapticLevel: String, Codable, CaseIterable, Sendable {
    case off, light, strong

    public var title: String { rawValue.capitalized }

    /// Actuator waveforms for a detent and a confirmation. Nil means silent.
    public var actuations: (detent: Int32, confirm: Int32)? {
        switch self {
        case .off: return nil
        case .light: return (1, 3)
        case .strong: return (3, 6)
        }
    }
}

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var title: String { rawValue.capitalized }
}

public struct MarginConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var haptics = HapticLevel.light
    public var hud = true
    public var holdCursor = true
    /// Holding Shift and Option slows sliders to a quarter of their speed.
    public var fineControl = true
    /// Edges only respond while Fn or Option is held. Corners are unaffected.
    public var requireModifier = false
    public var songInMenuBar = true
    /// Layers semantic actions over the system controls. Off keeps volume and
    /// brightness on the edges in every app.
    public var smartEdges = true
    /// Holding Caps Lock switches every edge to a second layer.
    public var capsLayer = false
    public var appearance = AppearanceMode.system
    public var tuning = Tuning()
    public var base: Profile
    public var apps: [Profile]

    public init(base: Profile, apps: [Profile] = []) {
        self.base = base
        self.apps = apps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        haptics = c.lenient(HapticLevel.self, forKey: .haptics) ?? .light
        hud = try c.decodeIfPresent(Bool.self, forKey: .hud) ?? true
        holdCursor = try c.decodeIfPresent(Bool.self, forKey: .holdCursor) ?? true
        fineControl = try c.decodeIfPresent(Bool.self, forKey: .fineControl) ?? true
        requireModifier = try c.decodeIfPresent(Bool.self, forKey: .requireModifier) ?? false
        songInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .songInMenuBar) ?? true
        smartEdges = try c.decodeIfPresent(Bool.self, forKey: .smartEdges) ?? true
        capsLayer = try c.decodeIfPresent(Bool.self, forKey: .capsLayer) ?? false
        appearance = c.lenient(AppearanceMode.self, forKey: .appearance) ?? .system
        tuning = try c.decodeIfPresent(Tuning.self, forKey: .tuning) ?? Tuning()
        base = try c.decode(Profile.self, forKey: .base)
        apps = try c.decodeIfPresent([Profile].self, forKey: .apps) ?? []
    }

    public func profile(forBundleID bundleID: String?) -> Profile? {
        guard let bundleID else { return nil }
        return apps.first { $0.bundleIDs.contains(bundleID) }
    }
}

extension KeyedDecodingContainer {
    /// Nil for a missing key or a value this version doesn't know, such as a
    /// case a newer Margin added. One such value would otherwise fail the whole
    /// file, and Margin would start over from the defaults.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
