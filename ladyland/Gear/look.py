"""机の「見た目」を Blender で仕上げて書き出す（2026-10-04、mako「BLENDER の時点で
ライティングまで終えられてるといいな」「見た目の雰囲気は、ここでしっかり落とし込む。
各クライアントは微調整くらい」→ 方針「A + AO」）。

- **A = 環境光**: スタジオの光（ソフトボックス）を発光する板で組み、機材の位置から
  全周を Cycles で撮って `environment.exr` に書く。アプリはこれで照らす
  （RealityKit は USD の中のライトを読まないので、光は画像で運ぶ）
- **AO**: 動かないものの暗がりだけ焼く — 机の面の接地の暗がり（`desk.usdz`）と
  筐体の隙間（`nanokontrol.usdz` の筐体の色に合成）

前提: `nanokontrol.py` で「nanoKONTROL2」コレクションができていること。
このスクリプトは「desk_look」コレクションだけを作り直し、シーンのレンダー設定・
カメラ・選択は最後に元へ戻す。

座標: Blender は Z が上、手前が -Y。アプリの机（中心 z = +0.04 m）は Blender の y = -0.04。
"""

import os

import bmesh
import bpy
import numpy as np
from mathutils import Euler, Vector

OUT_DIR = os.path.expanduser("~/Library/Application Support/ladyland/gear")
TEX_DIR = os.path.join(OUT_DIR, "textures")
LOOK = "desk_look"
GEAR = "nanoKONTROL2"


# MARK: - 小物


def principled(m):
    # ⚠️ 節点名は UI の言語で訳される — 種類で引く
    return next(n for n in m.node_tree.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")


def material(name, rgb, rough=0.5, metal=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = principled(m)
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    m.diffuse_color = (*rgb, 1)
    return m


def emission(name, rgb, strength):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*rgb, 1)
    em.inputs["Strength"].default_value = strength
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    return m


def plane(coll, name, size, loc, rot, mat):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=0.5)
    bmesh.ops.scale(bm, vec=Vector((size[0], size[1], 1)), verts=bm.verts)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    ob.location = loc
    ob.rotation_euler = rot
    coll.objects.link(ob)
    return ob


def aim(ob, target):
    """板の表（+Z）を target へ向ける"""
    direction = Vector(target) - ob.location
    ob.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()


def box_uv(mesh):
    """箱の UV — 面ごとに法線の主軸で投影（スマート UV 展開は edit mode が要るので使わない）"""
    bm = bmesh.new()
    bm.from_mesh(mesh)
    uv = bm.loops.layers.uv.verify()
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    zs = [v.co.z for v in bm.verts]
    lo = Vector((min(xs), min(ys), min(zs)))
    span = Vector((max(xs) - lo.x or 1, max(ys) - lo.y or 1, max(zs) - lo.z or 1))
    for face in bm.faces:
        n = face.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        a, b = [(1, 2), (0, 2), (0, 1)][axis]
        for loop in face.loops:
            p = (loop.vert.co - lo)
            loop[uv].uv = (p[a] / span[a], p[b] / span[b])
    bm.to_mesh(mesh)
    bm.free()


def bake_ao(ob, size, samples=64):
    """ob の AO を画像に焼く（ほかの機材の影も入る）。0-1 の配列を返す"""
    img = bpy.data.images.get(f"{ob.name}_ao") or bpy.data.images.new(f"{ob.name}_ao", size, size)
    img.scale(size, size)
    m = ob.active_material
    node = m.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    m.node_tree.nodes.active = node
    scene = bpy.context.scene
    scene.cycles.samples = samples
    with bpy.context.temp_override(
        object=ob, active_object=ob, selected_objects=[ob], selected_editable_objects=[ob]
    ):
        bpy.ops.object.bake(type="AO", use_clear=True, margin=4)
    m.node_tree.nodes.remove(node)
    return np.array(img.pixels[:]).reshape(size, size, 4)[:, :, 0]


def color_texture(ob, rgb, ao, name, strength=1.0):
    """色 × AO を画像にして Base Color に直結（USD の Preview Surface に乗る形）"""
    size = ao.shape[0]
    shade = 1.0 - strength * (1.0 - ao)
    pixels = np.ones((size, size, 4), dtype=np.float32)
    for i in range(3):
        linear = np.clip(rgb[i] * shade, 0, 1)
        # ⚠️ PNG は sRGB で読まれる — 線形の値のまま書くと約 1/10 の明るさになる
        pixels[:, :, i] = np.where(
            linear <= 0.0031308, 12.92 * linear, 1.055 * np.power(linear, 1 / 2.4) - 0.055)
    img = bpy.data.images.get(name) or bpy.data.images.new(name, size, size)
    img.scale(size, size)
    img.pixels[:] = pixels.ravel()
    os.makedirs(TEX_DIR, exist_ok=True)
    img.filepath_raw = os.path.join(TEX_DIR, f"{name}.png")
    img.file_format = "PNG"
    img.save()
    m = ob.active_material
    tex = m.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = img
    m.node_tree.links.new(tex.outputs["Color"], principled(m).inputs["Base Color"])
    return img


# MARK: - 組み立て


