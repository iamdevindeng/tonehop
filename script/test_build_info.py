#!/usr/bin/python3
"""Isolated generator checks; never build the App or access audio services."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "generate_build_info", Path(__file__).with_name("generate_build_info.py"))
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class BuildInfoGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ToneHop build info 空格 ")
        self.root = Path(self.temporary.name)
        self.source = self.root / "ToneHop/Sources/A file.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("let value = 1\n")
        self.output = self.root / "build/Debug/ToneHop.app/Contents/Resources/BuildInfo.json"
        (self.root / ".gitignore").write_text("build/\n")
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=BuildInfo Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture baseline")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(["/usr/bin/git", "-C", str(self.root), *arguments],
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def generate(self, configuration="Debug"):
        return GENERATOR.generate(self.root, self.output, "0.1.0", "2", configuration)

    def test_deterministic_identity_and_paths_with_spaces(self):
        first = self.generate()
        modified = self.output.stat().st_mtime_ns
        self.assertEqual(first["gitWorkingTreeState"], "clean")
        self.assertEqual(len(first["gitCommit"]), 40)
        self.assertEqual(first, self.generate())
        self.assertEqual(modified, self.output.stat().st_mtime_ns)
        self.assertEqual(first, json.loads(self.output.read_text()))

    def test_source_change_changes_digest_and_marks_dirty(self):
        first = self.generate()
        self.source.write_text("let value = 2\n")
        second = self.generate()
        self.assertNotEqual(first["sourceDigest"], second["sourceDigest"])
        self.assertEqual(second["gitWorkingTreeState"], "dirty")

    def test_untracked_source_and_deletion_change_digest(self):
        baseline = self.generate()
        new_source = self.source.parent / "Untracked\n'quoted'.swift"
        new_source.write_text("let added = true\n")
        added = self.generate()
        self.assertEqual(added["sourceFileCount"], baseline["sourceFileCount"] + 1)
        self.assertNotEqual(added["sourceDigest"], baseline["sourceDigest"])
        self.assertEqual(added["gitWorkingTreeState"], "dirty")
        new_source.unlink()
        self.assertEqual(self.generate()["sourceDigest"], baseline["sourceDigest"])

    def test_logs_documents_evidence_and_generated_files_do_not_change_digest(self):
        baseline = self.generate()["sourceDigest"]
        for relative in ("README.md", "iterations/002/verification/evidence/result.json",
                         "build/logs/build.log", "ToneHop/Sources/Generated/BuildInfo.swift",
                         "ToneHop/Sources/Docs/design.md", "script/check.log"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unrelated changes\n")
        self.assertEqual(self.generate()["sourceDigest"], baseline)

    def test_shared_configuration_resources_scripts_and_entitlements_participate(self):
        previous = self.generate()["sourceDigest"]
        for relative in ("ToneHop/ToneHop.xcodeproj/project.pbxproj",
                         "ToneHop/ToneHop.xcodeproj/xcshareddata/xcschemes/ToneHop.xcscheme",
                         "ToneHop/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
                         "ToneHop/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png",
                         "script/test.sh", "ToneHop/Development.entitlements",
                         "ToneHop/Config.xcconfig"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("new input\n")
            current = self.generate()["sourceDigest"]
            self.assertNotEqual(current, previous)
            previous = current
        # Per-developer Xcode state is not an input to the shared product.
        private = self.root / "ToneHop/ToneHop.xcodeproj/xcuserdata/test.xcuserdatad/state"
        private.parent.mkdir(parents=True)
        private.write_text("window state\n")
        self.assertEqual(self.generate()["sourceDigest"], previous)

    def test_missing_git_replaces_old_metadata_but_preserves_source_digest(self):
        first = self.generate()
        shutil.rmtree(self.root / ".git")
        second = self.generate()
        self.assertEqual(second["gitCommit"], "unknown")
        self.assertEqual(second["gitWorkingTreeState"], "unknown")
        self.assertEqual(first["sourceDigest"], second["sourceDigest"])
        self.assertEqual(json.loads(self.output.read_text()), second)

    def test_missing_git_executable_reports_unknown(self):
        with mock.patch.object(GENERATOR.subprocess, "run", side_effect=FileNotFoundError):
            result = self.generate()
        self.assertEqual(result["gitCommit"], "unknown")
        self.assertEqual(result["gitWorkingTreeState"], "unknown")
        self.assertEqual(len(result["sourceDigest"]), 64)

    def test_configuration_changes_metadata_without_changing_source_digest(self):
        debug, release = self.generate("Debug"), self.generate("Release")
        self.assertEqual(debug["sourceDigest"], release["sourceDigest"])
        self.assertEqual(debug["configuration"], "Debug")
        self.assertEqual(release["configuration"], "Release")

    def test_cli_uses_xcode_build_settings_and_atomic_json_output(self):
        environment = dict(os.environ, MARKETING_VERSION="1.2.3", CURRENT_PROJECT_VERSION="17",
                           CONFIGURATION="Release", PYTHONDONTWRITEBYTECODE="1")
        subprocess.run(["/usr/bin/python3", str(Path(GENERATOR.__file__)),
                        "--root", str(self.root), "--output", str(self.output)],
                       env=environment, check=True, capture_output=True)
        result = json.loads(self.output.read_text())
        self.assertEqual(result["applicationVersion"], "1.2.3")
        self.assertEqual(result["buildNumber"], "17")
        self.assertEqual(result["configuration"], "Release")
        self.assertEqual(list(self.output.parent.glob(".BuildInfo-*")), [])


if __name__ == "__main__":
    unittest.main()
