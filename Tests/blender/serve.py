"""Keeps the bridge running in background Blender so `Margin --bridge-test` can
reach it. Background mode has no timer loop, so tick() is driven here.

  Blender -b --factory-startup --python Tests/blender/serve.py
"""
import importlib.util
import os
import time

import bpy

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("margin_bridge", os.path.join(here, "../../plugins/blender/margin_bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

obj = bpy.context.active_object or bpy.data.objects[0]
bpy.context.view_layer.objects.active = obj
obj.keyframe_insert("location", frame=10)
bpy.ops.object.mode_set(mode="SCULPT")

w = bpy.data.window_managers[0].windows[0] if bpy.data.window_managers[0].windows else None
print("modal_operators available:", hasattr(w, "modal_operators") if w else "no window")

bridge.register()
end = time.monotonic() + 14
while time.monotonic() < end:
    bridge.tick()
    time.sleep(0.016)
bridge.unregister()
os._exit(0)
