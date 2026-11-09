# SPDX-License-Identifier: GPL-3.0-or-later
"""Margin bridge: trackpad edges as exact Blender controls.

Margin sends `signature milliseconds name value` over UDP to 127.0.0.1:52010.
A background thread queues those, and a timer applies them on Blender's main
thread, because Blender's Python API crashes when called from any other thread.
Current values go back to 127.0.0.1:52011 as a signature followed by JSON, so
Margin's readout and haptic detents match.

Only the names in SETTERS and COMMANDS do anything. Messages are never
evaluated, so nothing a sender writes can run as code. Each one is signed with
a key only this macOS account can read, so other programs and other accounts
on the Mac can't drive Blender, and a recorded message stops working in seconds.
"""

bl_info = {
    "name": "Margin Bridge",
    "author": "Margin",
    "version": (0, 1, 0),
    "blender": (4, 2, 0),
    "category": "Interface",
    "description": "Control Blender values from the edges of your trackpad with the Margin app",
}

import bisect
import hashlib
import hmac
import json
import math
import os
import queue
import socket
import threading
import time

import bpy
import mathutils

LISTEN_PORT = 52010
REPORT_PORT = 52011
TICK_SECONDS = 1 / 60
REPORT_SECONDS = 1 / 15
HEARTBEAT_SECONDS = 1.0
MAX_DETENTS = 64
KEYFRAME_SECONDS = 1.0
SIGNATURE_LENGTH = 64
MAX_MESSAGE_AGE_MS = 5000
KEY_RETRY_SECONDS = 5.0
KEY_PATH = os.path.expanduser("~/Library/Application Support/Margin/bridge-key")

inbox = queue.Queue(maxsize=512)
# A leftover add-on entry in Preferences makes Blender reload this file after
# startup. Keep the live socket, or the listener dies with the port still held.
listener = globals().get("listener")
reporter = globals().get("reporter")
running = globals().get("running", False)
key = globals().get("key")
key_checked_at = 0.0
last_sent = None
last_sent_at = 0.0
last_report_at = 0.0
keyframe_source = None
keyframes_read_at = 0.0
all_keyframes = []


# Context. Timers run without a UI context, so everything is found explicitly.

def window():
    for wm in bpy.data.window_managers:
        if wm.windows:
            return wm.windows[0]
    return None


def scene():
    w = window()
    return w.scene if w else bpy.context.scene


def active_object():
    w = window()
    layer = w.view_layer if w else bpy.context.view_layer
    return layer.objects.active


def view_3d():
    """The first 3D viewport's (space, region_3d), or (None, None)."""
    w = window()
    if not w:
        return None, None
    for area in w.screen.areas:
        if area.type == 'VIEW_3D':
            space = area.spaces.active
            return space, space.region_3d
    return None, None


def mode():
    w = window()
    if w and getattr(w, "modal_operators", None):
        if any(op.bl_idname == "TRANSFORM_OT_translate" for op in w.modal_operators):
            return "GRAB"
    obj = active_object()
    if not obj:
        return "OBJECT"
    # Subdivision level only earns the left edge when there's a modifier to set.
    if obj.mode == "OBJECT" and subsurf():
        return "SUBDIV"
    return obj.mode


# Paths differ by version: 5.x keeps unified settings on each paint mode, 4.x
# keeps them on tool_settings.

def paint_settings():
    tools = scene().tool_settings
    sculpt = tools.sculpt
    unified = getattr(sculpt, "unified_paint_settings", None) or getattr(tools, "unified_paint_settings", None)
    return unified, sculpt.brush if sculpt else None


def brush_owner(flag):
    """Where a brush value lives: unified settings when shared, else the brush."""
    unified, brush = paint_settings()
    if unified is not None and (brush is None or getattr(unified, flag, False)):
        return unified
    return brush


def subsurf():
    obj = active_object()
    if not obj:
        return None
    return next((m for m in obj.modifiers if m.type == 'SUBSURF'), None)


def fcurves(obj):
    """An object's animation curves on either side of 4.4's layered actions."""
    data = obj.animation_data
    action = data.action if data else None
    if not action:
        return []
    if hasattr(action, "fcurves"):
        return list(action.fcurves)
    slot = getattr(data, "action_slot", None)
    if not slot:
        return []
    for layer in action.layers:
        for strip in layer.strips:
            bag = strip.channelbag(slot)
            if bag:
                return list(bag.fcurves)
    return []


