"""Runs the bridge inside real Blender, over real sockets:

  Blender -b --factory-startup --python Tests/blender/test_bridge.py

Background Blender has no timer loop or viewport, so tick() is driven by hand
and viewport commands are covered only for not raising.
"""
import hashlib
import hmac
import importlib.util
import json
import os
import socket
import sys
import tempfile
import time

import bpy

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("margin_bridge", os.path.join(here, "../../plugins/blender/margin_bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
# Separate ports, so this can run beside a real Blender and Margin.
key_file = tempfile.NamedTemporaryFile("w", suffix=".key", delete=False)
key_file.write("test-key")
key_file.close()
bridge.LISTEN_PORT, bridge.REPORT_PORT = 52020, 52021
bridge.KEY_PATH = key_file.name

failures = []


def check(name, condition):
    print(("PASS " if condition else "FAIL ") + name)
    if not condition:
        failures.append(name)


back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
back.bind(("127.0.0.1", bridge.REPORT_PORT))
back.settimeout(0.5)
out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def signed(message, secret=b"test-key", stamp=None):
    raw = message.encode() if isinstance(message, str) else message
    body = str(int(time.time() * 1000) if stamp is None else stamp).encode() + b" " + raw
    return hmac.new(secret, body, hashlib.sha256).hexdigest().encode() + b" " + body


def post(packet):
    out.sendto(packet, ("127.0.0.1", bridge.LISTEN_PORT))
    time.sleep(0.05)
    bridge.tick()


def send(*messages):
    for message in messages:
        out.sendto(signed(message), ("127.0.0.1", bridge.LISTEN_PORT))
    time.sleep(0.05)
    bridge.tick()


def latest():
    bridge.last_report_at = 0
    bridge.last_sent = None
    bridge.tick()
    data = None
    back.settimeout(0.3)
    try:
        while True:
            data, _ = back.recvfrom(65535)
            back.settimeout(0.02)
    except socket.timeout:
        pass
    return json.loads(data[64:])


bridge.register()
check("registers and runs", bridge.running)
check("timer is registered", bpy.app.timers.is_registered(bridge.tick))

scene = bpy.context.scene
scene.frame_start, scene.frame_end = 1, 100
obj = bpy.context.active_object or bpy.data.objects[0]
bpy.context.view_layer.objects.active = obj

state = latest()
check("reports app and object mode", state["app"] == "blender" and state["mode"] == "OBJECT")
check("reports frame range", state["parameters"]["frame"]["max"] == 100)

send("frame 42")
check("frame sets the scene", scene.frame_current == 42)

obj.keyframe_insert("location", frame=10)
obj.keyframe_insert("location", frame=30)
# Keyframes are reread about once a second, so a new key's detent arrives a
# moment later. Expire that cache instead of waiting.
bridge.keyframes_read_at = 0.0
state = latest()
check("keyframes become detents (5.x channelbags)", state["parameters"]["frame"]["detents"] == [10.0, 30.0])

check("no subdivision level without a modifier", "subdivision_level" not in state["parameters"])
modifier = obj.modifiers.new("sub", "SUBSURF")
send("subdivision_level 3")
check("subdivision sets the modifier", modifier.levels == 3)
send("subdivision_level 99")
check("subdivision clamps", modifier.levels == 6)
state = latest()
check("subdivision is reported", state["parameters"]["subdivision_level"]["value"] == 6)
check("a modifier changes the mode to SUBDIV", state["mode"] == "SUBDIV")

bpy.ops.object.mode_set(mode="SCULPT")
state = latest()
check("reports sculpt mode", state["mode"] == "SCULPT")
send("brush_size 42")
check("brush size is applied and read back", latest()["parameters"]["brush_size"]["value"] == 42)
send("brush_strength 0.25")
check("brush strength is applied and read back", abs(latest()["parameters"]["brush_strength"]["value"] - 0.25) < 0.001)
send("brush_size -5")
check("brush size clamps to 1", latest()["parameters"]["brush_size"]["value"] == 1)
bpy.ops.object.mode_set(mode="OBJECT")

before = scene.frame_current
send("frame nan", "frame inf", "nonsense", "too many words here", "import os", "__import__('os') 1",
     b"\xff\xfe binary", "brush_size", "")
check("bad messages change nothing", scene.frame_current == before)
check("bridge survives bad messages", bridge.tick() is not None)

send("frame 7", "frame 8", "frame 9")
check("newest value wins within a tick", scene.frame_current == 9)

for command in bridge.COMMANDS:
    send(f"{command} 1")
send("viewport_orbit 0.1", "viewport_zoom 0.1", "viewport_pan 0.1")
check("every relative value is reported", all(name in latest()["parameters"] for name in bridge.RELATIVE))
check("viewport commands don't raise without a viewport", bridge.tick() is not None)

spec.loader.exec_module(bridge)
bridge.LISTEN_PORT, bridge.REPORT_PORT = 52020, 52021
bridge.KEY_PATH = key_file.name
bridge.register()
check("survives Blender reloading the file", bridge.running and bridge.listener is not None)
send("frame 11")
check("still listens after a reload", scene.frame_current == 11)

scene.frame_set(20)
post(b"frame 21")
check("ignores unsigned messages", scene.frame_current == 20)
post(signed("frame 22", secret=b"wrong-key"))
check("ignores the wrong key", scene.frame_current == 20)
post(signed("frame 23", stamp=int((time.time() - 60) * 1000)))
check("ignores recorded messages", scene.frame_current == 20)
post(signed("frame 24"))
check("accepts a signed message", scene.frame_current == 24)

bridge.unregister()
check("unregisters", not bridge.running and not bpy.app.timers.is_registered(bridge.tick))
check("tick stops itself after unregister", bridge.tick() is None)
time.sleep(0.3)
bridge.register()
check("re-registers on the same port", bridge.running)
bridge.unregister()

print(f"RESULT {'FAILED ' + str(len(failures)) if failures else 'ALL PASSED'}")
sys.stdout.flush()
os._exit(1 if failures else 0)
