#!/usr/bin/env python3
"""Offline regression tests; only Python standard library and /bin/sh required."""
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
TARGETS = json.loads((ROOT / "scripts/ios-identities.json").read_text())

class IdentityTests(unittest.TestCase):
    def environment(self, target, bundle, name, config):
        dev = config == "Debug"
        if dev:
            bundle = bundle.replace(".LiveActivity", ".dev.LiveActivity") if bundle.endswith(".LiveActivity") else bundle + ".dev"
            name += " Dev"
        icon = "AppIcon-Dev" if dev else ("AppIcon" if target == "TailViewIOS" else "")
        return dict(PATH=os.environ.get("PATH", "/usr/bin:/bin"), CONFIGURATION=config,
                    TARGET_NAME=target, PRODUCT_BUNDLE_IDENTIFIER=bundle,
                    APP_DISPLAY_NAME=name, ASSETCATALOG_COMPILER_APPICON_NAME=icon)

    def guard(self, env):
        return subprocess.run(["/bin/sh", str(ROOT / "scripts/validate-ios-identity.sh")],
                              env=env, capture_output=True, text=True)

    def test_valid_identities_and_missing_or_incorrect_configuration(self):
        for target, info, bundle, name in TARGETS:
            for config in ("Debug", "Release"):
                env = self.environment(target, bundle, name, config)
                with self.subTest(target=target, config=config):
                    self.assertEqual(self.guard(env).returncode, 0)
                keys = ["CONFIGURATION", "TARGET_NAME", "PRODUCT_BUNDLE_IDENTIFIER", "APP_DISPLAY_NAME"]
                if target != "TailViewLiveActivity" and env["ASSETCATALOG_COMPILER_APPICON_NAME"]:
                    keys.append("ASSETCATALOG_COMPILER_APPICON_NAME")
                for key in keys:
                    for replacement in (None, "unexpected"):
                        bad = env.copy()
                        if replacement is None:
                            del bad[key]
                        else:
                            bad[key] = replacement
                        with self.subTest(target=target, config=config, key=key, replacement=replacement):
                            self.assertNotEqual(self.guard(bad).returncode, 0)
                other = self.environment(target, bundle, name, "Release" if config == "Debug" else "Debug")
                mixed = env | {"PRODUCT_BUNDLE_IDENTIFIER": other["PRODUCT_BUNDLE_IDENTIFIER"]}
                self.assertNotEqual(self.guard(mixed).returncode, 0)

    def test_plist_configuration_and_dev_assets(self):
        for target, info, bundle, name in TARGETS:
            plist = plistlib.loads((ROOT / info).read_bytes())
            self.assertEqual(plist["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")
            self.assertEqual(plist["CFBundleDisplayName"], "$(APP_DISPLAY_NAME)")
            if target == "BackgroundTranscriber":
                self.assertEqual(plist["BGTaskSchedulerPermittedIdentifiers"], ["$(PRODUCT_BUNDLE_IDENTIFIER).transcription"])
                source = (ROOT / "BackgroundTranscriber/TranscriptionCoordinator.swift").read_text()
                self.assertIn('permitted == [bundleID + ".transcription"]', source)
                self.assertIn('preconditionFailure("Invalid Background Transcriber task identity configuration")', source)
            if target == "TailViewIOS":
                source = (ROOT / "IOSViewer/SavedMacStore.swift").read_text()
                self.assertIn('return bundleID + ".saved-macs"', source)
                self.assertIn('preconditionFailure("Invalid TailView iOS identity configuration")', source)
            if target == "TailViewLiveActivity":
                continue
            catalog = (ROOT / info).parent / "DevAssets.xcassets/AppIcon-Dev.appiconset"
            contents = json.loads((catalog / "Contents.json").read_text())
            self.assertEqual(len(contents["images"]), 1)
            entry = contents["images"][0]
            self.assertEqual((entry["idiom"], entry["platform"], entry["size"]), ("universal", "ios", "1024x1024"))
            png = (catalog / entry["filename"]).read_bytes()
            self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", png[16:24]), (1024, 1024))
            self.assertEqual(png[25], 2, "Opaque RGB PNG required")

if __name__ == "__main__":
    unittest.main(verbosity=2)