def keyframes(current):
    """The keyframes nearest the playhead, in order and capped. A heavy rig has
    far too many to walk on every report, so the list refreshes about once a
    second, and a key added just now gets its detent a moment later."""
    global keyframe_source, keyframes_read_at, all_keyframes
    obj = active_object()
    if not obj:
        return []
    now = time.monotonic()
    source = obj.as_pointer()
    if source != keyframe_source or now - keyframes_read_at >= KEYFRAME_SECONDS:
        all_keyframes = sorted({point.co.x for curve in fcurves(obj) for point in curve.keyframe_points})
        keyframe_source, keyframes_read_at = source, now
    middle = bisect.bisect_left(all_keyframes, current)
    start = max(0, middle - MAX_DETENTS)
    nearby = all_keyframes[start:middle + MAX_DETENTS]
    return sorted(sorted(nearby, key=lambda f: abs(f - current))[:MAX_DETENTS])


# Setters. Each clamps, because a sender can ask for anything.

def set_frame(value):
    s = scene()
    s.frame_set(int(round(value)))


def set_brush_size(value):
    owner = brush_owner("use_unified_size")
    if owner:
        owner.size = max(1, int(round(value)))


def set_brush_strength(value):
    owner = brush_owner("use_unified_strength")
    if owner:
        owner.strength = min(10.0, max(0.0, value))


def set_subdivision(value):
    modifier = subsurf()
    if modifier:
        modifier.levels = min(6, max(0, int(round(value))))


def orbit(amount):
    """Relative: spins the view around the world's vertical axis."""
    _, region = view_3d()
    if region:
        turn = mathutils.Quaternion((0, 0, 1), amount * math.tau)
        region.view_rotation = turn @ region.view_rotation


def zoom(amount):
    """Relative: sliding up moves the view closer, by the same ratio at any distance."""
    _, region = view_3d()
    if region:
        region.view_distance = max(0.001, region.view_distance * math.exp(-amount * 4))


def pan(amount):
    """Relative: moves the view up or down, scaled to how far out it is."""
    _, region = view_3d()
    if region:
        up = region.view_rotation @ mathutils.Vector((0, 1, 0))
        region.view_location -= up * amount * region.view_distance


SETTERS = {
    "frame": set_frame,
    "brush_size": set_brush_size,
    "brush_strength": set_brush_strength,
    "subdivision_level": set_subdivision,
    "viewport_orbit": orbit,
    "viewport_zoom": zoom,
    "viewport_pan": pan,
}


def toggle_xray():
    space, _ = view_3d()
    if space:
        space.shading.show_xray = not space.shading.show_xray


def toggle_camera():
    _, region = view_3d()
    if region:
        region.view_perspective = 'PERSP' if region.view_perspective == 'CAMERA' else 'CAMERA'


def cycle_shading():
    space, _ = view_3d()
    if space:
        order = ['SOLID', 'MATERIAL', 'RENDERED', 'WIREFRAME']
        current = space.shading.type
        space.shading.type = order[(order.index(current) + 1) % len(order)] if current in order else 'SOLID'


def toggle_render_preview():
    space, _ = view_3d()
    if space:
        space.shading.type = 'SOLID' if space.shading.type == 'RENDERED' else 'RENDERED'


def in_viewport(run):
    """Runs an operator as if from the 3D viewport, so nothing depends on
    which window has focus or where the pointer is. Operators that change the
    scene pass True for undo, which scripts otherwise skip. Background Blender loads windows as data with no
    real UI, and operators crash there, so it runs nothing."""
    if bpy.app.background:
        return
    w = window()
    area = next((a for a in w.screen.areas if a.type == 'VIEW_3D'), None) if w else None
    region = next((r for r in area.regions if r.type == 'WINDOW'), None) if area else None
    if region:
        with bpy.context.temp_override(window=w, screen=w.screen, area=area, region=region):
            run()


def viewport(run):
    return lambda: in_viewport(run)


def toggle_setting(owner, name):
    target = owner()
    if target:
        setattr(target, name, not getattr(target, name))


