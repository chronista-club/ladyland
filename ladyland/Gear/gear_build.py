"""配置データ（`Gear/<id>.json`）から機材を Blender で組み、USDZ に書き出す汎用の組み立て役
（2026-10-05、mako「同様に、LPD8 と、Korg Keystage、ROTO-Control も詳細モデリングを
blend で出来ないかな？」「FGDP-50 も」「Numa Compact X SE も」）。

nanoKONTROL2 は `nanokontrol.py` が個別に組む（先に作ったもの）。それ以外はここ。
機材ごとの違いは JSON の数字だけにする — 形と材質は部品の種類（kind）で決まる。

JSON（単位 mm、座標はアプリと同じ: 機材の中心が原点、x = 右 +、z = 手前 +）:

    {
      "id": "lpd8", "title": "LPD8 mk2",
      "size": [W, D, H],            # 外形（H は操作子込み）
      "body_height": 20,            # 筐体の厚み（操作子はこの上に乗る）
      "body_color": [r, g, b],      # 線形 0-1
      "corner": 4,                  # 筐体の角の丸み
      "source": "測った元（写真・説明書の URL）",
      "parts": [
        {"name": "pad_1", "kind": "pad", "center": [x, z], "size": [w, d, h],
         "color": [r, g, b] (省略可), "travel": 30 (フェーダーだけ)}
      ],
      "sections": [{"id": "lpd8.pads", "kind": "pads", "parts": ["pad_1", ...], "ccs": [..]}]
    }

部品の種類: knob / encoder / fader / button / pad / key_white / key_black / display /
wheel / grille / led / decor。可動部は名前で掴む（アプリが動かす）ので、名前は JSON のまま。

使い方: Blender の Scripting タブか Blender MCP で
    exec(open(".../gear_build.py").read()); build_and_export("lpd8")
"""

import json
import os

import bmesh
import bpy
from mathutils import Vector

MM = 0.001
HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else \
    "/Users/makomac/repos/ladyland/ladyland/Gear"
OUT_DIR = os.path.expanduser("~/Library/Application Support/ladyland/gear")


# MARK: - 材質


def _principled(m):
    # ⚠️ 節点名は UI の言語で訳される — 種類で引く
    return next(n for n in m.node_tree.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")


def material(name, rgb, rough=0.5, metal=0.0, emission=None):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = _principled(m)
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission[0], 1)
        bsdf.inputs["Emission Strength"].default_value = emission[1]
    m.diffuse_color = (*rgb, 1)
    return m


# 部品の種類ごとの既定の見た目（JSON の "color" で色だけ上書きできる）
LOOK = {
    "knob": dict(rgb=(0.05, 0.05, 0.055), rough=0.45),
    "encoder": dict(rgb=(0.06, 0.06, 0.065), rough=0.4, metal=0.3),
    "fader": dict(rgb=(0.03, 0.03, 0.032), rough=0.55),
    "button": dict(rgb=(0.09, 0.09, 0.095), rough=0.7),
    "pad": dict(rgb=(0.12, 0.12, 0.125), rough=0.85),
    "key_white": dict(rgb=(0.82, 0.82, 0.8), rough=0.35),
    "key_black": dict(rgb=(0.015, 0.015, 0.017), rough=0.35),
    "display": dict(rgb=(0.01, 0.012, 0.016), rough=0.08),
    "wheel": dict(rgb=(0.04, 0.04, 0.042), rough=0.6),
    "grille": dict(rgb=(0.025, 0.025, 0.027), rough=0.9),
    "led": dict(rgb=(0.9, 0.9, 0.88), rough=0.3),
    "decor": dict(rgb=(0.8, 0.8, 0.78), rough=0.5),
}


