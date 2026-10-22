#!/usr/bin/env python3
"""実際の配布バンドルで更新ポリシーと Sparkle の組み込みを検証する。

scripts/build-app.sh の後に実行。アプリは起動せず、機材にも接続しない。
mem_1CgGUt6c4wBCNzowECCFsR / design/13-app-updates.md
"""
import base64
from pathlib import Path
import plistlib
import subprocess
import unittest


APP = Path(__file__).resolve().parent.parent / "dist" / "Ladyland.app"


class AppBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contents = APP / "Contents"
        with (cls.contents / "Info.plist").open("rb") as source:
            cls.info = plistlib.load(source)

    def test_scheduled_checks_never_install_automatically(self):
        self.assertIs(self.info.get("SUEnableAutomaticChecks"), True)
        self.assertIs(self.info.get("SUAllowsAutomaticUpdates"), False)
        self.assertIs(self.info.get("SUAutomaticallyUpdate"), False)
        self.assertEqual(self.info.get("SUScheduledCheckInterval"), 86400)

    def test_stable_feed_and_signing_key(self):
        self.assertEqual(self.info.get("SUFeedURL"),
                         "https://github.com/chronista-club/ladyland/releases/latest/download/appcast.xml")
        key = base64.b64decode(self.info.get("SUPublicEDKey", ""), validate=True)
        self.assertEqual(len(key), 32)

    def test_build_number_is_numeric_and_commit_is_separate(self):
        self.assertRegex(self.info["CFBundleVersion"], r"^[1-9][0-9]*$")
        self.assertRegex(self.info.get("LadylandCommit", ""), r"^[0-9a-f]{7,40}$")

    def test_framework_and_nested_updater_are_bundled(self):
        framework = self.contents / "Frameworks" / "Sparkle.framework"
        for relative in ("Sparkle", "Versions/B/Autoupdate", "Versions/B/Updater.app",
                         "Versions/B/XPCServices/Installer.xpc", "Versions/B/XPCServices/Downloader.xpc"):
            with self.subTest(relative=relative):
                self.assertTrue((framework / relative).exists(), relative)
        binary = str(self.contents / "MacOS" / "Ladyland")
        libraries = subprocess.check_output(["otool", "-L", binary], text=True)
        self.assertIn("@rpath/Sparkle.framework/", libraries)
        commands = subprocess.check_output(["otool", "-l", binary], text=True)
        self.assertIn("path @executable_path/../Frameworks", commands)


if __name__ == "__main__":
    unittest.main()
