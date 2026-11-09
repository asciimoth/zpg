"""Check release order without changing a remote repository."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("scripts", "tools"):
            (self.root / name).mkdir()
        shutil.copy(ROOT / "scripts/release.sh", self.root / "scripts/release.sh")
        (self.root / "tools/package_artifacts.py").write_text("pass\n")
        self.log = self.root / "calls.jsonl"
        mock = self.root / "tools/mock"
        mock.write_text('''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name == "git":
    if args[:3] == ["rev-parse", "-q", "--verify"]: sys.exit(1)
    if args[:2] == ["rev-parse", "--is-shallow-repository"]: print("false")
    elif args[:2] == ["remote", "get-url"]: print("git@github.com:example/zpg.git")
    elif args[0] == "rev-parse": print("abc123")
elif name == "gh":
    if args[0] == "api": print("true")
    elif args[:2] == ["release", "view"]: sys.exit(1)
elif name == "goreleaser" and args[0] == "release":
    if os.environ.get("FAIL_BUILD") == "1": sys.exit(1)
    dist = pathlib.Path("dist"); dist.mkdir()
    files = ("zpg_1.2.3_linux_amd64.deb", "zpg_1.2.3_linux_amd64.rpm")
    lines = []
    for filename in files:
        (dist / filename).write_bytes(b"package")
        (dist / (filename + ".sig")).write_bytes(b"signature")
        lines.append(hashlib.sha256(b"package").hexdigest() + "  " + filename)
    (dist / "checksums.txt").write_text("\\n".join(lines) + "\\n")
    (dist / "checksums.txt.sig").write_bytes(b"signature")
''')
        mock.chmod(0o755)
        for name in ("git", "just", "goreleaser", "gh", "ghrepo"):
            (self.root / "tools" / name).symlink_to(mock)
        self.env = dict(os.environ, PATH=f"{self.root}/tools:{os.environ['PATH']}",
                        CALL_LOG=str(self.log), GITHUB_TOKEN="test-token")
        self.env.pop("GHREPO_REPO_DIR", None)

    def run_release(self, *args):
        return subprocess.run(["bash", "scripts/release.sh", *args], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_invalid_version_stops_before_tools(self):
        self.assertNotEqual(self.run_release("1.2.3-rc1").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_failed_build_does_not_push_or_publish(self):
        self.env["FAIL_BUILD"] = "1"
        self.assertNotEqual(self.run_release("1.2.3").returncode, 0)
        calls = self.calls()
        self.assertTrue(any(c[:2] == ["git", "-c"] and "tag" in c for c in calls))
        self.assertFalse(any(c[:2] == ["git", "push"] for c in calls))
        self.assertFalse(any(c[:3] == ["gh", "release", "create"] for c in calls))

    def test_publish_then_add_package_urls_to_ghrepo(self):
        repo = self.root / "repository"
        repo.mkdir()
        (repo / "ghrepo.yaml").touch()
        self.env["GHREPO_REPO_DIR"] = str(repo)
        result = self.run_release("v1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        push = next(i for i, c in enumerate(calls) if c[:2] == ["git", "push"])
        publish = next(i for i, c in enumerate(calls) if c[:3] == ["gh", "release", "create"])
        add = next(i for i, c in enumerate(calls) if c[:2] == ["ghrepo", "add"])
        self.assertLess(push, publish)
        self.assertLess(publish, add)
        self.assertEqual(calls[add][2:], [
            "https://github.com/example/zpg/releases/download/v1.2.3/zpg_1.2.3_linux_amd64.deb",
            "https://github.com/example/zpg/releases/download/v1.2.3/zpg_1.2.3_linux_amd64.rpm",
        ])


if __name__ == "__main__":
    unittest.main()