def part_material(gear_id, part):
    kind = part["kind"]
    base = dict(LOOK.get(kind, LOOK["decor"]))
    if "color" in part:
        base["rgb"] = tuple(part["color"])
        name = f"{gear_id}_{kind}_{'_'.join(f'{c:.2f}' for c in part['color'])}"
    else:
        name = f"{gear_id}_{kind}"
    if kind == "display":
        base["emission"] = ((0.05, 0.07, 0.09), 0.4)  # 消えた画面のうっすらした光
    return material(name, **base)


# MARK: - 形


def _finish(coll, ob, mat, parent, loc_mm, bevel_mm, segments=3):
    ob.data.materials.append(mat)
    coll.objects.link(ob)
    if parent:
        ob.parent = parent
    ob.location = Vector(loc_mm) * MM
    if bevel_mm > 0:
        b = ob.modifiers.new("bevel", "BEVEL")
        b.width = bevel_mm * MM
        b.segments = segments
        b.limit_method = "ANGLE"
    return ob


def box(coll, name, size_mm, loc_mm, mat, parent=None, bevel_mm=0.0):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size_mm) * MM, verts=bm.verts)
    bm.to_mesh(me)
    bm.free()
    return _finish(coll, bpy.data.objects.new(name, me), mat, parent, loc_mm, bevel_mm)


def cylinder(coll, name, radius_mm, depth_mm, loc_mm, mat, parent=None, taper=0.92, bevel_mm=0.6):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=40, radius1=radius_mm * MM,
        radius2=radius_mm * MM * taper, depth=depth_mm * MM)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    return _finish(coll, bpy.data.objects.new(name, me), mat, parent, loc_mm, bevel_mm, 2)


def wheel(coll, name, radius_mm, width_mm, loc_mm, mat, parent=None):
    """ピッチ / モジュレーションのホイール — 横向きの円柱（x 軸まわりに回る）"""
    ob = cylinder(coll, name, radius_mm, width_mm, loc_mm, mat, parent, taper=1.0, bevel_mm=0.8)
    ob.rotation_euler = (0, 1.5708, 0)
    return ob


# MARK: - 組み立て


# MARK: - 鍵盤（"keybed" から白鍵・黒鍵を生成）

# 半音 → 黒鍵か（C C# D D# E F F# G G# A A# B）
_BLACK = {1, 3, 6, 8, 10}
# 黒鍵が直前の白鍵の右端からどれだけずれるか（白鍵幅に対する比。実機の不等間隔を近似）
_BLACK_OFFSET = {1: -0.08, 3: 0.08, 6: -0.12, 8: 0.0, 10: 0.12}


def expand_keybed(spec):
    """"keybed": {"lowest": 21, "count": 88, "left": x, "front": z,
    "white_width": 23.5, "white_length": 150, "black_width": 13.7,
    "black_length": 95, "height": 12, "base": 8}
    → key_<midi> の部品（白鍵は kind=key_white、黒鍵は key_black）。left は一番左の
    白鍵の左端、front は白鍵の手前端（z mm）"""
    kb = spec.get("keybed")
    if not kb:
        return []
    ww, wl = kb["white_width"], kb["white_length"]
    bw, bl = kb["black_width"], kb["black_length"]
    h, base = kb.get("height", 12), kb.get("base", 6)
    parts = []
    white_index = -1
    for i in range(kb["count"]):
        note = kb["lowest"] + i
        semitone = note % 12
        if semitone not in _BLACK:
            white_index += 1
            x = kb["left"] + ww * (white_index + 0.5)
            parts.append({"name": f"key_{note}", "kind": "key_white",
                          "center": [x, kb["front"] - wl / 2], "size": [ww - 0.6, wl, h], "base": base})
        else:
            x = kb["left"] + ww * (white_index + 1) + ww * _BLACK_OFFSET[semitone]
            parts.append({"name": f"key_{note}", "kind": "key_black",
                          "center": [x, kb["front"] - wl + bl / 2], "size": [bw, bl, h + 6], "base": base})
    return parts


def load_spec(gear_id):
    with open(os.path.join(HERE, f"{gear_id}.json")) as f:
        spec = json.load(f)
    spec["parts"] = spec.get("parts", []) + expand_keybed(spec)
    return spec


