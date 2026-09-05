import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import publish_release as release


class ReleaseTests(unittest.TestCase):
    tag = "v9.8.7"
    repo = "example/wispterm"

    def test_notes_have_versioned_bilingual_downloads_and_benchmark(self):
        for tag in (self.tag, "v10.0.1"):
            body = release.render_notes(tag, self.repo, "# Changes\n\nA feature and a fix.")
            self.assertIn("A feature and a fix.", body)
            self.assertEqual(body.count("## Downloads / 下载"), 1)
            self.assertIn("## Performance baseline / 性能基线", body)
            for name in release.required_assets(tag):
                self.assertIn(f"https://github.com/{self.repo}/releases/download/{tag}/{name}", body)
            self.assertNotIn("WispTerm-v", body)
        with self.assertRaises(ValueError):
            release.render_notes("../../bad", self.repo, "notes")
        with self.assertRaises(ValueError):
            release.render_notes(self.tag, self.repo, " ")

    def test_existing_baseline_text_is_retained(self):
        body = release.render_notes(self.tag, self.repo, "## 性能基线\n\nCustom measurements.")
        self.assertIn("Custom measurements.", body)
        self.assertEqual(body.count("性能基线\n"), 1)

    def test_every_asset_is_required_and_must_be_uploaded_and_nonempty(self):
        assets = [{"name": name, "state": "uploaded", "size": 10} for name in release.required_assets(self.tag)]
        self.assertEqual(release.missing_assets(self.tag, assets), set())
        for asset in assets:
            rest = [a for a in assets if a is not asset]
            self.assertEqual(release.missing_assets(self.tag, rest), {asset["name"]})
            self.assertEqual(release.missing_assets(self.tag, rest + [dict(asset, size=0)]), {asset["name"]})
            self.assertEqual(release.missing_assets(self.tag, rest + [dict(asset, state="starter")]), {asset["name"]})

    def test_partial_uploads_stay_draft_until_last_asset_and_retry_keeps_body(self):
        info = None
        bodies = []
        publications = []

        def gh(*args, check=True):
            nonlocal info
            command = args[:2]
            if command == ("release", "view"):
                return subprocess.CompletedProcess(args, 0 if info else 1, json.dumps(info), "")
            if command == ("release", "create"):
                self.assertIn("--draft", args)
                info = {"databaseId": 123, "isDraft": True, "assets": []}
            if command == ("release", "upload"):
                for filename in args[3:args.index("--repo")]:
                    name = Path(filename).name
                    info["assets"] = [a for a in info["assets"] if a["name"] != name]
                    info["assets"].append({"name": name, "state": "uploaded", "size": 10})
            if command == ("release", "edit"):
                bodies.append(Path(args[args.index("--notes-file") + 1]).read_text(encoding="utf-8"))
            if args[0] == "api":
                self.assertFalse(release.missing_assets(self.tag, info["assets"]))
                self.assertIn("make_latest=legacy", args)
                info["isDraft"] = False
                publications.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")

        body = release.render_notes(self.tag, self.repo, "# Release changes")
        with tempfile.TemporaryDirectory() as directory, patch.object(release, "gh", side_effect=gh):
            paths = {}
            for name in release.required_assets(self.tag):
                paths[name] = Path(directory) / name
                paths[name].write_bytes(b"fixture")
            windows = [p for n, p in paths.items() if n.startswith(("wispterm-windows-", "benchmark-"))]
            release.publish(self.tag, self.repo, windows, body)
            self.assertTrue(info["isDraft"])
            others = [p for p in paths.values() if p not in windows]
            for asset in others:
                release.publish(self.tag, self.repo, [asset], body)
            self.assertFalse(info["isDraft"])
            release.publish(self.tag, self.repo, windows, body)
        self.assertEqual(len(publications), 1)
        self.assertTrue(all(text == body for text in bodies))

    def test_windows_cannot_skip_reports_or_upload_missing_files(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, "gh") as gh:
            asset = Path(directory) / f"wispterm-windows-portable-{self.tag}.zip"
            with self.assertRaises(ValueError):
                release.publish(self.tag, self.repo, [asset], "body")
            asset.write_bytes(b"zip")
            with self.assertRaisesRegex(ValueError, "both benchmark"):
                release.publish(self.tag, self.repo, [asset], "body")
            gh.assert_not_called()

    def test_create_race_uses_the_other_platforms_draft(self):
        info = {"databaseId": 123, "isDraft": True, "assets": []}
        missing = subprocess.CompletedProcess([], 1, "", "already exists")
        ok = subprocess.CompletedProcess([], 0, "", "")
        found = subprocess.CompletedProcess([], 0, json.dumps(info), "")
        with patch.object(release, "gh", side_effect=[missing, missing, found, ok, found]) as gh:
            release.publish(self.tag, self.repo, [], "body")
        self.assertFalse(any(call.args[0] == "api" for call in gh.call_args_list))

    def test_workflows_use_the_shared_publisher_and_benchmark(self):
        root = Path(__file__).resolve().parent.parent
        for filename in ("windows-release.yml", "macos-release.yml", "macos-release-x86_64.yml", "linux-release.yml", "wisptermctl-release.yml"):
            workflow = (root / ".github" / "workflows" / filename).read_text(encoding="utf-8")
            self.assertIn("python packaging/publish_release.py --publish", workflow)
            self.assertNotIn("gh release create", workflow)
            self.assertNotIn("gh release edit", workflow)
        windows = (root / ".github/workflows/windows-release.yml").read_text(encoding="utf-8")
        self.assertIn("benchmark-release.ps1", windows)
        self.assertIn('"zig-out/release-benchmark/benchmark-windows-$tag.md"', windows)
        self.assertIn('"zig-out/release-benchmark/benchmark-windows-$tag.json"', windows)


if __name__ == "__main__":
    unittest.main()
