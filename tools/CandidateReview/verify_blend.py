"""Check a saved candidate .blend in a separate Blender background process."""

import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Matrix, Vector

root = Path(__file__).resolve().parents[2]
candidate = bpy.context.scene['candidate']
directory = root / 'art/candidates/proof-v01' / candidate
manifest = json.loads((directory / 'runtime/manifest.json').read_text())
motion = json.loads((directory / 'motion.json').read_text())
rig = next(obj for obj in bpy.data.objects if obj.type == 'ARMATURE')
assert len(rig.pose.bones) <= 12
assert not bpy.data.libraries
assert not any(image.source == 'FILE' and image.packed_file is None for image in bpy.data.images)
assert not any(obj.type in ('CURVES', 'VOLUME') or len(obj.particle_systems) for obj in bpy.data.objects)
assert 'IN-PLACE INSPECTION' in rig.animation_data.action.name
assert bpy.context.scene.frame_end == 24
maximum = 0.
for clip in ('walkRight', 'walkLeft'):
    action = next(action for action in bpy.data.actions if action.get('clip_id') == clip)
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    for sample in motion['clips'][clip]:
        bpy.context.scene.frame_set(sample['index'] + 1)
        bpy.context.view_layer.update()
        assert max(abs(v - expected) for row, expected_row in zip(rig.pose.bones['Stage'].matrix_basis, Matrix.Identity(4))
                   for v, expected in zip(row, expected_row)) < 1e-6
        for name, foot in sample['feet'].items():
            bone = rig.pose.bones[name]
            rest = bone.bone.head_local
            observed = (bone.matrix @ bone.bone.matrix_local.inverted()) @ Vector((rest.x, rest.y, 0))
            maximum = max(maximum, math.dist(observed, foot['evaluatedWorld']))
assert maximum < 2e-5, f'Saved rig differs from exported measurements: {maximum}'
print('SAVED_BLEND_PASS ' + json.dumps({'candidate': candidate, 'bones': len(rig.pose.bones),
      'maximumSavedRigErrorWorld': maximum, 'externalFiles': 0, 'hairObjects': 0}))
