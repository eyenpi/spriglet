"""Finite editable 30-fps Sprout actions with measured world-space stance.

Blender actions contain real root travel. Export compensation is a separate,
unkeyed stage bone; it is used only while writing in-place runtime images.
"""

import hashlib
import json
import math

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

FPS = 30
COUNTS = {"idle": 37, "walkRight": 73, "walkLeft": 73, "pet": 34, "settle": 25}
STEP = .28


def smooth(value):
    value = min(1.0, max(0.0, value))
    return value * value * (3 - 2 * value)


def pulse(t, a, b, c, d):
    return smooth((t - a) / (b - a)) * (1 - smooth((t - c) / (d - c)))


def translation(value):
    return Matrix.Translation(Vector(value))


def rotation(axis, angle):
    return Matrix.Rotation(angle, 4, axis)


def around(pivot, transform):
    return translation(pivot) @ transform @ translation(-Vector(pivot))


def neutral():
    return {"travel": 0.0, "yaw": 0.0, "bob": 0.0, "squash": 0.0,
            "bodyRoll": 0.0, "headPitch": 0.0, "headRoll": 0.0,
            "headYaw": 0.0, "ear": 0.0, "arm": 0.0,
            "blink": 0.0, "tail": 0.0, "phase": "stance"}


def petted(amount=1.0):
    result = neutral()
    result.update(squash=-.025 * amount, headPitch=-.04 * amount,
                  headRoll=-.10 * amount, ear=-.12 * amount,
                  arm=.16 * amount, blink=amount)
    return result


def foot_rest(side):
    return Vector((side * .29, -.24, .105))


def swing(start, end, start_yaw, end_yaw, t, lift=.10):
    eased = smooth(t)
    center = Vector(start).lerp(Vector(end), eased)
    center.z += lift * math.sin(math.pi * min(1, max(0, t))) ** 2
    return {"center": center, "yaw": start_yaw + (end_yaw - start_yaw) * eased,
            "pitch": .13 * math.sin(2 * math.pi * t),
            "planted": t <= 0 or t >= 1}


def stationary(center, yaw=0):
    return {"center": Vector(center), "yaw": yaw, "pitch": 0.0, "planted": True}


def evaluate_motion(clip, index, axis):
    n = COUNTS.get(clip, 1)
    t = index / (n - 1) if n > 1 else 0
    pose = neutral()
    feet = {s: stationary(foot_rest(s)) for s in (-1, 1)}
    if clip == "idle":
        envelope = math.sin(math.pi * t) ** 2
        pose.update(squash=.012 * envelope, headPitch=-.017 * envelope,
                    headYaw=.025 * math.sin(2 * math.pi * t) * envelope,
                    ear=.035 * math.sin(2 * math.pi * t - .3) * envelope,
                    blink=pulse(t, .31, .40, .45, .56))
    elif clip == "pet":
        a = smooth(t / .42)
        pose = petted(a)
        flourish = math.sin(math.pi * smooth((t - .18) / .82)) ** 2
        pose["headRoll"] -= .065 * flourish
        pose["headPitch"] -= .035 * flourish
        pose["ear"] += .060 * math.sin(6 * math.pi * t) * flourish
        pose["tail"] = .10 * math.sin(4 * math.pi * t) * flourish
    elif clip == "settle":
        pose = petted(1 - smooth(t))
        pose["blink"] = 1 - smooth((t - .16) / .47)
    elif clip == "sleep":
        pose = petted()
        pose.update(headPitch=.12, headRoll=.06, squash=-.035, ear=-.19, blink=1.0)
    elif clip.startswith("walk"):
        direction = 1 if clip == "walkRight" else -1
        travel_axis = axis * direction
        yaw = math.atan2(travel_axis.x, -travel_axis.y)
        turn = rotation('Z', yaw)
        turned = {s: (turn @ foot_rest(s)) + travel_axis * (-s * STEP / 2) for s in (-1, 1)}
        # Turns lift one foot at a time; a marked planted foot never rotates or
        # translates, including while the torso turns above it.
        if index <= 12:
            pose["yaw"] = yaw * smooth(index / 12)
            pose["phase"] = "turn-out"
            for s, start in ((1, 0), (-1, 6)):
                u = min(1, max(0, (index - start) / 6))
                feet[s] = swing(foot_rest(s), turned[s], 0, yaw, u, .075)
        elif index <= 60:
            elapsed = index - 12
            step_index = min(3, int(elapsed / 12))
            u = (elapsed - 12 * step_index) / 12
            pose["travel"] = direction * 4 * STEP * smooth(elapsed / 48)
            pose["yaw"] = yaw
            pose["phase"] = "walk"
            pos = {s: turned[s].copy() for s in (-1, 1)}
            for k in range(step_index + 1):
                s = 1 if k % 2 == 0 else -1
                target = (turn @ foot_rest(s)) + travel_axis * ((k + 1.5) * STEP)
                if k < step_index:
                    pos[s] = target
                else:
                    feet[s] = swing(pos[s], target, yaw, yaw, u, .105)
                    feet[-s] = stationary(pos[-s], yaw)
            phase = elapsed / 12
            envelope = math.sin(math.pi * elapsed / 48) ** .5
            pose.update(bob=.020 * math.sin(math.pi * phase) ** 2,
                        bodyRoll=.022 * math.sin(math.pi * phase) * envelope,
                        headRoll=-.010 * math.sin(math.pi * phase) * envelope,
                        headPitch=.025 * envelope,
                        arm=.18 * math.sin(math.pi * phase) * envelope,
                        ear=.05 * math.sin(math.pi * phase - .5) * envelope,
                        tail=.055 * math.sin(math.pi * phase) * envelope)
        else:
            pose["travel"] = direction * 4 * STEP
            u_turn = (index - 60) / 12
            pose["yaw"] = yaw * (1 - smooth(u_turn))
            pose["phase"] = "turn-back"
            initial = {1: (turn @ foot_rest(1)) + travel_axis * (3.5 * STEP),
                       -1: (turn @ foot_rest(-1)) + travel_axis * (4.5 * STEP)}
            for s, start in ((1, 60), (-1, 66)):
                u = min(1, max(0, (index - start) / 6))
                target = foot_rest(s) + travel_axis * 4 * STEP
                feet[s] = swing(initial[s], target, yaw, 0, u, .075)
    if clip != "sleep" and index == n - 1 and clip != "pet":
        travel = pose["travel"]
        pose = neutral()
        pose["travel"] = travel
        feet = {s: stationary(foot_rest(s) + axis * travel) for s in (-1, 1)}
    if index == 0 and clip not in ("settle", "sleep"):
        pose = neutral()
        feet = {s: stationary(foot_rest(s)) for s in (-1, 1)}
    return pose, feet