def build(spec):
    gid = spec["id"]
    coll_name = spec["title"]
    prev_sel = [o.name for o in bpy.context.selected_objects]
    prev_active = bpy.context.view_layer.objects.active

    if coll_name in bpy.data.collections:
        old = bpy.data.collections[coll_name]
        for o in list(old.objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(old)
    coll = bpy.data.collections.new(coll_name)
    bpy.context.scene.collection.children.link(coll)

    root = bpy.data.objects.new(gid, None)
    root.empty_display_size = 0.05
    coll.objects.link(root)

    w, d, _h = spec["size"]
    top = spec["body_height"]
    body_mat = material(f"{gid}_body", tuple(spec.get("body_color", (0.02, 0.02, 0.022))), 0.45, 0.2)
    box(coll, "body", (w, d, top), (0, 0, top / 2), body_mat, root, bevel_mm=spec.get("corner", 2.5))

    white = material(f"{gid}_mark", (0.9, 0.9, 0.88), 0.4)
    groove = material(f"{gid}_groove", (0.004, 0.004, 0.004), 0.9)

    for part in spec["parts"]:
        kind = part["kind"]
        x, z = part["center"]
        pw, pd, ph = part["size"]
        y0 = part.get("base", top)  # 乗る高さ（鍵盤など筐体の天面より低いものは JSON で）
        mat = part_material(gid, part)
        name = part["name"]
        loc = (x, -z, y0 + ph / 2)
        if kind in ("knob", "encoder"):
            ob = cylinder(coll, name, pw / 2, ph, loc, mat, root)
            if kind == "knob":  # 指標線（奥向き）
                box(coll, f"{name}_mark", (0.9, pw * 0.35, 0.3), (0, pw * 0.22, ph / 2 + 0.1), white, ob)
            else:  # エンコーダーは滑り止めのローレット風（細い溝の輪）
                cylinder(coll, f"{name}_cap", pw * 0.42, 0.4, (0, 0, ph / 2 + 0.15), mat, ob, 1.0, 0.1)
        elif kind == "fader":
            travel = part.get("travel", 30)
            box(coll, f"{name}_slot", (2.4, travel + pd, 0.6), (x, -z, y0 + 0.3), groove, root)
            ob = box(coll, name, (pw, pd, ph), loc, mat, root, bevel_mm=1.0)
            box(coll, f"{name}_line", (pw * 0.95, 1.0, 0.3), (0, 0, ph / 2 + 0.15), white, ob)
        elif kind == "pad":
            ob = box(coll, name, (pw, pd, ph), loc, mat, root, bevel_mm=min(2.5, pw * 0.08))
        elif kind in ("key_white", "key_black"):
            ob = box(coll, name, (pw, pd, ph), loc, mat, root, bevel_mm=0.6 if kind == "key_white" else 0.8)
        elif kind == "display":
            ob = box(coll, name, (pw, pd, ph), loc, mat, root, bevel_mm=0.4)
        elif kind == "wheel":
            ob = wheel(coll, name, pd / 2, pw, (x, -z, y0 + ph - pd / 2), mat, root)
        elif kind == "grille":
            ob = box(coll, name, (pw, pd, ph), loc, mat, root, bevel_mm=min(2.0, pd * 0.2))
        else:  # button / led / decor
            ob = box(coll, name, (pw, pd, ph), loc, mat, root,
                     bevel_mm=min(1.6, min(pw, pd) * 0.35) if kind == "button" else 0.3)

    for o in bpy.context.selected_objects:
        o.select_set(False)
    for n in prev_sel:
        if n in bpy.data.objects:
            bpy.data.objects[n].select_set(True)
    bpy.context.view_layer.objects.active = prev_active
    return coll


def export(spec, coll):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{spec['id']}.usdz")
    prev_sel = [o.name for o in bpy.context.selected_objects]
    prev_active = bpy.context.view_layer.objects.active
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for o in coll.objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = bpy.data.objects[spec["id"]]
    bpy.ops.wm.usd_export(
        filepath=path, selected_objects_only=True, export_materials=True,
        generate_preview_surface=True, export_textures_mode="NEW", overwrite_textures=True,
        export_animation=False, convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y", evaluation_mode="RENDER", root_prim_path="/root")
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    for n in prev_sel:
        if n in bpy.data.objects:
            bpy.data.objects[n].select_set(True)
    bpy.context.view_layer.objects.active = prev_active
    # アプリが部品とセクションを読む配置データ（鍵盤は展開済み）も同じ場所へ
    with open(os.path.join(OUT_DIR, f"{spec['id']}.json"), "w") as f:
        json.dump(spec, f, ensure_ascii=False, indent=1)
    return path


def build_and_export(gear_id):
    spec = load_spec(gear_id)
    coll = build(spec)
    return export(spec, coll)


# MARK: - 写真と重ねて確かめる


def compare(spec, photo, mm_per_px, body_center_px, out_render, out_overlay):
    """真上からの正投影を写真と同じ縮尺で撮り、写真に半分重ねた画像を書く。
    mm_per_px = (横, 縦)、body_center_px = 写真の中の筐体の中心 (x, y)（上基準）"""
    import numpy as np
    scene = bpy.context.scene
    img = bpy.data.images.load(photo, check_existing=True)
    W, H = img.size
    sx, sy = mm_per_px
    cx, cy = body_center_px
    r = scene.render
    keep = (scene.camera, r.engine, r.resolution_x, r.resolution_y, r.filepath,
            r.image_settings.file_format, scene.cycles.samples)
    coll = bpy.data.collections[spec["title"]]
    others = [c for c in scene.collection.children if c.name not in (coll.name, "desk_look")]
    hid = {c.name: c.hide_render for c in others}
    for c in others:
        c.hide_render = True
    # 照明の発光板は真上のカメラに写り込むので、比較のあいだだけカメラから隠す（光は残る）
    look = bpy.data.collections.get("desk_look")
    emitters = [o for o in (look.objects if look else []) if o.name.startswith("softbox")]
    for o in emitters:
        o.visible_camera = False
    cam_data = bpy.data.cameras.new("compare_cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = W * sx * MM
    cam = bpy.data.objects.new("compare_cam", cam_data)
    coll.objects.link(cam)
    # 写真の中心と筐体の中心の差（写真の上 = 奥 = Blender の +y）
    cam.location = ((W / 2 - cx) * sx * MM, (cy - H / 2) * sy * MM, 1.0)
    scene.camera = cam
    r.engine = "CYCLES"
    r.resolution_x, r.resolution_y = W, H
    r.pixel_aspect_x, r.pixel_aspect_y = 1, sy / sx if sx else 1
    r.filepath = out_render
    r.image_settings.file_format = "PNG"
    scene.cycles.samples = 24
    try:
        bpy.ops.render.render(write_still=True)
    finally:
        bpy.data.objects.remove(cam, do_unlink=True)
        for c in others:
            c.hide_render = hid[c.name]
        for o in emitters:
            o.visible_camera = True
        r.pixel_aspect_x = r.pixel_aspect_y = 1
        (scene.camera, r.engine, r.resolution_x, r.resolution_y, r.filepath,
         r.image_settings.file_format, scene.cycles.samples) = keep
    a = bpy.data.images.load(out_render)
    pa = np.array(a.pixels[:]).reshape(H, W, 4)
    pb = np.array(img.pixels[:]).reshape(H, W, 4)
    mix = pa.copy()
    mix[..., :3] = 0.5 * pa[..., :3] + 0.5 * pb[..., :3]
    o = bpy.data.images.new("compare_overlay", W, H)
    o.pixels[:] = mix.ravel()
    o.filepath_raw = out_overlay
    o.file_format = "PNG"
    o.save()
    for im in (a, o):
        bpy.data.images.remove(im)
    return out_overlay
