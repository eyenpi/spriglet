"""Native Blender 5.2 fur attached to the armature-deformed skin.

HairAttachmentUV is a non-overlapping per-face attachment atlas, not an art
texture UV. Preserve it when editing the existing topology; rebuild the groom
after topology changes. Deform Curves on Surface reads rest_position and each
strand's surface_uv_coordinate to follow the evaluated skinned mesh.
"""

from array import array
import bisect
import hashlib
import math
import random

import bpy
from mathutils import Vector

from coat_fibers import hair_material


def attachment_atlas(mesh):
    uv = mesh.uv_layers.new(name="HairAttachmentUV")
    grid = math.ceil(math.sqrt(len(mesh.polygons)))
    values = array("f", [0]) * (2 * len(mesh.loops))
    for polygon in mesh.polygons:
        col, row = polygon.index % grid, polygon.index // grid
        corners = [(0.1, .1), (.9, .1), (.9, .9), (.1, .9)]
        if polygon.loop_total == 3:
            corners = [(0.1, .1), (.9, .1), (.1, .9)]
        if polygon.loop_total not in (3, 4):
            raise ValueError("Attachment atlas requires triangles or quads")
        for loop, corner in zip(polygon.loop_indices, corners):
            values[2 * loop] = (col + corner[0]) / grid
            values[2 * loop + 1] = (row + corner[1]) / grid
    uv.uv.foreach_set("vector", values)
    positions = array("f", [0]) * (3 * len(mesh.vertices))
    mesh.vertices.foreach_get("co", positions)
    mesh.attributes.new("rest_position", "FLOAT_VECTOR", "POINT").data.foreach_set("vector", positions)
    return uv


def deformation_tree():
    tree = bpy.data.node_groups.new("Sprout · fur follows animated skin", "GeometryNodeTree")
    tree.interface.new_socket(name="Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    tree.interface.new_socket(name="Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    inp, out = tree.nodes.new("NodeGroupInput"), tree.nodes.new("NodeGroupOutput")
    deform = tree.nodes.new("GeometryNodeDeformCurvesOnSurface")
    inp.location, deform.location, out.location = (-220, 0), (0, 0), (220, 0)
    tree.links.new(inp.outputs["Geometry"], deform.inputs["Curves"])
    tree.links.new(deform.outputs["Curves"], out.inputs["Geometry"])
    return tree


def add_bound_groom(surfaces, collection, density):
    material, tree = hair_material(), deformation_tree()
    total, probes, objects = 0, [], []
    for surface, color_fn, length_factor in surfaces:
        mesh = surface.data
        uv = attachment_atlas(mesh)
        mesh.calc_loop_triangles()
        triangles, areas, cumulative = [], [], 0.0
        for tri in mesh.loop_triangles:
            vertices = [mesh.vertices[i] for i in tri.vertices]
            points = [v.co.copy() for v in vertices]
            area = (points[1] - points[0]).cross(points[2] - points[0]).length * .5
            # A clean sole: native strands are never generated below this band.
            if "foot" in surface.name.lower() and min(p.z for p in points) < .032:
                continue
            if area <= 1e-10:
                continue
            triangles.append((tuple(tri.vertices), points,
                              [v.normal.copy() for v in vertices],
                              [uv.uv[i].vector.copy() for i in tri.loops]))
            cumulative += area
            areas.append(cumulative)
        count = max(16, round(cumulative * density))
        seed = int.from_bytes(hashlib.sha256(surface.name.encode()).digest()[:8], "little")
        rng = random.Random(seed)
        positions, radii, colors, attachments = (array("f") for _ in range(4))
        for strand in range(count):
            indices, points, normals, uvs = triangles[bisect.bisect_left(areas, rng.random() * cumulative)]
            u, v = math.sqrt(rng.random()), rng.random()
            weights = (1 - u, u * (1 - v), u * v)
            point = sum((p * w for p, w in zip(points, weights)), Vector())
            normal = sum((n * w for n, w in zip(normals, weights)), Vector()).normalized()
            attachment = sum((p * w for p, w in zip(uvs, weights)), Vector((0, 0)))
            attachments.extend(attachment)
            length = .022 * length_factor * rng.uniform(.70, 1.25)
            if surface.name == "Sprout body" and point.y < -.30 and point.z > 1.24:
                length *= .42
            down = Vector((-.08 * point.x, 0, -1))
            tangent = down - normal * down.dot(normal)
            if tangent.length > 1e-8:
                tangent.normalize()
            jitter = Vector(tuple(rng.uniform(-1, 1) for _ in range(3)))
            jitter -= normal * jitter.dot(normal)
            brightness = rng.uniform(.88, 1.02)
            color = tuple(c * brightness for c in color_fn(point))
            # Root is exactly on its barycentric attachment, enabling numerical
            # attachment validation after every representative rig deformation.
            for t, radius in ((0, .00075), (.36, .00066), (.74, .00039), (1, .00006)):
                position = point + normal * (length * t)
                position += tangent * (length * .50 * t * t) + jitter * (length * .06 * t * t)
                if "foot" in surface.name.lower():
                    position.z = max(position.z, .012)
                positions.extend(position)
                radii.append(radius * (.72 if length_factor < .6 else 1))
                colors.extend((*color, 1))
            if strand < 8:
                probes.append({"surface": surface.name, "strand": strand,
                               "vertexIndices": list(indices), "weights": list(weights)})
        curves = bpy.data.hair_curves.new(surface.name + " · bound velvet")
        curves.add_curves([4] * count)
        curves.set_types(type="CATMULL_ROM")
        curves.attributes["position"].data.foreach_set("vector", positions)
        curves.attributes.new("radius", "FLOAT", "POINT").data.foreach_set("value", radii)
        curves.attributes.new("fur_color", "FLOAT_COLOR", "POINT").data.foreach_set("color", colors)
        curves.attributes.new("surface_uv_coordinate", "FLOAT2", "CURVE").data.foreach_set("vector", attachments)
        curves.surface, curves.surface_uv_map = surface, uv.name
        curves.materials.append(material)
        obj = bpy.data.objects.new(surface.name + " · bound velvet", curves)
        collection.objects.link(obj)
        obj.modifiers.new("Follow armature-deformed surface", "NODES").node_group = tree
        obj["groom_binding"] = "Deform Curves on Surface; HairAttachmentUV + rest_position"
        obj["strand_count"] = count
        obj["sole_clearance"] = .012 if "foot" in surface.name.lower() else 0.0
        curves.update_tag()
        objects.append(obj)
        total += count
    return objects, probes, total
