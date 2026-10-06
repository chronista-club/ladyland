"""編集済み studio を Ladyland へ渡す。機材・家具の再生成、blend の保存はしない。

Blender --background --python ladyland/Gear/studio_export.py -- --output /tmp/studio-gear
確認した出力を Application Support/ladyland/gear へ配置する。
座標: Blender (x, y, z) m → Ladyland (x, z, -y) mm。
"""

import argparse
import json
import math
from pathlib import Path
import re
import sys

import bpy
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
STUDIO = HERE.parents[1] / "assets/blender/scenes/studio.blend"


def app_vector(v, factor=1000):
    return [round(float(n) * factor, 3) for n in (v[0], v[2], -v[1])]


def mesh_bounds(objects):
    points = [o.matrix_world @ Vector(v) for o in objects if o.type == "MESH" and not o.hide_render
              for v in o.bound_box]
    if not points:
        raise ValueError("書き出すメッシュがありません")
    return ([min(p[i] for p in points) for i in range(3)],
            [max(p[i] for p in points) for i in range(3)])


def gear_instances(scene):
    return sorted((o for o in scene.objects if o.instance_type == "COLLECTION" and not o.hide_render),
                  key=lambda o: o.name)


def layout_from_scene(scene):
    if abs(scene.unit_settings.scale_length - 1) > 1e-6:
        raise ValueError("studio はメートル単位（scale_length = 1）にしてください")
    gear = []
    for instance in gear_instances(scene):
        if not re.fullmatch(r"[a-z0-9_]+", instance.name):
            raise ValueError(f"機材のインスタンス名を ID にしてください: {instance.name}")
        at, rotation, scale = instance.matrix_world.decompose()
        if any(abs(v - 1) > 1e-5 for v in scale) or (rotation @ Vector((0, 0, 1)) - Vector((0, 0, 1))).length > 1e-5:
            raise ValueError(f"機材は実寸・水平のまま配置してください: {instance.name}")
        collection = instance.instance_collection
        if collection.instance_offset.length > 1e-6:
            raise ValueError(f"機材の collection offset は 0 にしてください: {instance.name}")
        lo, hi = mesh_bounds(collection.all_objects)
        if abs(lo[2]) > .002:
            raise ValueError(f"機材原点は底面にしてください: {instance.name}")
        gear.append(dict(id=instance.name, center=[app_vector(at)[0], app_vector(at)[2]],
                         size=[round((hi[0] - lo[0]) * 1000, 3), round((hi[1] - lo[1]) * 1000, 3)],
                         height=round((hi[2] - lo[2]) * 1000, 3), elevation=app_vector(at)[1],
                         yaw=round(math.degrees(rotation.to_euler().z), 3)))
    if not gear:
        raise ValueError("機材のコレクションインスタンスがありません")

    surfaces = []
    for obj in scene.objects:
        if not obj.get("ladyland_surface") or obj.hide_render:
            continue
        lo, hi = mesh_bounds([obj])
        surfaces.append(dict(id=obj.name,
                             center=[round((lo[0] + hi[0]) * 500, 3), round(-(lo[1] + hi[1]) * 500, 3)],
                             size=[round((hi[0] - lo[0]) * 1000, 3), round((hi[1] - lo[1]) * 1000, 3)],
                             elevation=round(hi[2] * 1000, 3), thickness=round((hi[2] - lo[2]) * 1000, 3)))
    if not surfaces:
        raise ValueError("天板にカスタムプロパティ ladyland_surface = True を付けてください")
    min_x = min(s["center"][0] - s["size"][0] / 2 for s in surfaces)
    max_x = max(s["center"][0] + s["size"][0] / 2 for s in surfaces)
    min_z = min(s["center"][1] - s["size"][1] / 2 for s in surfaces)
    max_z = max(s["center"][1] + s["size"][1] / 2 for s in surfaces)

    trays = {}
    heights = []
    for obj in scene.objects:
        key = obj.get("ladyland_tray")
        if key:
            if key not in {"mixer", "trackKnobs"} or key in trays:
                raise ValueError(f"不明または重複した tray: {key}")
            at = app_vector(obj.matrix_world.translation)
            trays[key] = [at[0], at[2]]
            heights.append(at[1])
    if not heights or max(heights) - min(heights) > .1:
        raise ValueError("仮想部品の置き場を同じ高さの Empty（ladyland_tray）で指定してください")

    cam = scene.camera
    if cam is None or cam.data.type not in {"PERSP", "ORTHO"}:
        raise ValueError("アクティブカメラに透視または平行投影カメラを指定してください")
    if abs(cam.data.shift_x) > 1e-6 or abs(cam.data.shift_y) > 1e-6:
        raise ValueError("カメラのレンズシフトは未対応です。カメラ自体を移動してください")
    at = cam.matrix_world.translation
    rotation = cam.matrix_world.to_quaternion()
    direction = rotation @ Vector((0, 0, -1))
    camera = dict(from_=app_vector(at), at=app_vector(at + direction),
                  up=app_vector(rotation @ Vector((0, 1, 0)), factor=1),
                  fov=round(math.degrees(cam.data.angle_y), 4),
                  projection="orthographic" if cam.data.type == "ORTHO" else "perspective")
    camera["from"] = camera.pop("from_")
    camera["aspectRatio"] = scene.render.resolution_x * scene.render.pixel_aspect_x / (scene.render.resolution_y * scene.render.pixel_aspect_y)
    if cam.data.type == "ORTHO":
        camera["orthographicScale"] = round(cam.data.ortho_scale * 1000, 3)
        horizontal = scene.render.resolution_x * scene.render.pixel_aspect_x >= scene.render.resolution_y * scene.render.pixel_aspect_y
        camera["scaleDirection"] = "horizontal" if horizontal else "vertical"
    return dict(note="studio.blend から生成。単位 mm。配置の編集は Blender で行う。",
                desk=dict(center=[(min_x + max_x) / 2, (min_z + max_z) / 2], size=[max_x - min_x, max_z - min_z]),
                surfaces=surfaces, gear=gear, tray=trays, trayElevation=heights[0], camera=camera)


