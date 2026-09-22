#!/usr/bin/env python3
"""Author Acorn's finite alert → turn → short hop → brake phrase.

The editable v03 scene is read, never changed. New actions have real root motion
and measured sole contacts. Every shared pose has one canonical PNG reference.
The ready pose deliberately uses the separately verified layered-rest canonical.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'art/candidates/transitions-v03/acorn-hopper'
REST = ROOT / 'art/candidates/rest-rig-v04/acorn-hopper'
DESTINATION = ROOT / 'art/candidates/reactive-v04/acorn-hopper'
sys.path.insert(0, str(ROOT / 'tools/CharacterSampleValidation'))
from png_validation import read_rgba_png, alpha_measurements

FPS, PIXELS, POINTS, TRAVEL = 30, 448, 96, 1.25
SPECS = {
    'reactive.alert': (12, 'ready', 'alert'),
    'reactive.turn.left': (12, 'alert', 'directed.left'),
    'reactive.turn.right': (12, 'alert', 'directed.right'),
    'reactive.hop.left': (26, 'directed.left', 'landed.left'),
    'reactive.hop.right': (26, 'directed.right', 'landed.right'),
    'reactive.brake.left': (16, 'landed.left', 'ready'),
    'reactive.brake.right': (16, 'landed.right', 'ready'),
    'reactive.dismiss': (12, 'alert', 'ready'),
    'reactive.abort.left': (12, 'directed.left', 'ready'),
    'reactive.abort.right': (12, 'directed.right', 'ready'),
}


def smooth(t):
    t = min(1., max(0., t))
    return t * t * (3 - 2 * t)


def pulse(t, start, peak, end):
    return smooth((t - start) / (peak - start)) if t < peak else 1 - smooth((t - peak) / (end - peak))


def canonical_pose(name):
    pose = dict(bodyLean=0., bodyPitch=0., bodyYaw=0., scaleZ=1., capPitch=0.,
                capLean=0., leafRoll=0., pawRaise=0., blink=0., lift=0., footFold=0., travel=0.)
    direction = -1 if name.endswith('.left') else 1
    if name == 'alert':
        pose.update(scaleZ=1.025, bodyPitch=-.035, capPitch=-.04, leafRoll=-.08, pawRaise=.08)
    elif name.startswith('directed.'):
        pose.update(scaleZ=1.01, bodyPitch=-.025, bodyLean=direction * .08, bodyYaw=direction * .12,
                    capLean=-direction * .045, capPitch=-.02, leafRoll=direction * .16, pawRaise=.11)
    elif name.startswith('landed.'):
        pose.update(scaleZ=.935, bodyLean=-direction * .028, bodyYaw=direction * .07,
                    capPitch=.045, leafRoll=-direction * .18, pawRaise=.02)
    elif name != 'ready':
        raise ValueError(f'Unknown pose: {name}')
    return pose


def parameters(clip, index):
    count, start, end = SPECS[clip]
    if not 0 <= index < count:
        raise ValueError('Frame outside authored range')
    t = index / (count - 1)
    first, last = canonical_pose(start), canonical_pose(end)
    pose = {key: value + (last[key] - value) * smooth(t) for key, value in first.items()}
    direction = -1 if clip.endswith('.left') else 1
    envelope = math.sin(math.pi * t) ** 2
    planted = True
    if clip == 'reactive.alert':
        pose['scaleZ'] += .025 * pulse(index, 1, 4, 9)
        pose['blink'] = .48 * pulse(index, 0, 2, 5)
        pose['leafRoll'] += .07 * math.sin(t * 2 * math.pi) * envelope
    elif '.turn.' in clip:
        # The body decides first; cap and leaf follow with bounded overshoot.
        pose['bodyLean'] += direction * .035 * envelope
        pose['capLean'] -= direction * .03 * math.sin(math.pi * t) * envelope
        pose['leafRoll'] += direction * .09 * math.sin(t * 2 * math.pi) * envelope
        pose['pawRaise'] += .055 * envelope
    elif '.hop.' in clip:
        u = min(1., max(0., (index - 5) / 12))
        pose['travel'] = direction * TRAVEL * smooth(u)
        pose['lift'] = .24 * math.sin(math.pi * u)
        planted = index <= 5 or index >= 17
        pose['scaleZ'] -= .13 * pulse(index, 0, 3, 6) + .075 * pulse(index, 16, 19, 25)
        pose['scaleZ'] += .10 * pulse(index, 5, 8, 13)
        pose['bodyLean'] += direction * .12 * pulse(index, 4, 10, 18)
        pose['capLean'] -= direction * .075 * math.sin((index - 4) * .48) * envelope
        pose['leafRoll'] += .19 * math.sin((index - 6) * .48) * envelope
        pose['pawRaise'] += .30 * pulse(index, 4, 10, 18)
        pose['footFold'] = .15 * math.sin(math.pi * u)
        pose['blink'] = .7 * pulse(index, 17, 19, 22)
    else:
        pose['scaleZ'] += .016 * math.sin(t * 2 * math.pi) * envelope
        pose['leafRoll'] += direction * .075 * math.sin(t * 3 * math.pi) * envelope
        pose['blink'] = .55 * pulse(index, 3, 5, 8)
    # Avoid floating trig residue at shared endpoints.
    if index in (0, count - 1):
        travel = pose['travel']
        pose = canonical_pose(start if index == 0 else end)
        pose['travel'] = travel
    return pose, planted


def markers(clip):
    last = SPECS[clip][0] - 1
    result = [{'frameIndex': index, 'id': key} for index in (0, last)
              for key in ('feetPlanted', 'safeToRedirect')]
    if '.hop.' in clip:
        result += [{'frameIndex': 5, 'id': 'feetPlanted'}, {'frameIndex': 17, 'id': 'feetPlanted'}]
    if SPECS[clip][2] == 'ready':
        result.append({'frameIndex': last, 'id': 'settled'})
    return sorted(result, key=lambda value: (value['frameIndex'], value['id']))


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def worker(destination, reuse_unchanged=False):
    import bpy
    from bpy_extras.object_utils import world_to_camera_view
    from mathutils import Matrix, Vector
    sys.path.insert(0, str(ROOT / 'art/sprout/scripts'))
    from sample_motion import around, translation, rotation, apply_pose, new_action, linear_keys
    scene = bpy.context.scene
    rig = bpy.data.objects['Acorn Hopper Rig']
    scene.camera = bpy.data.objects['Camera · runtime']
    camera = scene.camera
    axis = camera.matrix_world.to_3x3() @ Vector((1, 0, 0))
    axis.z = 0
    axis.normalize()
    lean_axis = Vector((-axis.y, axis.x, 0))
    bones = {bone.name: bone for bone in rig.data.bones}
    feet = {name: bones[name].head_local.copy() for name in ('Foot.L', 'Foot.R')}
    scene.render.resolution_x = scene.render.resolution_y = PIXELS
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    destination.mkdir(parents=True, exist_ok=True)
    previous_library=previous_motion=None
    if reuse_unchanged and (destination/'clips.json').exists() and (destination/'motion.json').exists():
        previous_library=json.loads((destination/'clips.json').read_text())
        previous_motion=json.loads((destination/'motion.json').read_text())

    def evaluate(clip, index):
        pose, planted = parameters(clip, index)
        shift = axis * pose['travel']
        root = translation(shift)
        scale = Matrix.Diagonal((1 + (1 - pose['scaleZ']) * .38, 1 + (1 - pose['scaleZ']) * .38, pose['scaleZ'], 1))
        body = root @ translation((0, 0, pose['lift'])) @ around(bones['Body'].head_local,
            Matrix.Rotation(pose['bodyLean'], 4, lean_axis) @ rotation('X', pose['bodyPitch']) @ rotation('Z', pose['bodyYaw']) @ scale)
        deforms = {'Stage': Matrix.Identity(4), 'Root': root, 'Body': body}
        deforms['Cap'] = body @ around(bones['Cap'].head_local, rotation('X', pose['capPitch']) @ Matrix.Rotation(pose['capLean'], 4, lean_axis))
        deforms['Leaf'] = deforms['Cap'] @ around(bones['Leaf'].head_local, rotation('Y', pose['leafRoll']))
        for side, name in ((-1, 'Arm.L'), (1, 'Arm.R')):
            deforms[name] = body @ around(bones[name].head_local, rotation('Y', -side * pose['pawRaise']))
        for side, name in ((-1, 'Foot.L'), (1, 'Foot.R')):
            deforms[name] = root @ translation((0, 0, pose['lift'])) @ around(feet[name], rotation('Y', side * pose['footFold']))
        matrices = {name: deform @ bones[name].matrix_local for name, deform in deforms.items()}
        contacts = {name: {'planted': planted, 'world': list(deforms[name] @ Vector((center.x, center.y, 0)))} for name, center in feet.items()}
        return matrices, contacts, shift, pose

    actions, evidence = {}, {}
    for clip, (count, start, end) in SPECS.items():
        action = new_action(rig, 'Acorn Hopper · ' + clip)
        action['clip_id'], action['starts_at'], action['ends_at'] = clip, start, end
        action['duration_seconds'] = count / FPS
        frames = []
        for index in range(count):
            scene.frame_set(index + 1)
            matrices, contacts, shift, pose = evaluate(clip, index)
            apply_pose(rig, matrices)
            for bone in rig.pose.bones:
                if bone.name != 'Stage':
                    for channel in ('location', 'rotation_quaternion', 'scale'):
                        bone.keyframe_insert(channel, frame=index + 1, group=bone.name)
            rig['Blink'], rig['Happy'] = float(pose['blink']), 0.
            for key in ('Blink', 'Happy'):
                rig.keyframe_insert(data_path=f'["{key}"]', frame=index + 1, group='Face')
            frames.append({'index': index, 'feet': contacts, 'rootWorld': list(shift), 'expression': {'Blink': pose['blink'], 'Happy': 0.},
                           'inPlacePose': {name: list(value for row in (translation(-shift) @ matrix) for value in row) for name, matrix in matrices.items() if name != 'Stage'}})
        linear_keys(action)
        actions[clip], evidence[clip] = action, frames

    def select(clip, index, compensate=True):
        rig.animation_data.action = actions[clip]
        rig.animation_data.action_slot = actions[clip].slots[0]
        rig.pose.bones['Stage'].matrix_basis = Matrix.Identity(4)
        scene.frame_set(index + 1)
        if compensate:
            stage = rig.pose.bones['Stage']
            stage.matrix_basis = stage.bone.matrix_local.inverted() @ translation(-Vector(evidence[clip][index]['rootWorld'])) @ stage.bone.matrix_local
        bpy.context.view_layer.update()

    # Validate evaluated output, including the actual saved action curves, before
    # spending time on rendering. All identical state names must mean one pose.
    canonical_states = {}
    for clip, (count, start, end) in SPECS.items():
        for index, pose_id in ((0, start), (count - 1, end)):
            sample = evidence[clip][index]
            if pose_id in canonical_states:
                prior = canonical_states[pose_id]
                error = max(abs(a-b) for name in prior['inPlacePose'] for a,b in zip(prior['inPlacePose'][name],sample['inPlacePose'][name]))
                if error > 2e-5 or prior['expression'] != sample['expression']:
                    raise ValueError(f'Pose mismatch: {clip}/{index} {pose_id}')
            else:
                canonical_states[pose_id] = sample
        for index in range(count):
            select(clip, index)
            sample = evidence[clip][index]
            shift = Vector(sample['rootWorld'])
            for name, center in feet.items():
                bone = rig.pose.bones[name]
                marker = bone.matrix @ bone.bone.matrix_local.inverted() @ Vector((center.x, center.y, 0))
                observed = marker + shift
                if (observed - Vector(sample['feet'][name]['world'])).length > 2e-5:
                    raise ValueError(f'Evaluated contact differs: {clip}/{index}/{name}')
                sample['feet'][name]['evaluatedWorld'] = list(observed)
                projected = world_to_camera_view(scene, camera, marker)
                sample['feet'][name]['canvasPixels'] = {'x': projected.x * PIXELS, 'y': (1-projected.y) * PIXELS}
            sample['evaluatedExpressions'] = {name: bpy.data.objects[name].data.shape_keys.key_blocks['Blink'].value for name in ('Eye.L','Eye.R')}
            if any(abs(value - sample['expression']['Blink']) > 1e-5 for value in sample['evaluatedExpressions'].values()):
                raise ValueError(f'Eye driver mismatch: {clip}/{index}')

    select('reactive.alert', 0, False)
    scene.frame_start, scene.frame_end = 1, SPECS['reactive.alert'][0]
    notes = bpy.data.texts.new('REACTIVE V04 · authored phrase')
    notes.write('New finite Actions: alert → turn.left/right → hop.left/right → brake.left/right.\n'
                'Choose a named Action and its frame range. Actions include face properties.\n'
                'Stage is unkeyed; only exporter uses it to compensate real root travel.\n'
                'Every state name identifies a matched skeleton/expression; feet ground during stationary phases.\n')
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(destination / 'acorn-reactive.blend'), compress=True)
    (destination / 'poses').mkdir(exist_ok=True)
    shutil.copyfile(REST / 'neutral.png', destination / 'poses/ready.png')
    exported_poses = {'ready'}
    reused_clips=set()
    if previous_library and previous_motion:
        provenance=previous_library['provenance']
        compatible=(provenance['sourceSHA256']==hashlib.sha256((SOURCE/'acorn-hopper.blend').read_bytes()).hexdigest()
                    and provenance['readyCanonicalSHA256']==hashlib.sha256((REST/'neutral.png').read_bytes()).hexdigest()
                    and provenance['blenderVersion']==bpy.app.version_string and provenance['samples']==scene.cycles.samples
                    and provenance['device']==scene.cycles.device)
        if compatible:
            for clip in SPECS:
                old=previous_library['clips'].get(clip)
                unchanged_images=old and all((destination/frame['file']).exists() and
                    previous_library.get('imagesSHA256',{}).get(frame['file'])==hashlib.sha256((destination/frame['file']).read_bytes()).hexdigest()
                    for frame in old['frames'])
                if old and previous_motion['clips'].get(clip)==evidence[clip] and unchanged_images:
                    reused_clips.add(clip)
                    exported_poses.update((old['startPoseID'],old['endPoseID']))
    clips = {}
    for clip, (count, start, end) in SPECS.items():
        frames = []
        for index in range(count):
            select(clip, index)
            pose_id = start if index == 0 else end if index == count-1 else None
            file = f'poses/{pose_id}.png' if pose_id else f'clips/{clip}/{index:04d}.png'
            if clip not in reused_clips and (not pose_id or pose_id not in exported_poses):
                path = destination / file
                path.parent.mkdir(parents=True, exist_ok=True)
                scene.render.filepath = str(path)
                if 'FINISHED' not in bpy.ops.render.render(write_still=True):
                    raise RuntimeError(f'Render cancelled: {clip}/{index}')
                if pose_id:
                    exported_poses.add(pose_id)
            root = Vector(evidence[clip][index]['rootWorld'])
            frames.append({'file': file, 'rootOffsetPoints': {'x': root.dot(axis) * POINTS / camera.data.ortho_scale, 'y': 0.}})
        hop = '.hop.' in clip
        clips[clip] = {
            'startPoseID': start, 'endPoseID': end, 'framesPerSecond': FPS, 'frames': frames,
            'tags': ['reactive', 'dodge', clip.split('.')[1]],
            'requirements': {'habitatIDs': ['desktop'], 'orientationIDs': [], 'capabilityIDs': []},
            'motionClass': 'relocation' if hop else 'local',
            'interruptionMarkers': markers(clip),
            'semanticEvents': [{'frameIndex': 17, 'id': 'footDown'}] if hop else [],
            'ownership': {'channelIDs': ['body', 'face', 'shadow', 'secondaryMotion'], 'mode': 'exclusive'},
        }
    source_manifest = json.loads((SOURCE / 'runtime/manifest.json').read_text())
    package = {
        'schemaVersion': 1, 'kind': 'schema3AuthoredClipLibrary', 'identity': 'acorn-reactive-v04',
        'canvasPixels': {'width': PIXELS, 'height': PIXELS}, 'displaySizePoints': {'width': POINTS, 'height': POINTS},
        'coordinateSystem': 'topLeftPixels',
        'groundAnchorPixels': {'x': source_manifest['groundAnchorPixels']['x'], 'y': PIXELS-source_manifest['groundAnchorPixels']['y']},
        'clips': clips, 'poses': {name: {'stillFrame': f'poses/{name}.png', 'layerIDs': []} for name in sorted(exported_poses)},
        'phrases': {f'dodge.{side}': ['reactive.alert', f'reactive.turn.{side}', f'reactive.hop.{side}', f'reactive.brake.{side}'] for side in ('left','right')},
        'reducedMotionFallback': 'procedural.blink',
        'groundedCancellation': {'alert':'reactive.dismiss','directed.left':'reactive.abort.left','directed.right':'reactive.abort.right'},
        'provenance': {'sourceSHA256': hashlib.sha256((SOURCE/'acorn-hopper.blend').read_bytes()).hexdigest(),
                       'exporterSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                       'readyCanonicalSHA256': hashlib.sha256((REST/'neutral.png').read_bytes()).hexdigest(),
                       'blenderVersion': bpy.app.version_string, 'samples': scene.cycles.samples, 'device': scene.cycles.device,
                       'reusedUnchangedClips':sorted(reused_clips)},
    }
    package['imagesSHA256']={file:hashlib.sha256((destination/file).read_bytes()).hexdigest()
                            for file in sorted({frame['file'] for clip in clips.values() for frame in clip['frames']})}
    write_json(destination/'clips.json', package)
    write_json(destination/'motion.json', {'schemaVersion': 1, 'framesPerSecond': FPS, 'travelAxis': list(axis), 'cameraScale': camera.data.ortho_scale, 'clips': evidence})


def verify(destination=DESTINATION):
    library = json.loads((destination/'clips.json').read_text())
    motion = json.loads((destination/'motion.json').read_text())
    assert set(library['clips']) == set(SPECS)
    assert library['provenance']['exporterSHA256'] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    assert library['provenance']['sourceSHA256'] == hashlib.sha256((SOURCE/'acorn-hopper.blend').read_bytes()).hexdigest()
    assert (destination/'poses/ready.png').read_bytes() == (REST/'neutral.png').read_bytes()
    unique, maximum_drift, maximum_ground = set(), 0., 0.
    for clip, (count, start, end) in SPECS.items():
        data, samples = library['clips'][clip], motion['clips'][clip]
        assert (data['startPoseID'],data['endPoseID']) == (start,end)
        assert len(data['frames']) == len(samples) == count
        assert data['frames'][0]['file'] == f'poses/{start}.png'
        assert data['frames'][-1]['file'] == f'poses/{end}.png'
        assert data['interruptionMarkers'] == markers(clip)
        previous={}
        for frame, sample in zip(data['frames'],samples):
            unique.add(frame['file'])
            expected_root=sum(a*b for a,b in zip(sample['rootWorld'],motion['travelAxis']))*POINTS/motion['cameraScale']
            assert abs(frame['rootOffsetPoints']['x']-expected_root)<1e-5 and frame['rootOffsetPoints']['y']==0
            for name, foot in sample['feet'].items():
                assert all(math.isfinite(v) for v in foot['evaluatedWorld'])
                assert math.dist(foot['evaluatedWorld'],foot['world'])<2e-5
                if foot['planted']:
                    maximum_ground=max(maximum_ground,abs(foot['evaluatedWorld'][2]))
                    if name in previous:
                        maximum_drift=max(maximum_drift,math.dist(previous[name],foot['evaluatedWorld']))
                    previous[name]=foot['evaluatedWorld']
                else:
                    previous.pop(name,None)
        for marker in data['interruptionMarkers']:
            if marker['id'] in ('feetPlanted','safeToRedirect','settled'):
                assert all(foot['planted'] for foot in samples[marker['frameIndex']]['feet'].values())
    assert maximum_ground < 2e-5 and maximum_drift < 2e-5, 'Ground contact slid or lifted'
    for file in sorted(unique):
        assert library['imagesSHA256'][file]==hashlib.sha256((destination/file).read_bytes()).hexdigest(),file
        image=read_rgba_png(destination/file,expected_size=(PIXELS,PIXELS))
        stats=alpha_measurements(image)
        assert stats['maximumBorderAlpha'] == 0
        assert stats['opaquePixels'] > 500
        box=stats['alphaBoundsTopLeftPixels']
        assert box and box['minX'] >= 3 and box['minY'] >= 3 and box['maxX'] <= 444 and box['maxY'] <= 444, file
    return {'clips':len(SPECS),'frames':sum(spec[0] for spec in SPECS.values()),'uniqueImages':len(unique),
            'maximumPlantedDriftWorld':maximum_drift,'maximumGroundErrorWorld':maximum_ground}


def verify_saved_scene(destination):
    """Reopen the delivered .blend and evaluate every saved action independently."""
    import bpy
    from mathutils import Matrix, Vector
    rig=bpy.data.objects['Acorn Hopper Rig']
    scene=bpy.context.scene
    motion=json.loads((destination/'motion.json').read_text())
    maximum_pose=maximum_face=0.
    for clip,(count,start,end) in SPECS.items():
        action=bpy.data.actions['Acorn Hopper · '+clip]
        assert action['starts_at']==start and action['ends_at']==end
        rig.animation_data.action=action
        rig.animation_data.action_slot=action.slots[0]
        rig.pose.bones['Stage'].matrix_basis=Matrix.Identity(4)
        for index,sample in enumerate(motion['clips'][clip]):
            scene.frame_set(index+1)
            bpy.context.view_layer.update()
            unshift=Matrix.Translation(-Vector(sample['rootWorld']))
            for name,expected in sample['inPlacePose'].items():
                actual=[value for row in (unshift @ rig.pose.bones[name].matrix) for value in row]
                maximum_pose=max(maximum_pose,max(abs(a-b) for a,b in zip(actual,expected)))
            for eye in ('Eye.L','Eye.R'):
                value=bpy.data.objects[eye].data.shape_keys.key_blocks['Blink'].value
                maximum_face=max(maximum_face,abs(value-sample['expression']['Blink']))
    assert maximum_pose<2e-5 and maximum_face<1e-5
    print(json.dumps({'savedActionsReopened':len(SPECS),'maximumPoseError':maximum_pose,'maximumExpressionError':maximum_face}))


def proof(destination, output):
    """Pillow/FFmpeg offline proof: exact PNGs, authored timing and root motion."""
    from PIL import Image, ImageDraw
    verify(destination)
    library=json.loads((destination/'clips.json').read_text())
    output.mkdir(parents=True,exist_ok=True)
    selected=[('reactive.alert',4),('reactive.turn.right',7),('reactive.hop.right',3),
              ('reactive.hop.right',11),('reactive.hop.right',17),('reactive.brake.right',5),('reactive.brake.right',15)]
    for points in (72,96,120):
        board=Image.new('RGB',(2016,1010),'#e9e7e2')
        draw=ImageDraw.Draw(board)
        draw.text((24,16),f'ACORN REACTIVE V04 / {points} point canvases @2x / offline authored source frames / no native or energy claim',fill='#333333')
        for row,bg in enumerate(('light','dark','busy')):
            y=56+row*312
            draw.rectangle((12,y,2004,y+300),fill='#f8f5ef' if bg=='light' else '#242830')
            if bg=='busy':
                for yy in range(y,y+300,14):
                    for xx in range(12,2004,14):
                        draw.rectangle((xx,yy,xx+6,yy+6),fill='#64796c' if (xx+yy)%3 else '#b99975')
            for col,(clip,index) in enumerate(selected):
                frame=library['clips'][clip]['frames'][index]
                x=24+col*284
                label=f'{clip.removeprefix("reactive.")} / {index+1}'
                draw.text((x,y+10),label,fill='#333333' if bg=='light' else '#eeeeee')
                sprite=Image.open(destination/frame['file']).convert('RGBA').resize((points*2,points*2),Image.Resampling.LANCZOS)
                board.paste(sprite,(x+12,y+40),sprite)
        board.save(output/f'storyboard-{points}pt.png')
    timelines={}
    for side in ('left','right'):
        timeline=[]
        root=0.
        for clip in library['phrases']['dodge.'+side]:
            frames=library['clips'][clip]['frames']
            for index,frame in enumerate(frames):
                timeline.append((clip,index,frame['file'],root+frame['rootOffsetPoints']['x']))
            root+=frames[-1]['rootOffsetPoints']['x']
        timelines[side]=timeline
    frame_dir=output/'preview-frames'
    frame_dir.mkdir(exist_ok=True)
    for index in range(len(timelines['left'])):
        image=Image.new('RGB',(1280,520),'#e9e7e2')
        draw=ImageDraw.Draw(image)
        draw.text((24,20),'Finite authored dodge / 96 point canvases @2x / 30 fps / actual cumulative root / offline proof',fill='#333333')
        for side,bg,start in (('left','#f8f5ef',370),('right','#242830',910)):
            clip,local,file,root=timelines[side][index]
            x0=12 if side=='left' else 646
            draw.rectangle((x0,70,x0+620,500),fill=bg)
            draw.text((x0+18,90),f'{side.upper()} / {clip} / {local+1}',fill='#333333' if side=='left' else '#eeeeee')
            sprite=Image.open(destination/file).convert('RGBA').resize((192,192),Image.Resampling.LANCZOS)
            image.paste(sprite,(round(start+root*2-96),250),sprite)
        image.save(frame_dir/f'{index:04d}.png')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-framerate','30','-i',str(frame_dir/'%04d.png'),
                    '-c:v','libx264','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(output/'reactive-finite.mp4')],check=True)
    write_json(output/'proof.json',{'kind':'offlineSourceFramePreview','framesPerSecond':30,'previewFrameCount':len(timelines['left']),
                                  'nativeCanvasPoints':96,'outputPixelsPerPoint':2,'rootMotion':'cumulative authored per-frame roots',
                                  'desktopCapture':False,'nativePresentationAcceptance':False})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--blender',default='/Applications/Blender.app/Contents/MacOS/Blender')
    parser.add_argument('--output',type=Path,default=DESTINATION)
    parser.add_argument('--worker',action='store_true')
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--proof',type=Path)
    parser.add_argument('--verify-saved',action='store_true')
    parser.add_argument('--verify-saved-worker',action='store_true')
    parser.add_argument('--reuse-unchanged',action='store_true',help='Reuse only clips with identical evaluated pose/face/contact samples and source/render settings')
    argv=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else sys.argv[1:]
    args=parser.parse_args(argv)
    if args.worker:
        worker(args.output.resolve(),args.reuse_unchanged); return
    if args.verify_saved_worker:
        verify_saved_scene(args.output.resolve()); return
    if args.verify_saved:
        subprocess.run([args.blender,'--background',str(args.output/'acorn-reactive.blend'),'--python-exit-code','1',
                        '--python',str(Path(__file__).resolve()),'--','--verify-saved-worker','--output',str(args.output.resolve())],check=True)
        return
    if args.proof:
        proof(args.output,args.proof); return
    if not args.check:
        command=[args.blender,'--background',str(SOURCE/'acorn-hopper.blend'),'--python-exit-code','1',
                 '--python',str(Path(__file__).resolve()),'--','--worker','--output',str(args.output.resolve())]
        if args.reuse_unchanged:
            command.append('--reuse-unchanged')
        subprocess.run(command,check=True)
    print(json.dumps(verify(args.output)))


if __name__ == '__main__':
    main()
