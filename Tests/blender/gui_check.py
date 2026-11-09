"""Checks the parts background mode can't reach: the real timer loop and a real
viewport. Opens a factory-settings window, checks itself and quits.

  Blender --factory-startup --python Tests/blender/gui_check.py -- <result-file>
"""
import importlib.util
import json
import os
import socket
import sys
import time

import bpy

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("margin_bridge", os.path.join(here, "../../plugins/blender/margin_bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
# Separate ports, so this can run beside a real Blender and Margin.
bridge.LISTEN_PORT, bridge.REPORT_PORT = 52020, 52021
bridge.load_key = lambda: None
bridge.key = b"test-key"

result_path = sys.argv[sys.argv.index("--") + 1]
out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
results = {}
steps = []


def send(text):
    body = f"{int(time.time() * 1000)} {text}".encode()
    out.sendto(bridge.sign(body) + b" " + body, ("127.0.0.1", bridge.LISTEN_PORT))


def step(fn):
    steps.append(fn)
    return fn


@step
def start():
    space, region = bridge.view_3d()
    results["viewport_found"] = space is not None
    window = bridge.window()
    results["modal_operators_available"] = hasattr(window, "modal_operators")
    results["mode"] = bridge.mode()
    results["xray_before"] = space.shading.show_xray
    results["view_before"] = region.view_perspective
    results["shading_before"] = space.shading.type
    results["rotation_before"] = list(region.view_rotation)
    results["distance_before"] = region.view_distance
    results["location_before"] = list(region.view_location)
    send("frame 33")
    send("xray_toggle 1")
    send("camera_view 1")
    send("shading_cycle 1")
    send("viewport_orbit 0.1")
    send("viewport_zoom 0.1")
    send("viewport_pan 0.1")


@step
def verify():
    space, region = bridge.view_3d()
    results["timer_applied_frame"] = bridge.scene().frame_current == 33
    results["xray_toggled"] = space.shading.show_xray != results["xray_before"]
    results["camera_toggled"] = region.view_perspective != results["view_before"]
    results["shading_cycled"] = space.shading.type != results["shading_before"]
    results["orbit_moved"] = list(region.view_rotation) != results["rotation_before"]
    results["zoom_moved_closer"] = region.view_distance < results["distance_before"]
    results["pan_moved"] = list(region.view_location) != results["location_before"]
    send("render_preview 1")


@step
def verify_render():
    space, _ = bridge.view_3d()
    results["render_preview_toggled"] = space.shading.type == "RENDERED"
    space.shading.type = "SOLID"


def advance():
    if not steps:
        with open(result_path, "w") as f:
            json.dump(results, f, indent=1)
        bridge.unregister()
        bpy.ops.wm.quit_blender()
        return None
    steps.pop(0)()
    return 0.6


def begin():
    bridge.register()
    bpy.app.timers.register(advance, first_interval=0.5)
    return None


bpy.app.timers.register(begin, first_interval=2.0)