def desired_matrices(rig, pose, feet, axis, base_travel=0.0):
    travel = axis * (pose["travel"] + base_travel)
    root = translation(travel)
    torso_scale = Matrix.Diagonal((1 - pose["squash"] / 2,
                                   1 - pose["squash"] / 2, 1 + pose["squash"], 1))
    body = root @ rotation('Z', pose["yaw"]) @ translation((0, 0, pose["bob"]))
    body @= around((0, 0, .22), rotation('Y', pose["bodyRoll"]) @ torso_scale)
    head = body @ around((0, 0, 1.34), rotation('X', pose["headPitch"])
                         @ rotation('Y', pose["headRoll"]) @ rotation('Z', pose["headYaw"]))
    deforms = {"Stage · export compensation": Matrix.Identity(4),
               "Root · world travel": root, "Body · breathe": body,
               "Head · expression": head}
    for s, label in ((-1, "Left"), (1, "Right")):
        ear_pivot = Vector((s * .32, .015, 1.84))
        deforms[label + " ear"] = head @ around(ear_pivot, rotation('X', pose["ear"])
                                                        @ rotation('Y', s * pose["ear"] * .55))
        arm_pivot = Vector((s * .54, -.39, 1.17))
        deforms[label + " paw"] = body @ around(arm_pivot,
            rotation('X', pose["arm"] * s) @ rotation('Y', -s * abs(pose["arm"]) * .30))
        foot = feet[s]
        center = foot["center"] + axis * base_travel
        deforms[label + " foot · plant"] = translation(center) @ rotation('Z', foot["yaw"])
        deforms[label + " foot · plant"] @= rotation('X', foot["pitch"]) @ translation(-foot_rest(s))
        eye_center = Vector(rig.data.bones[label + " eye · blink"].head_local)
        eye_scale = Matrix.Diagonal((1.0, 1.0, max(.045, 1 - pose["blink"] * .955), 1))
        deforms[label + " eye · blink"] = head @ around(eye_center, eye_scale)
    deforms["Crown · follow"] = head @ around((0, -.08, 1.95), rotation('Y', pose["ear"] * .5))
    deforms["Tail · balance"] = body @ around((.14, .46, .43), rotation('Z', pose["tail"]))
    return {name: deform @ rig.data.bones[name].matrix_local for name, deform in deforms.items()}


def apply_pose(rig, matrices, frame=None):
    for bone in rig.pose.bones:
        target = matrices[bone.name]
        if bone.parent:
            basis = (bone.bone.matrix_local.inverted() @ bone.parent.bone.matrix_local
                     @ matrices[bone.parent.name].inverted() @ target)
        else:
            basis = bone.bone.matrix_local.inverted() @ target
        bone.matrix_basis = basis
        if frame is not None and bone.name != "Stage · export compensation":
            for channel in ("location", "rotation_quaternion", "scale"):
                bone.keyframe_insert(channel, frame=frame, group=bone.name)