def toggle_wireframe():
    space, _ = view_3d()
    if space:
        space.shading.type = 'SOLID' if space.shading.type == 'WIREFRAME' else 'WIREFRAME'


def toggle_proportional():
    tools = scene().tool_settings
    name = "use_proportional_edit" if mode() == "EDIT" else "use_proportional_edit_objects"
    setattr(tools, name, not getattr(tools, name))


def delete_selected():
    if active_object() and active_object().mode == "EDIT":
        bpy.ops.mesh.delete('EXEC_DEFAULT', True, type='VERT')
    else:
        bpy.ops.object.delete('EXEC_DEFAULT', True)


def step_frame(amount):
    s = scene()
    s.frame_set(s.frame_current + amount)


COMMANDS = {
    "xray_toggle": toggle_xray,
    "camera_view": toggle_camera,
    "shading_cycle": cycle_shading,
    "render_preview": toggle_render_preview,
    "undo": viewport(lambda: bpy.ops.ed.undo()),
    "redo": viewport(lambda: bpy.ops.ed.redo()),
    "toggle_edit": viewport(lambda: bpy.ops.object.editmode_toggle('EXEC_DEFAULT', True)),
    "play": viewport(lambda: bpy.ops.screen.animation_play()),
    "render_image": viewport(lambda: bpy.ops.render.render('INVOKE_DEFAULT')),
    "save_file": viewport(lambda: bpy.ops.wm.save_mainfile('INVOKE_DEFAULT')),
    "add_menu": viewport(lambda: bpy.ops.wm.call_menu(name="VIEW3D_MT_add")),
    "search": viewport(lambda: bpy.ops.wm.search_menu('INVOKE_DEFAULT')),
    "move": viewport(lambda: bpy.ops.transform.translate('INVOKE_DEFAULT', True)),
    "rotate": viewport(lambda: bpy.ops.transform.rotate('INVOKE_DEFAULT', True)),
    "scale": viewport(lambda: bpy.ops.transform.resize('INVOKE_DEFAULT', True)),
    "extrude": viewport(lambda: bpy.ops.mesh.extrude_region_move('INVOKE_DEFAULT', True)),
    "inset": viewport(lambda: bpy.ops.mesh.inset('INVOKE_DEFAULT', True)),
    "delete": viewport(delete_selected),
    "duplicate": viewport(lambda: bpy.ops.object.duplicate_move('INVOKE_DEFAULT', True)),
    "hide": viewport(lambda: bpy.ops.object.hide_view_set('EXEC_DEFAULT', True)),
    "reveal": viewport(lambda: bpy.ops.object.hide_view_clear('EXEC_DEFAULT', True)),
    "frame_all": viewport(lambda: bpy.ops.view3d.view_all()),
    "local_view": viewport(lambda: bpy.ops.view3d.localview()),
    "wireframe": toggle_wireframe,
    "maximize": viewport(lambda: bpy.ops.screen.screen_full_area()),
    "sidebar": lambda: toggle_setting(lambda: view_3d()[0], "show_region_ui"),
    "toolbar": lambda: toggle_setting(lambda: view_3d()[0], "show_region_toolbar"),
    "proportional": toggle_proportional,
    "snapping": lambda: toggle_setting(lambda: scene().tool_settings, "use_snap"),
    "next_keyframe": viewport(lambda: bpy.ops.screen.keyframe_jump(next=True)),
    "previous_keyframe": viewport(lambda: bpy.ops.screen.keyframe_jump(next=False)),
    "next_frame": lambda: step_frame(1),
    "previous_frame": lambda: step_frame(-1),
}


RELATIVE = {"viewport_orbit", "viewport_zoom", "viewport_pan"}


def load_key():
    global key, key_checked_at
    key_checked_at = time.monotonic()
    try:
        with open(KEY_PATH, "rb") as file:
            key = file.read().strip() or None
    except OSError:
        key = None


def sign(body):
    return hmac.new(key, body, hashlib.sha256).hexdigest().encode()


