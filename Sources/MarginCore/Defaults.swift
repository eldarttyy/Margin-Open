import Foundation

public extension MarginConfig {
    /// The system layer: what the edges do with no app-specific meaning. The
    /// bottom edge and bottom corners stay off because that's where palms rest.
    static var standard: MarginConfig {
        let base = Profile(name: "Default", bindings: [
            .leftEdge: .slider(.brightness),
            .rightEdge: .slider(.volume),
            .topEdge: .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25),
            .topLeft: .buttons(tap: Action(.toggleMic)),
            .topRight: .buttons(tap: Action(.playPause), hold: Action(.toggleMute)),
        ])
        return MarginConfig(base: base)
    }
}

/// The panel's plain switches, each mapped onto the base profile's bindings so
/// they stay in step with anything edited in full Settings.
public extension MarginConfig {
    var quickMute: Bool {
        get { base[.topRight]?.hold.kind == .toggleMute }
        set {
            var binding = base[.topRight] ?? .buttons()
            binding.mode = .buttons
            binding.hold = newValue ? Action(.toggleMute) : Action()
            base[.topRight] = binding
        }
    }

    var tapToPlay: Bool {
        get { base[.topRight]?.tap.kind == .playPause }
        set {
            var binding = base[.topRight] ?? .buttons()
            binding.mode = .buttons
            binding.tap = newValue ? Action(.playPause) : Action()
            base[.topRight] = binding
        }
    }

    var mediaStrip: Bool {
        get { base[.topEdge]?.mode == .stepper && base[.topEdge]?.forward.kind == .nextTrack }
        set {
            base[.topEdge] = newValue
                ? .stepper(forward: Action(.nextTrack), backward: Action(.previousTrack), step: 0.25)
                : ZoneBinding(mode: .off)
        }
    }

    var swapSides: Bool {
        get { base[.leftEdge]?.slider == .volume && base[.rightEdge]?.slider == .brightness }
        set {
            guard newValue != swapSides else { return }
            let left = base[.leftEdge]
            base[.leftEdge] = base[.rightEdge]
            base[.rightEdge] = left
        }
    }

    var sensitivity: Double {
        get { base[.rightEdge]?.sensitivity ?? ZoneBinding().sensitivity }
        set {
            for zone in [ZoneID.leftEdge, .rightEdge] { base[zone]?.sensitivity = newValue }
        }
    }
}