def new_action(rig, name):
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    slot = action.slots.new(id_type='OBJECT', name=rig.name)
    animation = rig.animation_data_create()
    animation.action, animation.action_slot = action, slot
    return action


def select_action(rig, action):
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    rig.pose.bones["Stage · export compensation"].matrix_basis = Matrix.Identity(4)


def linear_keys(action):
    for layer in action.layers:
        for strip in layer.strips:
            for slot in action.slots:
                bag = strip.channelbag(slot)
                if bag:
                    for curve in bag.fcurves:
                        for key in curve.keyframe_points:
                            key.interpolation = 'LINEAR'


def signature(rig, travel):
    result = {}
    for bone in rig.pose.bones:
        if bone.name != "Stage · export compensation":
            matrix = translation(-travel) @ bone.matrix
            result[bone.name] = [round(v, 7) for row in matrix for v in row]
    return result


def bake_actions(rig, camera, pixels=448, points=224):
    scene = bpy.context.scene
    axis = camera.matrix_world.to_3x3() @ Vector((1, 0, 0))
    axis.z = 0
    axis.normalize()
    scale = points / camera.data.ortho_scale
    actions, contacts = {}, {"schemaVersion": 1, "framesPerSecond": FPS,
        "pixelConvention": "bottom-left", "canvasPixels": {"width": pixels, "height": pixels},
        "displaySizePoints": {"width": points, "height": points},
        "travelAxisWorld": list(axis), "worldGroundZ": 0.0,
        "stanceTolerancePixels": .05, "groundHeightTolerance": 1e-5,
        "clips": {}}
    for clip, count in COUNTS.items():
        action = new_action(rig, "Sprout · " + clip)
        action["clip_id"] = clip
        action["frames_per_second"] = FPS
        frames, endpoints = [], {}
        for i in range(count):
            scene.frame_set(i + 1)
            pose, feet = evaluate_motion(clip, i, axis)
            matrices = desired_matrices(rig, pose, feet, axis)
            apply_pose(rig, matrices, i + 1)
            bpy.context.view_layer.update()
            travel = axis * pose["travel"]
            foot_samples = {}
            for s, label in ((-1, "left"), (1, "right")):
                name = label.title() + " foot · plant"
                deform = rig.pose.bones[name].matrix @ rig.data.bones[name].matrix_local.inverted()
                marker = deform @ Vector((s * .29, -.24, 0))
                projected = world_to_camera_view(scene, camera, marker - travel)
                foot_samples[label] = {"planted": feet[s]["planted"],
                    "phase": pose["phase"] if pose["phase"] != "walk" else ("stance" if feet[s]["planted"] else "swing"),
                    "canvasPixels": {"x": projected.x * pixels, "y": projected.y * pixels},
                    "worldPosition": dict(zip(("x", "y", "z"), marker)),
                    "groundHeight": marker.z}
            frames.append({"index": i, "rootOffsetPoints": {"x": pose["travel"] * scale, "y": 0.0},
                           "feet": foot_samples})
            if i in (0, count - 1):
                key = "entry" if i == 0 else "exit"
                label = "petted" if (clip == "pet" and key == "exit") or (clip == "settle" and key == "entry") else "neutral"
                endpoints[key] = {"pose": label, "boneMatrices": signature(rig, travel)}
        linear_keys(action)
        actions[clip] = action
        contacts["clips"][clip] = {"frames": frames, "endpoints": endpoints}
    # An editable showcase action preserves actual grounded translation.
    demo = new_action(rig, "Sprout · COMPLETE SAMPLE · idle walk pet settle")
    timeline_frame, base_travel = 1, 0.0
    for clip in ("idle", "walkRight", "pet", "settle"):
        scene.timeline_markers.new(clip, frame=timeline_frame)
        for i in range(COUNTS[clip]):
            scene.frame_set(timeline_frame)
            pose, feet = evaluate_motion(clip, i, axis)
            apply_pose(rig, desired_matrices(rig, pose, feet, axis, base_travel), timeline_frame)
            timeline_frame += 1
        base_travel += pose["travel"]
    linear_keys(demo)
    actions["demo"] = demo
    sleep = new_action(rig, "Sprout · sleep pose")
    pose, feet = evaluate_motion("sleep", 0, axis)
    apply_pose(rig, desired_matrices(rig, pose, feet, axis), 1)
    actions["sleep"] = sleep
    contacts["demoFrameCount"] = timeline_frame - 1
    ground = world_to_camera_view(scene, camera, Vector((0, 0, 0)))
    contacts["groundAnchorPixels"] = {"x": ground.x * pixels, "y": ground.y * pixels}
    select_action(rig, actions["idle"])
    scene.frame_set(1)
    return actions, contacts, axis