def verified(data):
    """The message inside a signed packet, or None. A failed check rereads the
    key at most every few seconds, in case Margin made a new one."""
    if not key and time.monotonic() - key_checked_at < KEY_RETRY_SECONDS:
        return None
    if not key:
        load_key()
    if not key or len(data) <= SIGNATURE_LENGTH + 1:
        return None
    signature, body = data[:SIGNATURE_LENGTH], data[SIGNATURE_LENGTH + 1:]
    if not hmac.compare_digest(signature, sign(body)):
        if time.monotonic() - key_checked_at >= KEY_RETRY_SECONDS:
            load_key()
        return None
    try:
        stamp, text = body.decode("ascii").split(" ", 1)
        if abs(time.time() * 1000 - int(stamp)) > MAX_MESSAGE_AGE_MS:
            return None
    except ValueError:
        return None
    return text


def apply_message(text):
    """Applies one message. Bad input is dropped rather than raised, because
    an exception would unregister the timer and silently end the bridge."""
    parts = text.split()
    if len(parts) != 2:
        return
    name, raw = parts
    try:
        if name in COMMANDS:
            COMMANDS[name]()
        elif name in SETTERS:
            value = float(raw)
            if math.isfinite(value):
                SETTERS[name](value)
    except (AttributeError, RuntimeError, ReferenceError, TypeError, ValueError):
        pass


def drain():
    """Applies queued messages, keeping only the newest value per name so a
    fast slide can't queue up work behind the viewport."""
    latest = {}
    while True:
        try:
            text = inbox.get_nowait()
        except queue.Empty:
            break
        name = text.split(" ", 1)[0]
        # Relative moves add up and commands each count, so neither can merge.
        key = name if name in SETTERS and name not in RELATIVE else (name, len(latest))
        latest[key] = text
    for text in latest.values():
        apply_message(text)


# Reports

def parameter(value, low, high, unit="", integer=False, detents=(), relative=False):
    return {"value": value, "min": low, "max": high, "unit": unit, "integer": integer,
            "detents": list(detents), "relative": relative}


def report():
    s = scene()
    params = {
        "frame": parameter(s.frame_current, s.frame_start, s.frame_end, "", True, keyframes(s.frame_current)),
    }
    for name in RELATIVE:
        params[name] = parameter(0, 0, 1, relative=True)
    size = brush_owner("use_unified_size")
    if size:
        params["brush_size"] = parameter(size.size, 1, 500, "px", True)
    strength = brush_owner("use_unified_strength")
    if strength:
        params["brush_strength"] = parameter(round(strength.strength, 3), 0, 1)
    modifier = subsurf()
    if modifier:
        params["subdivision_level"] = parameter(modifier.levels, 0, 6, "", True)
    return {"app": "blender", "mode": mode(), "parameters": params}


def send_report(now):
    global last_sent, last_sent_at
    try:
        text = json.dumps(report(), separators=(",", ":"))
    except (AttributeError, RuntimeError, ReferenceError):
        return
    if text == last_sent and now - last_sent_at < HEARTBEAT_SECONDS:
        return
    if not key:
        return
    try:
        body = text.encode()
        reporter.sendto(sign(body) + body, ("127.0.0.1", REPORT_PORT))
    except OSError:
        return
    last_sent, last_sent_at = text, now


def tick():
    """Runs on the main thread. Must never raise, or Blender drops the timer."""
    global last_report_at
    if not running:
        return None
    drain()
    now = time.monotonic()
    if now - last_report_at >= REPORT_SECONDS:
        last_report_at = now
        send_report(now)
    return TICK_SECONDS


def listen(sock):
    while running:
        try:
            data, address = sock.recvfrom(1024)
        except socket.timeout:
            continue
        except OSError:
            return
        if address[0] != "127.0.0.1":
            continue
        text = verified(data)
        if text is None:
            continue
        try:
            inbox.put_nowait(text)
        except queue.Full:
            pass


def register():
    global listener, reporter, running
    if running:
        return
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("127.0.0.1", LISTEN_PORT))
    except OSError:
        # Another Blender already has the port. It keeps the trackpad.
        sock.close()
        print("Margin Bridge: port in use, another Blender window is connected")
        return
    sock.settimeout(0.25)
    load_key()
    listener = sock
    reporter = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    running = True
    threading.Thread(target=listen, args=(sock,), daemon=True).start()
    bpy.app.timers.register(tick, persistent=True)


def unregister():
    global listener, reporter, running
    running = False
    if bpy.app.timers.is_registered(tick):
        bpy.app.timers.unregister(tick)
    for sock in (listener, reporter):
        if sock:
            sock.close()
    listener = reporter = None
