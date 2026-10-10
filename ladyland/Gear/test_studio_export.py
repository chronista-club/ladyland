"""Blender --background --python ladyland/Gear/test_studio_export.py"""

import importlib.util
import math
from pathlib import Path
import unittest

import bpy


class StudioExportTests(unittest.TestCase):
    def setUp(self):
        path = Path(__file__).with_name("studio_export.py")
        self.assertTrue(path.is_file(), "studio から配置を書き出す実装が必要")
        spec = importlib.util.spec_from_file_location("studio_export", path)
        self.export = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.export)
        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = bpy.context.scene
        # 幅 1m、奥行き .2m、高さ .08m の機材。中心は底面。
        collection = bpy.data.collections.new("Test gear")
        bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, .04))
        body = bpy.context.object
        body.dimensions = (1, .2, .08)
        for owner in list(body.users_collection):
            owner.objects.unlink(body)
        collection.objects.link(body)
        gear = bpy.data.objects.new("keyboard", None)
        gear.instance_type = "COLLECTION"
        gear.instance_collection = collection
        gear.location = (-1, .02, .74)
        gear.rotation_euler.z = math.pi / 2
        scene.collection.objects.link(gear)
        self.gear = gear
        bpy.ops.mesh.primitive_cube_add(size=1, location=(-1, 0, .72))
        shelf = bpy.context.object
        shelf.name = "Shelf"
        shelf.dimensions = (.4, 1.4, .04)
        shelf["ladyland_surface"] = True
        tray = bpy.data.objects.new("Mixer tray", None)
        tray["ladyland_tray"] = "mixer"
        tray.location = (-1, -.6, .74)
        scene.collection.objects.link(tray)
        data = bpy.data.cameras.new("Camera")
        data.type = "ORTHO"
        data.ortho_scale = 3
        camera = bpy.data.objects.new("Camera", data)
        camera.location = (0, -3, 2)
        camera.rotation_euler = (math.pi / 2, 0, 0)
        scene.collection.objects.link(camera)
        scene.camera = camera
        scene.render.resolution_x = 1500
        scene.render.resolution_y = 1200
        bpy.context.view_layer.update()

    def test_pose_surface_and_camera_use_application_axes(self):
        layout = self.export.layout_from_scene(bpy.context.scene)
        gear = layout["gear"][0]
        self.assertEqual(gear["center"], [-1000, -20])
        self.assertAlmostEqual(gear["elevation"], 740, places=2)
        self.assertAlmostEqual(gear["yaw"], 90, places=3)
        self.assertEqual(gear["size"], [1000, 200])
        self.assertAlmostEqual(gear["height"], 80, places=2)
        self.assertAlmostEqual(layout["surfaces"][0]["elevation"], 740, places=2)
        self.assertEqual(layout["tray"]["mixer"], [-1000, 600])
        self.assertAlmostEqual(layout["trayElevation"], 740, places=2)
        self.assertEqual(layout["camera"]["from"], [0, 2000, 3000])
        self.assertEqual(layout["camera"]["projection"], "orthographic")
        self.assertEqual(layout["camera"]["orthographicScale"], 3000)
        self.assertEqual(layout["camera"]["aspectRatio"], 1.25)
        self.assertEqual(layout["camera"]["scaleDirection"], "horizontal")

    def test_tilt_and_scale_are_rejected_instead_of_silently_flattened(self):
        for rotation, scale in [((.1, 0, 0), (1, 1, 1)), ((0, 0, 0), (2, 1, 1))]:
            with self.subTest(rotation=rotation, scale=scale):
                self.gear.rotation_euler = rotation
                self.gear.scale = scale
                bpy.context.view_layer.update()
                with self.assertRaises(ValueError):
                    self.export.layout_from_scene(bpy.context.scene)

    def test_layout_extraction_does_not_move_authored_objects(self):
        before = {o.name: o.matrix_world.copy() for o in bpy.context.scene.objects}
        camera = bpy.context.scene.camera
        self.export.layout_from_scene(bpy.context.scene)
        self.assertEqual(before, {o.name: o.matrix_world for o in bpy.context.scene.objects})
        self.assertEqual(camera, bpy.context.scene.camera)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(StudioExportTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
