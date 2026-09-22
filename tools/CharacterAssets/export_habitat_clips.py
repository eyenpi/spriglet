#!/usr/bin/env python3
"""Acorn local-portal and supported ledge Actions; no unauthored wall travel.

Host roots stay fixed. Real skeletal motion occurs within the portal's window,
with explicit clipping and measured foot/paw supports. Only a fully transparent
shared portal.hidden pose authorizes moving the window to another habitat.
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

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'art/candidates/transitions-v03/acorn-hopper'
REST=ROOT/'art/candidates/rest-rig-v04/acorn-hopper'
DESTINATION=ROOT/'art/candidates/habitats-v05/acorn-hopper'
sys.path.insert(0,str(ROOT/'tools/CharacterSampleValidation'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
from png_validation import read_rgba_png,alpha_measurements
from export_rest_rig import write_png

FPS,PIXELS,POINTS=30,448,96
SPECS={
    'habitat.floorExit':(22,'ready','portal.hidden'),
    'habitat.floorReentry':(22,'portal.hidden','ready'),
    'habitat.peekIn':(24,'portal.hidden','ledge.peek'),
    'habitat.edgeLook':(30,'ledge.peek','ledge.peek'),
    'habitat.dangle':(18,'ledge.peek','ledge.hang'),
    'habitat.pullUp':(22,'ledge.hang','ledge.peek'),
    'habitat.ledgeExit':(22,'ledge.peek','portal.hidden'),
}
PORTAL={'habitat.floorExit':('bottom',431,4,21),'habitat.floorReentry':('bottom',431,0,19),
        'habitat.peekIn':('top',16,0,17),'habitat.ledgeExit':('top',16,5,21)}


def smooth(t):
    t=min(1.,max(0.,t));return t*t*(3-2*t)


def pulse(t,a,b,c):
    return smooth((t-a)/(b-a)) if t<b else 1-smooth((t-b)/(c-b))


def parameters(clip,index):
    count,start,end=SPECS[clip]
    if not 0<=index<count:raise ValueError('Frame outside authored range')
    t=index/(count-1)
    pose=dict(z=0.,scale=1.,lean=0.,yaw=0.,cap=0.,leaf=0.,paw=0.,foot=0.,blink=0.,ledge=0.)
    support='none'
    if clip=='habitat.floorExit':
        pose.update(z=-2.65*smooth((t-.20)/.80),scale=1-.18*pulse(t,0,.19,.50),
                    lean=.08*math.sin(math.pi*t),paw=.5*pulse(t,.12,.38,.75),
                    leaf=.2*math.sin(3*math.pi*t)*math.sin(math.pi*t)**2,blink=pulse(t,.05,.19,.35))
        support='feet' if index<=4 else 'none'
    elif clip=='habitat.floorReentry':
        z=-2.65*(1-smooth(t/.68))+.18*pulse(t,.50,.68,.86)
        pose.update(z=z,scale=1-.14*pulse(t,.76,.87,1),paw=.5*pulse(t,0,.55,.9),
                    foot=.17*math.sin(math.pi*t),cap=.06*pulse(t,.60,.8,1),
                    leaf=-.16*math.sin(t*3*math.pi)*math.sin(math.pi*t)**2,blink=.6*pulse(t,.78,.88,1))
        support='feet' if index>=19 else 'none'
    else:
        pose.update(z=.45,paw=1.1,ledge=1.,foot=.12)
        support='paws'
        if clip=='habitat.peekIn':
            pose.update(z=.45+2.8*(1-smooth(t/.74))-.055*pulse(t,.72,.86,1),
                        ledge=smooth(t/.5),foot=.22,paw=.65+.45*smooth(t/.72),
                        cap=.07*pulse(t,.62,.83,1),leaf=.16*math.sin(t*3*math.pi)*math.sin(math.pi*t)**2)
            support='paws' if index>=17 else 'none'
        elif clip=='habitat.edgeLook':
            envelope=math.sin(math.pi*t)**2
            pose.update(lean=.055*math.sin(2*math.pi*t)*envelope,yaw=.13*math.sin(2*math.pi*t)*envelope,
                        cap=-.055*math.sin(2*math.pi*t-.2)*envelope,leaf=.09*math.sin(3*math.pi*t)*envelope,
                        blink=pulse(t,.72,.78,.86))
        elif clip=='habitat.dangle':
            pose.update(z=.45-.23*smooth(t),foot=.12+.18*smooth(t),
                        lean=.035*math.sin(2*math.pi*t)*math.sin(math.pi*t)**2,
                        cap=.055*smooth(t),leaf=-.13*smooth(t),blink=.6*pulse(t,.1,.25,.44))
        elif clip=='habitat.pullUp':
            pose.update(z=.22+.23*smooth(t)-.045*pulse(t,0,.18,.40),foot=.30-.18*smooth(t),
                        cap=.055*(1-smooth(t))-.035*pulse(t,.3,.6,1),leaf=-.13*(1-smooth(t))+.1*pulse(t,.5,.76,1),
                        blink=.8*pulse(t,.08,.24,.46))
        elif clip=='habitat.ledgeExit':
            pose.update(z=.45+2.8*smooth((t-.12)/.88),ledge=1-smooth((t-.45)/.5),
                        paw=1.1-.45*smooth((t-.2)/.5),foot=.12+.22*math.sin(math.pi*t),
                        cap=-.055*math.sin(math.pi*t),leaf=.15*math.sin(3*math.pi*t)*math.sin(math.pi*t)**2)
            support='paws' if index<=4 else 'none'
    # The exact supported canonical states do not depend on floating trig tails.
    if index in (0,count-1):
        state=start if index==0 else end
        if state=='ready':pose=dict(z=0.,scale=1.,lean=0.,yaw=0.,cap=0.,leaf=0.,paw=0.,foot=0.,blink=0.,ledge=0.);support='feet'
        elif state in ('ledge.peek','ledge.hang'):
            hanging=state=='ledge.hang'
            pose=dict(z=.22 if hanging else .45,scale=1.,lean=0.,yaw=0.,cap=.055 if hanging else 0.,
                      leaf=-.13 if hanging else 0.,paw=1.1,foot=.30 if hanging else .12,blink=0.,ledge=1.)
            support='paws'
        else:support='none';pose['ledge']=0.
    return pose,support


def markers(clip):
    count,start,end=SPECS[clip]
    result=[]
    for index,state in ((0,start),(count-1,end)):
        if state=='portal.hidden':
            result.append({'frameIndex':index,'id':'portalHidden'})
        else:
            result.extend({'frameIndex':index,'id':name} for name in ('safeToRedirect','feetPlanted' if state=='ready' else 'pawsGripped'))
    if end!='portal.hidden':result.append({'frameIndex':count-1,'id':'settled'})
    return result


def semantic_events(clip):
    count, _, end = SPECS[clip]
    result = []
    if clip == 'habitat.peekIn':
        result.append({'frameIndex': 17, 'id': 'pawsGripped'})
    if end == 'portal.hidden':
        result.append({'frameIndex': count - 1, 'id': 'fullyHidden'})
    return result


def write_json(path,value):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,indent=2)+'\n')


def clip_portal(file,clip,index):
    if clip not in PORTAL:return
    side,line,first,last=PORTAL[clip]
    if not first<=index<=last:return
    image=read_rgba_png(file);pixels=bytearray(image.pixels)
    rows=range(line) if side=='top' else range(line,PIXELS)
    for y in rows:pixels[y*PIXELS*4:(y+1)*PIXELS*4]=bytes(PIXELS*4)
    write_png(file,PIXELS,PIXELS,pixels)


def worker(destination,preview=False):
    import bpy
    from bpy_extras.object_utils import world_to_camera_view
    from mathutils import Matrix,Vector
    sys.path.insert(0,str(ROOT/'art/sprout/scripts'))
    from sample_motion import around,translation,rotation,apply_pose,new_action,linear_keys
    scene=bpy.context.scene;rig=bpy.data.objects['Acorn Hopper Rig'];camera=bpy.data.objects['Camera · runtime'];scene.camera=camera
    bones={b.name:b for b in rig.data.bones}
    up=camera.matrix_world.to_3x3()@Vector((0,1,0));right=camera.matrix_world.to_3x3()@Vector((1,0,0));back=camera.matrix_world.to_3x3()@Vector((0,0,1))
    grip_local={side:Vector((sign*.565*1.09,-.275*1.02,(.565+.15)*.92)) for sign,side in ((-1,'L'),(1,'R'))}
    raised={side:translation((0,0,.45))@around(bones['Arm.'+side].head_local,rotation('Y',-sign*1.1)) for sign,side in ((-1,'L'),(1,'R'))}
    targets={side:raised[side]@p for side,p in grip_local.items()};average=sum(p.dot(up) for p in targets.values())/2
    targets={side:p+up*(average-p.dot(up)) for side,p in targets.items()}
    grips={side:{'x':q.x*PIXELS,'y':(1-q.y)*PIXELS} for side,p in targets.items() for q in [world_to_camera_view(scene,camera,p)]}
    # A small real rounded lip gives the paws a visible support datum. It is
    # habitat artwork, not an imitation of the menu bar or other protected UI.
    basis=Matrix((right,-back,up)).transposed().to_4x4()
    lips=[]
    for sign,side in ((-1,'L'),(1,'R')):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=40,ring_count=16,radius=1)
        lip=bpy.context.object;lip.name='Portal ledge · olive lip.'+side
        center=targets[side]+right*(sign*.33)+back*.035-up*.018
        lip.matrix_world=translation(center)@basis@Matrix.Diagonal((.33,.035,.027,1))
        for polygon in lip.data.polygons:polygon.use_smooth=True
        lips.append(lip)
    material=bpy.data.materials.new('Portal ledge · matte olive')
    nodes=material.node_tree.nodes;links=material.node_tree.links;nodes.clear()
    surface=nodes.new('ShaderNodeBsdfPrincipled');surface.inputs['Base Color'].default_value=(.16,.19,.085,1);surface.inputs['Roughness'].default_value=.82
    transparent=nodes.new('ShaderNodeBsdfTransparent');mix=nodes.new('ShaderNodeMixShader');output=nodes.new('ShaderNodeOutputMaterial')
    links.new(transparent.outputs[0],mix.inputs[1]);links.new(surface.outputs[0],mix.inputs[2]);links.new(mix.outputs[0],output.inputs['Surface'])
    rig['HabitatLedge']=0.;driver=mix.inputs[0].driver_add('default_value').driver;v=driver.variables.new();v.name='visible';v.targets[0].id=rig;v.targets[0].data_path='["HabitatLedge"]';driver.expression='visible'
    for lip in lips:lip.data.materials.append(material)
    catcher=bpy.data.objects['Contact shadow'];catcher.vertex_groups['Root'].name='Stage'
    rig['HabitatFloor']=0.;floor_driver=catcher.driver_add('hide_render').driver;variable=floor_driver.variables.new()
    variable.name='floor';variable.targets[0].id=rig;variable.targets[0].data_path='["HabitatFloor"]';floor_driver.expression='floor < .5'
    foot_local={name:Vector((bones[name].head_local.x,bones[name].head_local.y,0)) for name in ('Foot.L','Foot.R')}
    scene.render.resolution_x=scene.render.resolution_y=PIXELS;scene.render.fps=FPS
    destination.mkdir(parents=True,exist_ok=True)

    def evaluate(clip,index):
        pose,support=parameters(clip,index);root=translation((0,0,pose['z']))
        scale=Matrix.Diagonal((1+(1-pose['scale'])*.3,1+(1-pose['scale'])*.3,pose['scale'],1))
        body=root@around(bones['Body'].head_local,Matrix.Rotation(pose['lean'],4,back)@rotation('Z',pose['yaw'])@scale)
        deforms={'Stage':Matrix.Identity(4),'Root':root,'Body':body}
        deforms['Cap']=body@around(bones['Cap'].head_local,rotation('X',pose['cap']))
        deforms['Leaf']=deforms['Cap']@around(bones['Leaf'].head_local,rotation('Y',pose['leaf']))
        contacts={}
        for sign,side in ((-1,'L'),(1,'R')):
            name='Arm.'+side;arm=body@around(bones[name].head_local,rotation('Y',-sign*pose['paw']))
            if support=='paws':arm=translation(targets[side]-arm@grip_local[side])@arm
            deforms[name]=arm
            contacts['paw.'+side]={'supported':support=='paws','kind':'ledgeGrip','world':list(arm@grip_local[side])}
            name='Foot.'+side
            foot=root@around(bones[name].head_local,rotation('Y',sign*pose['foot']))
            if support=='feet':foot=Matrix.Identity(4)
            deforms[name]=foot
            contacts['foot.'+side]={'supported':support=='feet','kind':'ground','world':list(foot@foot_local[name])}
        matrices={name:value@bones[name].matrix_local for name,value in deforms.items()}
        return matrices,contacts,pose

    actions,evidence={},{}
    for clip,(count,start,end) in SPECS.items():
        action=new_action(rig,'Acorn Hopper · '+clip);action['starts_at']=start;action['ends_at']=end;frames=[]
        for index in range(count):
            scene.frame_set(index+1);matrices,contacts,pose=evaluate(clip,index);apply_pose(rig,matrices)
            for bone in rig.pose.bones:
                if bone.name!='Stage':
                    for channel in ('location','rotation_quaternion','scale'):bone.keyframe_insert(channel,frame=index+1,group=bone.name)
            rig['Blink']=float(pose['blink']);rig['Happy']=0.;rig['HabitatLedge']=float(pose['ledge']);rig['HabitatFloor']=1. if clip.startswith('habitat.floor') else 0.
            for key in ('Blink','Happy','HabitatLedge','HabitatFloor'):rig.keyframe_insert(data_path=f'["{key}"]',frame=index+1,group='Face and habitat')
            frames.append({'index':index,'contacts':contacts,'localRootWorld':[0.,0.,pose['z']],
                           'expression':{'Blink':pose['blink'],'Happy':0.},'ledgeOpacity':pose['ledge'],
                           'pose':{name:[v for row in matrix for v in row] for name,matrix in matrices.items() if name!='Stage'}})
        linear_keys(action);actions[clip]=action;evidence[clip]=frames

    def select(clip,index):
        rig.animation_data.action=actions[clip];rig.animation_data.action_slot=actions[clip].slots[0]
        rig.pose.bones['Stage'].matrix_basis=Matrix.Identity(4);scene.frame_set(index+1);bpy.context.view_layer.update()

    canonical={}
    for clip,(count,start,end) in SPECS.items():
        for index in range(count):
            select(clip,index);sample=evidence[clip][index]
            for key,contact in sample['contacts'].items():
                kind,side=key.split('.');name=('Arm.' if kind=='paw' else 'Foot.')+side
                local=grip_local[side] if kind=='paw' else foot_local[name]
                bone=rig.pose.bones[name];observed=bone.matrix@bone.bone.matrix_local.inverted()@local
                contact['evaluatedWorld']=list(observed)
                q=world_to_camera_view(scene,camera,observed);contact['canvasPixels']={'x':q.x*PIXELS,'y':(1-q.y)*PIXELS}
                if math.dist(contact['world'],contact['evaluatedWorld'])>2e-5:raise ValueError(f'Contact evaluation mismatch {clip}/{index}/{key}')
            state=start if index==0 else end if index==count-1 else None
            if state and state!='portal.hidden':
                if state in canonical:
                    expected=canonical[state];error=max(abs(a-b) for name in expected['pose'] for a,b in zip(expected['pose'][name],sample['pose'][name]))
                    if error>2e-5 or expected['expression']!=sample['expression']:raise ValueError(f'Shared pose mismatch {clip}/{state}')
                canonical[state]=sample
    select('habitat.edgeLook',0);scene.frame_start=1;scene.frame_end=SPECS['habitat.edgeLook'][0]
    notes=bpy.data.texts.new('HABITATS V05 · local portal and grip actions')
    notes.write('Select an Acorn Hopper · habitat.* Action; body, face, ledge and floor visibility follow it.\n'
                'Host root stays fixed; Root bone contains real motion inside the local window. Stage stays identity.\n'
                'Both raised paw contacts remain fixed during edge-look, dangle and pull-up.\n'
                'Two small olive lips are floating habitat artwork, never physical menu support.\n'
                'The exporter applies declared top/bottom portal alpha clipping after rendering.\n'
                'Only the fully transparent portal.hidden image permits relocating the host window.\n'
                + '\n'.join(f'{clip}: frames 1–{value[0]}, {value[1]} → {value[2]}' for clip,value in SPECS.items()))
    bpy.context.preferences.filepaths.save_version=0
    bpy.ops.wm.save_as_mainfile(filepath=str(destination/'acorn-habitats.blend'),compress=True)
    (destination/'poses').mkdir(exist_ok=True);shutil.copyfile(REST/'neutral.png',destination/'poses/ready.png')
    write_png(destination/'poses/portal.hidden.png',PIXELS,PIXELS,bytes(PIXELS*PIXELS*4))
    exported={'ready','portal.hidden'};clips={}
    for clip,(count,start,end) in SPECS.items():
        frames=[]
        indices=sorted({0,count//2,count-1}) if preview else range(count)
        for index in indices:
            select(clip,index);state=start if index==0 else end if index==count-1 else None
            file=f'poses/{state}.png' if state else f'clips/{clip}/{index:04d}.png'
            if not state or state not in exported:
                path=destination/file;path.parent.mkdir(parents=True,exist_ok=True);scene.render.filepath=str(path)
                if 'FINISHED' not in bpy.ops.render.render(write_still=True):raise RuntimeError('Render cancelled')
                clip_portal(path,clip,index)
                if state:exported.add(state)
            frames.append({'file':file,'rootOffsetPoints':{'x':0.,'y':0.}})
        floor=clip.startswith('habitat.floor')
        clips[clip]={'startPoseID':start,'endPoseID':end,'framesPerSecond':FPS,'frames':frames,'tags':['habitat','portal' if clip in PORTAL else 'ledge'],
                     'requirements':{'habitatIDs':['desktop','floor'] if floor else ['topShelf','notchLeft','notchRight'],
                                     'orientationIDs':['upright'],'capabilityIDs':(['localPortal'] if floor else ['localPortal','ledgeGrip']) if clip in PORTAL else ['ledgeGrip']},
                     'motionClass':'relocation' if clip in PORTAL else 'depth','interruptionMarkers':markers(clip),
                     'semanticEvents':semantic_events(clip),
                     'ownership':{'channelIDs':['body','face','shadow','secondaryMotion'],'mode':'exclusive'}}
    if preview:return
    presentation={clip:{'hostRootMotion':'fixedWindow','allowsPointerInteraction':clip not in PORTAL,
                       'portalClip':({'side':PORTAL[clip][0],'linePixels':PORTAL[clip][1],'firstFrame':PORTAL[clip][2],'lastFrame':PORTAL[clip][3]} if clip in PORTAL else None)} for clip in SPECS}
    images={frame['file'] for clip in clips.values() for frame in clip['frames']}
    hit_regions={};poses={}
    for state in sorted(exported):
        file=f'poses/{state}.png';image=read_rgba_png(destination/file);box=alpha_measurements(image)['alphaBoundsTopLeftPixels']
        pose={'stillFrame':file,'layerIDs':[]}
        if box:
            hit_id='habitat.'+state;pose['hitRegionID']=hit_id
            hit_regions[hit_id]={'pointsPixels':[{'x':box['minX'],'y':box['minY']},{'x':box['maxX']+1,'y':box['minY']},
                                                {'x':box['maxX']+1,'y':box['maxY']+1},{'x':box['minX'],'y':box['maxY']+1}]}
        poses[state]=pose
    library={'schemaVersion':1,'kind':'schema3AuthoredClipLibrary','identity':'acorn-habitats-v05',
             'canvasPixels':{'width':PIXELS,'height':PIXELS},'displaySizePoints':{'width':POINTS,'height':POINTS},'coordinateSystem':'topLeftPixels',
             'clips':clips,'poses':poses,'hitRegions':hit_regions,'clipPresentation':presentation,
             'habitatGeometry':{'gripAnchorsPixels':grips,'minimumGripHeadClearancePoints':46.,'topPortalLinePixels':16,'floorPortalLinePixels':431,
                                'supportKind':'authoredFloatingPortalLedge','physicalMenuSupport':False,'wallTraversalSupported':False},
             'portalContract':{'relocationPoseID':'portal.hidden','requiresFullyTransparentFrame':True,'requiresBelowProtectedStrip':True,
                               'requiresEntireWindowBelowProtectedStrip':True},
             'resourceBudget':{'maxBufferedFrames':12,'newCompressedImagesMaximumBytes':18*1024*1024},
             'reducedMotionFallback':'procedural.blink',
             'provenance':{'sourceSHA256':hashlib.sha256((SOURCE/'acorn-hopper.blend').read_bytes()).hexdigest(),
                           'readyCanonicalSHA256':hashlib.sha256((REST/'neutral.png').read_bytes()).hexdigest(),
                           'exporterSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'blenderVersion':bpy.app.version_string,
                           'samples':scene.cycles.samples,'device':scene.cycles.device},
             'imagesSHA256':{file:hashlib.sha256((destination/file).read_bytes()).hexdigest() for file in sorted(images)}}
    write_json(destination/'clips.json',library);write_json(destination/'motion.json',{'schemaVersion':1,'clips':evidence})


def verify(destination=DESTINATION):
    library=json.loads((destination/'clips.json').read_text());motion=json.loads((destination/'motion.json').read_text())
    assert set(library['clips'])==set(SPECS)
    assert library['provenance'].get('validatorSHA256',library['provenance']['exporterSHA256'])==hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    assert (destination/'poses/ready.png').read_bytes()==(REST/'neutral.png').read_bytes()
    assert not any(read_rgba_png(destination/'poses/portal.hidden.png').pixels[3::4])
    maximum_drift=maximum_error=0.;unique=set()
    for clip,(count,start,end) in SPECS.items():
        data=library['clips'][clip];samples=motion['clips'][clip];assert len(data['frames'])==len(samples)==count
        assert (data['startPoseID'],data['endPoseID'])==(start,end)
        assert data['frames'][0]['file']==f'poses/{start}.png' and data['frames'][-1]['file']==f'poses/{end}.png'
        previous={}
        for index,(frame,sample) in enumerate(zip(data['frames'],samples)):
            assert frame['rootOffsetPoints']=={'x':0.,'y':0.};unique.add(frame['file'])
            for name,contact in sample['contacts'].items():
                maximum_error=max(maximum_error,math.dist(contact['world'],contact['evaluatedWorld']))
                if contact['supported']:
                    if name in previous:maximum_drift=max(maximum_drift,math.dist(previous[name],contact['evaluatedWorld']))
                    previous[name]=contact['evaluatedWorld']
                else:previous.pop(name,None)
            for marker in [m for m in data['interruptionMarkers'] if m['frameIndex']==index]:
                if marker['id'] in ('safeToRedirect','feetPlanted','pawsGripped','settled'):
                    assert sum(c['supported'] for c in sample['contacts'].values())>=2
    assert maximum_drift<2e-5 and maximum_error<2e-5
    compressed=0;minimum_ledge_y=PIXELS
    for file in unique:
        path=destination/file;compressed+=path.stat().st_size
        assert library['imagesSHA256'][file]==hashlib.sha256(path.read_bytes()).hexdigest()
        image=read_rgba_png(path,expected_size=(PIXELS,PIXELS));stats=alpha_measurements(image)
        if file=='poses/portal.hidden.png':continue
        assert stats['opaquePixels']>0 or file.startswith(('clips/habitat.floorExit','clips/habitat.floorReentry','clips/habitat.peekIn','clips/habitat.ledgeExit'))
        # Only declared portal phases may touch a canvas boundary.
        portal_file=any(file==frame['file'] and clip in PORTAL and PORTAL[clip][2]<=index<=PORTAL[clip][3]
                        for clip,data in library['clips'].items() for index,frame in enumerate(data['frames']))
        if not portal_file:assert stats['maximumBorderAlpha']==0,file
        ledge_file=any(file==frame['file'] and not clip.startswith('habitat.floor')
                       for clip,data in library['clips'].items() for frame in data['frames'])
        if ledge_file and not portal_file and stats['alphaBoundsTopLeftPixels']:
            minimum_ledge_y=min(minimum_ledge_y,stats['alphaBoundsTopLeftPixels']['minY'])
    assert compressed<18*1024*1024
    above_grip=(library['habitatGeometry']['gripAnchorsPixels']['L']['y']-minimum_ledge_y)*POINTS/PIXELS
    assert above_grip+1<=library['habitatGeometry']['minimumGripHeadClearancePoints']
    return {'clips':len(SPECS),'frames':sum(s[0] for s in SPECS.values()),'uniqueImages':len(unique),'compressedImageBytes':compressed,
            'maximumSupportDriftWorld':maximum_drift,'maximumEvaluatedContactErrorWorld':maximum_error,
            'maximumVisiblePointsAboveGrip':above_grip}


def blink_driver_error(observed,target):
    # Blender 5.2 stores the animated control at 0.9999734759 while reporting
    # the driven shape key as exactly 1.0. Accept only this bounded endpoint
    # snap; ordinary fractional driver mismatches still fail at 1e-5.
    if observed==1. and 1-1e-4<target<=1:return 0.
    return abs(observed-target)


def verify_saved(destination):
    import bpy
    from mathutils import Matrix
    scene=bpy.context.scene;rig=bpy.data.objects['Acorn Hopper Rig']
    motion=json.loads((destination/'motion.json').read_text());maximum_pose=maximum_face=maximum_control=maximum_snap=0.
    for clip in SPECS:
        action=bpy.data.actions['Acorn Hopper · '+clip];rig.animation_data.action=action;rig.animation_data.action_slot=action.slots[0]
        rig.pose.bones['Stage'].matrix_basis=Matrix.Identity(4)
        for sample in motion['clips'][clip]:
            scene.frame_set(sample['index']+1);bpy.context.view_layer.update()
            for name,expected in sample['pose'].items():
                actual=[v for row in rig.pose.bones[name].matrix for v in row]
                maximum_pose=max(maximum_pose,max(abs(a-b) for a,b in zip(actual,expected)))
            for eye in ('Eye.L','Eye.R'):
                control=rig['Blink'];observed=bpy.data.objects[eye].data.shape_keys.key_blocks['Blink'].value
                maximum_control=max(maximum_control,abs(control-sample['expression']['Blink']))
                maximum_face=max(maximum_face,blink_driver_error(observed,control))
                maximum_snap=max(maximum_snap,abs(observed-control))
            assert abs(rig['HabitatLedge']-sample['ledgeOpacity'])<1e-5
            assert bpy.data.objects['Contact shadow'].hide_render != clip.startswith('habitat.floor')
    assert maximum_pose<2e-5 and maximum_face<1e-5 and maximum_control<1e-5
    print(json.dumps({'savedActionsReopened':len(SPECS),'maximumPoseError':maximum_pose,'maximumSavedBlinkControlError':maximum_control,
                      'maximumFractionalDriverError':maximum_face,'maximumDriverEndpointSnap':maximum_snap}))


def proof(destination,output):
    from PIL import Image,ImageDraw
    library=json.loads((destination/'clips.json').read_text());output.mkdir(parents=True,exist_ok=True)
    selected=[('habitat.floorExit',8),('habitat.floorReentry',14),('habitat.peekIn',20),('habitat.edgeLook',9),
              ('habitat.dangle',17),('habitat.pullUp',11),('habitat.ledgeExit',10)]
    for points in (72,96,120):
        board=Image.new('RGB',(2016,1010),'#e9e7e2');draw=ImageDraw.Draw(board)
        draw.text((24,16),f'ACORN LOCAL PORTALS / {points} pt canvases @2x / floating ledge art, NOT menu support / declared occlusion / offline proof',fill='#333333')
        for row,bg in enumerate(('light','dark','busy')):
            y=56+row*312;draw.rectangle((12,y,2004,y+300),fill='#f8f5ef' if bg=='light' else '#242830')
            if bg=='busy':
                for yy in range(y,y+300,14):
                    for xx in range(12,2004,14):draw.rectangle((xx,yy,xx+6,yy+6),fill='#64796c' if (xx+yy)%3 else '#b99975')
            for col,(clip,index) in enumerate(selected):
                x=24+col*284;frame=library['clips'][clip]['frames'][index]
                draw.text((x,y+10),f'{clip.removeprefix("habitat.")} / {index+1}',fill='#333333' if bg=='light' else '#eeeeee')
                sprite=Image.open(destination/frame['file']).convert('RGBA').resize((points*2,points*2),Image.Resampling.LANCZOS)
                board.paste(sprite,(x+12,y+40),sprite)
                if clip in PORTAL:
                    line=round(y+40+PORTAL[clip][1]*points*2/PIXELS)
                    for xx in range(x+12,x+12+points*2,12):draw.line((xx,line,xx+5,line),fill='#89969c')
        board.save(output/f'storyboard-{points}pt.png')
    sequences={'floor':['habitat.floorExit','habitat.floorReentry'],
               'ledge':['habitat.peekIn','habitat.edgeLook','habitat.dangle','habitat.pullUp','habitat.ledgeExit']}
    timelines={side:[(clip,index,frame) for clip in clips for index,frame in enumerate(library['clips'][clip]['frames'])] for side,clips in sequences.items()}
    frame_dir=output/'preview-frames';frame_dir.mkdir(exist_ok=True)
    count=max(len(frames) for frames in timelines.values())
    for index in range(count):
        image=Image.new('RGB',(1280,540),'#e9e7e2');draw=ImageDraw.Draw(image)
        draw.text((24,20),'Finite local portals / 96 pt canvases @2x / 30 fps / fixed host / visible support art / offline proof',fill='#333333')
        for side,bg,x0 in (('floor','#f8f5ef',12),('ledge','#242830',646)):
            clip,local,frame=timelines[side][min(index,len(timelines[side])-1)]
            draw.rectangle((x0,70,x0+620,520),fill=bg)
            draw.text((x0+18,90),f'{side.upper()} / {clip} / {local+1}',fill='#333333' if side=='floor' else '#eeeeee')
            sprite=Image.open(destination/frame['file']).convert('RGBA').resize((192,192),Image.Resampling.LANCZOS)
            image.paste(sprite,(x0+212,250),sprite)
        image.save(frame_dir/f'{index:04d}.png')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-framerate','30','-i',str(frame_dir/'%04d.png'),
                    '-c:v','libx264','-crf','18','-pix_fmt','yuv420p','-movflags','+faststart',str(output/'habitats-finite.mp4')],check=True)
    write_json(output/'proof.json',{'kind':'offlineSourceFramePreview','framesPerSecond':FPS,'frameCount':count,
                                  'canvasPoints':96,'pixelsPerPoint':2,'hostRoot':'fixed','desktopCapture':False})


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--blender',default='/Applications/Blender.app/Contents/MacOS/Blender')
    parser.add_argument('--output',type=Path,default=DESTINATION);parser.add_argument('--worker',action='store_true')
    parser.add_argument('--preview',action='store_true');parser.add_argument('--check',action='store_true')
    parser.add_argument('--verify-saved',action='store_true');parser.add_argument('--verify-saved-worker',action='store_true');parser.add_argument('--proof',type=Path)
    argv=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else sys.argv[1:];args=parser.parse_args(argv)
    if args.worker:worker(args.output.resolve(),args.preview);return
    if args.verify_saved_worker:verify_saved(args.output.resolve());return
    if args.verify_saved:
        subprocess.run([args.blender,'--background',str(args.output/'acorn-habitats.blend'),'--python-exit-code','1','--python',str(Path(__file__).resolve()),
                        '--','--verify-saved-worker','--output',str(args.output.resolve())],check=True);return
    if args.proof:proof(args.output,args.proof);return
    if not args.check:
        command=[args.blender,'--background',str(SOURCE/'acorn-hopper.blend'),'--python-exit-code','1','--python',str(Path(__file__).resolve()),'--','--worker','--output',str(args.output.resolve())]
        if args.preview:command.append('--preview')
        subprocess.run(command,check=True)
    if not args.preview:print(json.dumps(verify(args.output)))


if __name__=='__main__':main()
