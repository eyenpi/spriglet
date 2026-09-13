"""Deterministic short velvet using Blender 5.2 native editable hair curves.

This study groom follows rigid transforms through parenting. It is not yet
bound to a deforming surface; regenerate it after editing the underlying shape.
"""

from array import array
import bisect
import hashlib
import math
import random

import bpy
from mathutils import Vector


def hair_material():
    mat = bpy.data.materials.new("Coat fibers · short velvet")
    nodes = mat.node_tree.nodes
    nodes.clear()
    attribute = nodes.new("ShaderNodeAttribute")
    attribute.attribute_type = "GEOMETRY"
    attribute.attribute_name = "fur_color"
    shader = nodes.new("ShaderNodeBsdfHairPrincipled")
    shader.model = "HUANG"
    shader.parametrization = "COLOR"
    shader.inputs["Roughness"].default_value = .65
    shader.inputs["Random Roughness"].default_value = .12
    # A stylized velvet choice: reduce Huang's white first reflection so the
    # olive pigment remains visible. Transmission components stay at 1.
    shader.inputs["Reflection"].default_value = .18
    output = nodes.new("ShaderNodeOutputMaterial")
    mat.node_tree.links.new(attribute.outputs["Color"], shader.inputs["Color"])
    mat.node_tree.links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    return mat


def add_groom(surfaces, collection, density):
    bpy.context.view_layer.update()
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mat = hair_material()
    total = 0
    for source, color_fn, length_factor in surfaces:
        evaluated = source.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        try:
            mesh.calc_loop_triangles()
            transform = source.matrix_world.copy()
            normal_transform = transform.to_3x3().inverted().transposed()
            triangles, areas = [], []
            cumulative = 0.0
            for tri in mesh.loop_triangles:
                vertices = [mesh.vertices[index] for index in tri.vertices]
                points = [transform @ vertex.co for vertex in vertices]
                area = (points[1] - points[0]).cross(points[2] - points[0]).length * .5
                if area < 1e-10:
                    continue
                normals = [(normal_transform @ vertex.normal).normalized() for vertex in vertices]
                triangles.append((points, normals))
                cumulative += area
                areas.append(cumulative)
            count = max(16, round(cumulative * density))
            seed = int.from_bytes(hashlib.sha256(source.name.encode()).digest()[:8], "little")
            rng = random.Random(seed)
            positions, radii, colors = array("f"), array("f"), array("f")
            inverse = transform.inverted()
            for _ in range(count):
                points, normals = triangles[bisect.bisect_left(areas, rng.random() * cumulative)]
                u = math.sqrt(rng.random())
                weights = (1 - u, u * (1 - rng.random()), 0)
                weights = (weights[0], weights[1], 1 - weights[0] - weights[1])
                point = sum((p * w for p, w in zip(points, weights)), Vector())
                normal = sum((n * w for n, w in zip(normals, weights)), Vector()).normalized()
                length = .022 * length_factor * rng.uniform(.70, 1.25)
                if source.name == "Sprout body" and point.y < -.30 and point.z > 1.24:
                    length *= .42
                down = Vector((-.08 * point.x, 0, -1))
                tangent = down - normal * down.dot(normal)
                if tangent.length > 1e-8:
                    tangent.normalize()
                jitter = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
                jitter -= normal * jitter.dot(normal)
                brightness = rng.uniform(.88, 1.02)
                color = tuple(c * brightness for c in color_fn(point))
                root = point + normal * .00015
                for t, radius in ((0, .00075), (.36, .00066), (.74, .00039), (1, .00006)):
                    position = root + normal * (length * t)
                    position += tangent * (length * .50 * t * t) + jitter * (length * .06 * t * t)
                    positions.extend(inverse @ position)
                    radii.append(radius * (.72 if length_factor < .6 else 1))
                    colors.extend((*color, 1))
            curves = bpy.data.hair_curves.new(source.name + " velvet")
            curves.add_curves([4] * count)
            curves.set_types(type="CATMULL_ROM")
            curves.attributes.new("radius", "FLOAT", "POINT")
            curves.attributes.new("fur_color", "FLOAT_COLOR", "POINT")
            curves.attributes["position"].data.foreach_set("vector", positions)
            curves.attributes["radius"].data.foreach_set("value", radii)
            curves.attributes["fur_color"].data.foreach_set("color", colors)
            curves.materials.append(mat)
            obj = bpy.data.objects.new(source.name + " · short velvet", curves)
            collection.objects.link(obj)
            obj.parent = source
            obj["groom_status"] = "Static design groom; rigid parenting only. Rebuild after changing surface geometry."
            obj["strand_count"] = count
            curves.update_tag()
            total += count
        finally:
            evaluated.to_mesh_clear()
    print(f"SPROUT_GROOM_STRANDS={total}")
