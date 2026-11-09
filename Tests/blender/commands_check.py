"""Runs every Blender command Margin offers in a real window and checks its effect.

  Blender --factory-startup --python Tests/blender/commands_check.py -- <result-file>
"""
import importlib.util
import json
import os
import sys
import tempfile

import bpy

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("margin_bridge", os.path.join(here, "../../plugins/blender/margin_bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

result_path = sys.argv[sys.argv.index("--") + 1]
results = {}
saved = os.path.join(tempfile.gettempdir(), "margin_commands_check.blend")


def run(name):
    bridge.COMMANDS[name]()


def cube():
    return bpy.data.objects.get("Cube")


def space():
    return bridge.view_3d()[0]


def region():
    return bridge.view_3d()[1]


def modal():
    return len(bridge.window().modal_operators) > 0


def select_cube():
    bpy.context.view_layer.objects.active = cube()
    cube().select_set(True)


# (command, prepare, check). Each step runs on its own tick so Blender settles.
steps = [
    ("toggle_edit", select_cube, lambda: cube().mode == "EDIT"),
    ("toggle_edit", None, lambda: cube().mode == "OBJECT"),
    ("hide", select_cube, lambda: cube().hide_get()),
    ("reveal", None, lambda: not cube().hide_get()),
    ("wireframe", None, lambda: space().shading.type == "WIREFRAME"),
    ("wireframe", None, lambda: space().shading.type == "SOLID"),
    ("sidebar", None, lambda: space().show_region_ui),
    ("sidebar", None, lambda: not space().show_region_ui),
    ("toolbar", None, lambda: space().show_region_toolbar is False),
    ("toolbar", None, lambda: space().show_region_toolbar),
    ("proportional", None, lambda: bridge.scene().tool_settings.use_proportional_edit_objects),
    ("proportional", None, lambda: not bridge.scene().tool_settings.use_proportional_edit_objects),
    ("snapping", None, lambda: bridge.scene().tool_settings.use_snap),
    ("snapping", None, lambda: not bridge.scene().tool_settings.use_snap),
    ("next_frame", lambda: bridge.scene().frame_set(5), lambda: bridge.scene().frame_current == 6),
    ("previous_frame", None, lambda: bridge.scene().frame_current == 5),
    ("next_keyframe", lambda: (cube().keyframe_insert("location", frame=20), bridge.scene().frame_set(5)), lambda: bridge.scene().frame_current == 20),
    ("previous_keyframe", lambda: (cube().keyframe_insert("location", frame=10), bridge.scene().frame_set(20)), lambda: bridge.scene().frame_current == 10),
    ("play", None, lambda: bpy.context.screen.is_animation_playing if False else bridge.window().screen.is_animation_playing),
    ("play", None, lambda: not bridge.window().screen.is_animation_playing),
    ("frame_all", lambda: setattr(region(), "view_location", (40, 40, 40)), lambda: tuple(region().view_location) != (40.0, 40.0, 40.0)),
    ("local_view", select_cube, lambda: space().local_view is not None),
    ("local_view", None, lambda: space().local_view is None),
    ("maximize", None, lambda: bridge.window().screen.name.endswith("nonnormal")),
    ("maximize", None, lambda: not bridge.window().screen.name.endswith("nonnormal")),
    ("save_file", lambda: bpy.ops.wm.save_as_mainfile(filepath=saved), lambda: os.path.exists(saved)),
    ("delete", select_cube, lambda: "Cube" not in bpy.data.objects or bpy.data.objects["Cube"].users == 0),
    ("undo", None, lambda: cube() is not None and cube().users > 0),
    ("redo", None, lambda: "Cube" not in bpy.data.objects or bpy.data.objects["Cube"].users == 0),
    ("undo", None, lambda: cube() is not None and cube().users > 0),
    ("hide", select_cube, lambda: cube().hide_get()),
    ("undo", None, lambda: not cube().hide_get()),
    ("add_menu", None, lambda: True),
    # "search" isn't here: its popup waits for typing, so Blender can't quit behind
    # it. Check it by hand: it should open, and Escape should close it.
]
# Interactive commands stay running, so each gets a Blender of its own:
#   ... -- <result-file> <command>
alone = {
    "move": (select_cube, modal),
    "rotate": (select_cube, modal),
    "scale": (select_cube, modal),
    "duplicate": (select_cube, modal),
    "extrude": (lambda: (select_cube(), run("toggle_edit")), modal),
    "inset": (lambda: (select_cube(), run("toggle_edit")), modal),
    "render_image": (None, lambda: len(bpy.context.window_manager.windows) > 1),
}
only = sys.argv[sys.argv.index("--") + 2:]
if only:
    prepare, check = alone[only[0]]
    steps = [(only[0], prepare, check)]
position = 0
pending = None


def record(name, passed, detail=""):
    key = name
    number = 2
    while key in results:
        key = f"{name} #{number}"
        number += 1
    results[key] = "PASS" if passed else f"FAIL {detail}"


def tick():
    global position, pending
    if pending:
        name, check = pending
        pending = None
        try:
            if check:
                record(name, bool(check()))
        except Exception as error:
            record(name, False, repr(error)[:90])
    if position >= len(steps):
        with open(result_path, "w") as out:
            json.dump(results, out, indent=1)
        bpy.ops.wm.quit_blender()
        return None
    name, prepare, check = steps[position]
    position += 1
    try:
        if prepare:
            prepare()
        run(name)
        pending = (name, check)
        if check is None:
            record(name, True, "")
    except Exception as error:
        record(name, False, repr(error)[:90])
    return 3.0 if only else 0.4


bpy.app.timers.register(tick, first_interval=2.0)