def build_look():
    if LOOK in bpy.data.collections:
        old = bpy.data.collections[LOOK]
        for o in list(old.objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(old)
    coll = bpy.data.collections.new(LOOK)
    bpy.context.scene.collection.children.link(coll)

    # 机の面（アプリの机と同じ広さ 0.9 × 0.42 m、天面 z = 0）
    desk_mat = material("desk_surface", (0.055, 0.052, 0.05), 0.8)
    desk = plane(coll, "desk", (0.9, 0.42), (0, -0.04, 0), (0, 0, 0), desk_mat)

    # 光 — 発光する板（全周の撮影に写り込む = 環境光になる）
    key = plane(coll, "softbox_key", (0.7, 0.45), (0.05, -0.25, 0.6), (0, 0, 0),
                emission("softbox_key", (1.0, 0.95, 0.88), 9.0))
    aim(key, (0, 0, 0))
    rim = plane(coll, "softbox_rim", (0.9, 0.08), (0, 0.45, 0.28), (0, 0, 0),
                emission("softbox_rim", (0.78, 0.86, 1.0), 6.0))
    aim(rim, (0, 0, 0.02))
    fill = plane(coll, "softbox_fill", (0.4, 0.3), (-0.7, -0.4, 0.15), (0, 0, 0),
                 emission("softbox_fill", (1.0, 0.92, 0.85), 1.2))
    aim(fill, (0, 0, 0.02))

    # ワールド — ほぼ黒（スタジオの暗がり）
    world = bpy.context.scene.world or bpy.data.worlds.new("World")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.bl_idname == "ShaderNodeBackground")
    bg.inputs["Color"].default_value = (0.012, 0.012, 0.014, 1)
    bg.inputs["Strength"].default_value = 1.0
    return coll, desk


def render_environment(coll):
    """機材の位置から全周を撮る（機材は写さない）→ environment.exr"""
    scene = bpy.context.scene
    cam_data = bpy.data.cameras.new("env_probe")
    cam_data.type = "PANO"
    cam_data.panorama_type = "EQUIRECTANGULAR"
    cam = bpy.data.objects.new("env_probe", cam_data)
    cam.location = (0, 0, 0.06)
    cam.rotation_euler = Euler((1.5708, 0, 0))  # 地平線を水平に
    coll.objects.link(cam)

    gear = bpy.data.collections.get(GEAR)
    hide_before = gear.hide_render if gear else None
    if gear:
        gear.hide_render = True

    r = scene.render
    scene.camera = cam
    r.resolution_x, r.resolution_y, r.resolution_percentage = 1024, 512, 100
    r.image_settings.file_format = "OPEN_EXR"
    r.image_settings.color_depth = "16"
    r.filepath = os.path.join(OUT_DIR, "environment.exr")
    scene.cycles.samples = 64
    bpy.ops.render.render(write_still=True)

    if gear:
        gear.hide_render = hide_before
    bpy.data.objects.remove(cam, do_unlink=True)


def export_usdz(objects, path, active):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active
    bpy.ops.wm.usd_export(
        filepath=path, selected_objects_only=True, export_materials=True,
        generate_preview_surface=True, export_textures_mode="NEW", overwrite_textures=True,
        export_animation=False,
        convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y", evaluation_mode="RENDER", root_prim_path="/root")


def main():
    scene = bpy.context.scene
    r = scene.render
    keep = dict(
        camera=scene.camera, engine=r.engine, rx=r.resolution_x, ry=r.resolution_y,
        rp=r.resolution_percentage, path=r.filepath, fmt=r.image_settings.file_format,
        depth=r.image_settings.color_depth, samples=scene.cycles.samples,
        sel=[o.name for o in bpy.context.selected_objects],
        active=bpy.context.view_layer.objects.active)
    # ⚠️ 開いているシーンの他のもの（既定の立方体やライト）が撮影と焼き込みに
    # 入らないよう、作業中だけレンダーから外す（最後に戻す）
    others = [c for c in scene.collection.children if c.name not in (GEAR, LOOK)]
    hidden_before = {c.name: c.hide_render for c in others}
    loose = [o for o in scene.collection.objects]
    loose_before = {o.name: o.hide_render for o in loose}
    for c in others:
        c.hide_render = True
    for o in loose:
        o.hide_render = True
    try:
        r.engine = "CYCLES"
        coll, desk = build_look()

        # AO — 机の面（接地の暗がり）と筐体の隙間
        box_uv(desk.data)
        desk_ao = bake_ao(desk, 1024)
        color_texture(desk, (0.055, 0.052, 0.05), desk_ao, "desk_color")
        body = bpy.data.objects.get("body")
        if body:
            box_uv(body.data)
            body_ao = bake_ao(body, 1024)
            # 黒い筐体は暗がりが見えにくい — 色を少しだけ持ち上げてから掛ける
            color_texture(body, (0.03, 0.03, 0.033), body_ao, "body_color")

        render_environment(coll)

        # 書き出し — 机と機材は別の USDZ（机は動かない、機材は部品を動かす）
        export_usdz([desk], os.path.join(OUT_DIR, "desk.usdz"), desk)
        gear = bpy.data.collections.get(GEAR)
        if gear:
            export_usdz(list(gear.objects), os.path.join(OUT_DIR, "nanokontrol.usdz"),
                        bpy.data.objects["nanokontrol"])
    finally:
        for c in others:
            c.hide_render = hidden_before[c.name]
        for o in loose:
            if o.name in bpy.data.objects:
                o.hide_render = loose_before[o.name]
        scene.camera = keep["camera"]
        r.engine = keep["engine"]
        r.resolution_x, r.resolution_y, r.resolution_percentage = keep["rx"], keep["ry"], keep["rp"]
        r.filepath = keep["path"]
        r.image_settings.file_format = keep["fmt"]
        r.image_settings.color_depth = keep["depth"]
        scene.cycles.samples = keep["samples"]
        for o in bpy.context.view_layer.objects:
            o.select_set(False)
        for name in keep["sel"]:
            if name in bpy.data.objects:
                bpy.data.objects[name].select_set(True)
        bpy.context.view_layer.objects.active = keep["active"]


if __name__ == "__main__":
    main()
