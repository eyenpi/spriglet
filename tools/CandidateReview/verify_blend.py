"""Check a saved candidate .blend in a separate Blender background process."""

import json
import math
from pathlib import Path
import sys

import bpy
from mathutils import Matrix, Vector

root = Path(__file__).resolve().parents[2]
candidate = bpy.context.scene['candidate']
directory = Path(bpy.data.filepath).resolve().parent
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
maximum_expression = maximum_pose = 0.
for clip, samples in motion['clips'].items():
    action = next(action for action in bpy.data.actions if action.get('clip_id') == clip)
    if 'boundaries' in motion:
        assert [action['starts_at'], action['ends_at']] == motion['boundaries'][clip]
        assert tuple(action.frame_range) == (1., float(len(samples)))
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    for sample in samples:
        bpy.context.scene.frame_set(sample['index'] + 1)
        bpy.context.view_layer.update()
        assert max(abs(v - expected) for row, expected_row in zip(rig.pose.bones['Stage'].matrix_basis, Matrix.Identity(4))
                   for v, expected in zip(row, expected_row)) < 1e-6
        for name, foot in sample['feet'].items():
            bone = rig.pose.bones[name]
            rest = bone.bone.head_local
            observed = (bone.matrix @ bone.bone.matrix_local.inverted()) @ Vector((rest.x, rest.y, 0))
            maximum = max(maximum, math.dist(observed, foot['evaluatedWorld']))
        if 'inPlacePose' in sample:
            for name, expected in sample['inPlacePose'].items():
                matrix = Matrix.Translation(-Vector(sample['rootWorld'])) @ rig.pose.bones[name].matrix
                maximum_pose = max(maximum_pose, max(abs(a - b) for a, b in zip(
                    [value for row in matrix for value in row], expected)))
        for name, expected in sample.get('evaluatedExpressions', {}).items():
            obj = bpy.data.objects[name]
            for key, value in expected.items():
                observed = obj.data.shape_keys.key_blocks[key].value
                maximum_expression = max(maximum_expression, abs(observed - value))
            assert all(driver.is_valid for driver in obj.data.shape_keys.animation_data.drivers)
assert maximum < 2e-5, f'Saved rig differs from exported measurements: {maximum}'
assert maximum_pose < 2e-5, f'Saved endpoint pose differs from authored pose: {maximum_pose}'
assert maximum_expression < 1e-5, f'Saved expression differs from exported expression: {maximum_expression}'
print('SAVED_BLEND_PASS ' + json.dumps({'candidate': candidate, 'bones': len(rig.pose.bones),
      'actionsChecked': list(motion['clips']), 'maximumSavedRigErrorWorld': maximum,
      'maximumSavedPoseElementError': maximum_pose, 'maximumSavedExpressionError': maximum_expression,
      'externalFiles': 0, 'hairObjects': 0}))