def export_usdz(objects, path):
    objects = list(objects)
    if not objects:
        raise ValueError(f"書き出すオブジェクトがありません: {path}")
    for obj in bpy.context.view_layer.objects:
        obj.select_set(False)
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.wm.usd_export(
        filepath=str(path), selected_objects_only=True, export_materials=True,
        generate_preview_surface=True, export_textures_mode="NEW", overwrite_textures=True,
        export_animation=False, convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y", evaluation_mode="RENDER", root_prim_path="/root")


def bake_surfaces(scene, output):
    # 一時プロセス内だけで材質を複製し、接地の陰影を Base Color に焼く。
    # 手編集の blend とリンク機材のメッシュ・材質は書き換えない。
    sys.path.insert(0, str(HERE))
    import look
    look.TEX_DIR = str(output / "textures")
    scene.render.engine = "CYCLES"
    for obj in scene.objects:
        if not obj.get("ladyland_surface") or obj.hide_render:
            continue
        if len(obj.data.materials) != 1:
            raise ValueError(f"天板の AO は単一材質に対応: {obj.name}")
        obj.data = obj.data.copy()
        obj.active_material = obj.active_material.copy()
        bsdf = look.principled(obj.active_material)
        if bsdf.inputs["Base Color"].is_linked:
            raise ValueError(f"天板の Base Color テクスチャの合成は未対応: {obj.name}")
        color = tuple(bsdf.inputs["Base Color"].default_value[:3])
        # 面同士の UV 重複を避ける。モディファイアは USD 書き出し時に評価する。
        for o in scene.objects:
            o.select_set(False)
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project(island_margin=.02)
        bpy.ops.object.mode_set(mode="OBJECT")
        ao = look.bake_ao(obj, 1024, samples=16)
        name = re.sub(r"[^a-zA-Z0-9_]", "_", obj.name) + "_color"
        look.color_texture(obj, color, ao, name)


def render_environment(scene, output):
    # Area lights 自体はカメラに写らないので、同位置・寸法の発光面で全周へ渡す。
    # 家具と機材は写さない（焼き込んだ模型が反射に二重出現するのを防ぐ）。
    from mathutils import Euler
    for obj in list(scene.objects):
        if obj.type == "MESH" or obj.instance_type == "COLLECTION":
            obj.hide_render = True
    for light in [o for o in scene.objects if o.type == "LIGHT" and not o.hide_render]:
        if light.data.type != "AREA":
            raise ValueError(f"環境光への変換は Area light に対応: {light.name}")
        data = light.data
        width = data.size
        depth = data.size_y if data.shape in {"RECTANGLE", "ELLIPSE"} else data.size
        area = width * depth * (math.pi / 4 if data.shape in {"DISK", "ELLIPSE"} else 1)
        bpy.ops.mesh.primitive_plane_add(size=1)
        proxy = bpy.context.object
        proxy.name = "environment_" + light.name
        proxy.matrix_world = light.matrix_world.copy()
        proxy.scale = (width, depth, 1)
        material = bpy.data.materials.new(proxy.name)
        material.use_nodes = True
        nodes = material.node_tree.nodes
        nodes.clear()
        emission = nodes.new("ShaderNodeEmission")
        emission.inputs["Color"].default_value = (*data.color, 1)
        emission.inputs["Strength"].default_value = data.energy / (math.pi * area)
        out = nodes.new("ShaderNodeOutputMaterial")
        material.node_tree.links.new(emission.outputs[0], out.inputs[0])
        proxy.data.materials.append(material)
        light.hide_render = True
    camera_data = bpy.data.cameras.new("environment_probe")
    camera_data.type = "PANO"
    camera_data.panorama_type = "EQUIRECTANGULAR"
    camera = bpy.data.objects.new("environment_probe", camera_data)
    scene.collection.objects.link(camera)
    # 上で非表示にした機材も位置の中心を求めるときには含める。
    instances = [o for o in scene.objects if o.instance_type == "COLLECTION"]
    camera.location = sum((o.matrix_world.translation for o in instances), Vector()) / len(instances) + Vector((0, 0, .15))
    camera.rotation_euler = Euler((math.pi / 2, 0, 0))
    scene.camera = camera
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 32
    scene.cycles.use_denoising = False
    scene.render.resolution_x = 1024
    scene.render.resolution_y = 512
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_depth = "16"
    scene.render.filepath = str(output / "environment.exr")
    bpy.ops.render.render(write_still=True)


def export_assets(source, output, bake=True):
    bpy.ops.wm.open_mainfile(filepath=str(source))
    scene = bpy.context.scene
    layout = layout_from_scene(scene)
    libraries = {}
    for instance in gear_instances(scene):
        library = instance.instance_collection.library
        if library is None:
            raise ValueError(f"機材は gear/<id>.blend にリンクしてください: {instance.name}")
        libraries[instance.name] = (Path(bpy.path.abspath(library.filepath)), instance.instance_collection.name)
    if set(layout["tray"]) != {"mixer", "trackKnobs"}:
        raise ValueError("mixer と trackKnobs の置き場を指定してください")
    output.mkdir(parents=True, exist_ok=True)
    if bake:
        bake_surfaces(scene, output)
    furniture = [o for o in scene.objects if o.type == "MESH" and not o.hide_render]
    export_usdz(furniture, output / "desk.usdz")
    render_environment(scene, output)
    sys.path.insert(0, str(HERE))
    import gear_build
    for gid, (library, collection_name) in libraries.items():
        bpy.ops.wm.open_mainfile(filepath=str(library))
        collection = bpy.data.collections[collection_name]
        root = bpy.data.objects.get(gid)
        if root is None or any(abs(a - b) > 1e-6 for row_a, row_b in zip(root.matrix_world, Matrix.Identity(4)) for a, b in zip(row_a, row_b)):
            raise ValueError(f"機材単体の原点・回転・縮尺を確認してください: {gid}")
        export_usdz(collection.all_objects, output / f"{gid}.usdz")
        if gid != "nanokontrol":
            spec = gear_build.load_spec(gid)
            (output / f"{gid}.json").write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n")
    (output / "desk_layout.json").write_text(json.dumps(layout, ensure_ascii=False, indent=2) + "\n")
    return layout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", type=Path, default=STUDIO)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--skip-bake", action="store_true", help="配置・材質確認用（接地 AO を省略）")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    layout = export_assets(args.scene.resolve(), args.output.resolve(), bake=not args.skip_bake)
    print(f"Exported {len(layout['gear'])} gear + studio to {args.output}", flush=True)


if __name__ == "__main__":
    main()
