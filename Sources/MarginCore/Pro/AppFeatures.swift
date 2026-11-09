import Foundation

extension FeatureCatalog {
    static let midi: [Feature] = [
        (1, "Mod wheel", "modulation expression"), (7, "Fader", "volume level mix"),
        (10, "Pan", "stereo balance"), (11, "Expression", "swell dynamics"), (74, "Filter cutoff", "brightness synth"),
    ].map { cc, title, keywords in
        Feature(id: "midi.\(cc)", title: title, group: "MIDI", keywords: "cc controller \(cc) \(keywords)", payload: .binding(.midi(cc: cc, name: title)))
    }

    static let blender: [Feature] = {
        let live = "Blender"
        func value(_ parameter: String, _ title: String, _ keywords: String) -> Feature {
            Feature(id: "blender.\(parameter)", title: title, group: live, keywords: keywords, payload: .binding(.plugin(parameter, name: title)), usesBridge: true)
        }
        func command(_ name: String, _ title: String, _ keywords: String) -> Feature {
            Feature(id: "blender.\(name)", title: title, group: live, keywords: keywords, payload: .action(Action(.plugin, name)), usesBridge: true)
        }
        return [
            value("brush_size", "Brush radius", "sculpt paint size"),
            value("brush_strength", "Brush strength", "sculpt paint intensity"),
            value("frame", "Timeline frame", "animation scrub playhead keyframe"),
            value("subdivision_level", "Subdivision level", "subsurf modifier smooth"),
            value("viewport_orbit", "Viewport orbit", "rotate turn view camera"),
            value("viewport_zoom", "Viewport zoom", "dolly closer view"),
            value("viewport_pan", "Viewport pan", "move view up down"),
            command("xray_toggle", "X-ray", "transparent see through"),
            command("camera_view", "Camera view", "look through"),
            command("shading_cycle", "Next shading mode", "material wireframe solid"),
            command("render_preview", "Render preview", "viewport rendered"),
            command("undo", "Undo", "back revert"),
            command("redo", "Redo", "again"),
            command("toggle_edit", "Toggle Edit mode", "object mesh tab"),
            command("play", "Play animation", "timeline stop space"),
            command("render_image", "Render image", "f12"),
            command("save_file", "Save file", ""),
            command("add_menu", "Add object", "mesh menu new"),
            command("search", "Search commands", "operator find"),
            command("move", "Move", "grab translate"),
            command("rotate", "Rotate", "turn"),
            command("scale", "Scale", "resize"),
            command("extrude", "Extrude", "edit mesh"),
            command("inset", "Inset faces", "edit mesh"),
            command("delete", "Delete", "remove"),
            command("duplicate", "Duplicate", "copy"),
            command("hide", "Hide selected", ""),
            command("reveal", "Reveal hidden", "show unhide"),
            command("frame_all", "Frame all", "view fit everything"),
            command("local_view", "Local view", "isolate focus"),
            command("wireframe", "Wireframe view", "shading"),
            command("maximize", "Maximize area", "fullscreen panel"),
            command("sidebar", "Sidebar", "properties panel"),
            command("toolbar", "Toolbar", "tools panel"),
            command("proportional", "Proportional editing", "falloff"),
            command("snapping", "Snapping", "snap magnet"),
            command("next_keyframe", "Next keyframe", "jump animation"),
            command("previous_keyframe", "Previous keyframe", "jump animation"),
            command("next_frame", "Next frame", "step animation"),
            command("previous_frame", "Previous frame", "step animation"),
        ]
    }()
}
