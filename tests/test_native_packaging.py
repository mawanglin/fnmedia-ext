"""native-only fork 打包约束：版本规则、内置运行时锁、安装脚本不碰系统。"""
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "proxy"))

import release_version  # noqa: E402
import updater  # noqa: E402


class ReleaseVersionTest(unittest.TestCase):
    def test_current_files_are_valid(self):
        info = release_version.release_info(
            release_version.read_first_line(ROOT / "VERSION"),
            release_version.read_first_line(ROOT / "RELEASE_CHANNEL"))
        self.assertEqual(info["tag"], "v" + info["display_version"])
        self.assertRegex(info["display_version"], r"^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?-n[1-9]\d*$")

    def test_rejects_bad_versions(self):
        for bad in ("1.0.0", "1.0.0-0", "1.0.0a", "1.0-1"):
            with self.assertRaises(ValueError):
                release_version.release_info(bad, "fork")
        with self.assertRaises(ValueError):
            release_version.release_info("1.0.0-1", "stable")

    def test_display_version(self):
        self.assertEqual(release_version.release_info("1.0.0-3", "fork")["tag"], "v1.0.0-n3")
        self.assertEqual(release_version.release_info("1.0.1-beta.1-1", "fork")["tag"], "v1.0.1-beta.1-n1")
        self.assertTrue(updater.is_newer("v1.0.1-beta.1-n2", "1.0.1-beta.1-1"))
        self.assertTrue(updater.is_newer("v1.0.1-beta.1-n1", "1.0.0-1"))

    def test_changelog_has_current_section(self):
        display = release_version.release_info(
            release_version.read_first_line(ROOT / "VERSION"), "fork")["display_version"]
        self.assertIn(f"## [{display}]", (ROOT / "CHANGELOG.md").read_text(encoding="utf-8"))


class UpdaterForkTest(unittest.TestCase):
    def test_points_at_fork_repo(self):
        self.assertEqual(updater.REPO_SLUG, "mawanglin/fnmedia-ext")

    def test_version_compare_with_fork_revision(self):
        self.assertTrue(updater.is_newer("v1.0.0-n2", "1.0.0-1"))
        self.assertFalse(updater.is_newer("v1.0.0-n1", "1.0.0-1"))
        self.assertTrue(updater.is_newer("v1.0.1-n1", "1.0.0-9"))
        self.assertFalse(updater.is_newer("v0.9.9-n9", "1.0.0-1"))

    def test_picks_asset_by_arch(self):
        assets = [{"name": "fnmedia-ext-1.0.0-1-arm.fpk"}, {"name": "fnmedia-ext-1.0.0-1-x86.fpk"},
                  {"name": "fnmedia-ext-1.0.0-1-x86.fpk.sha256"}]
        self.assertEqual(updater._pick_asset(assets, arch="arm")["name"], "fnmedia-ext-1.0.0-1-arm.fpk")
        self.assertEqual(updater._pick_asset(assets, arch="x86")["name"], "fnmedia-ext-1.0.0-1-x86.fpk")
        self.assertIsNone(updater._pick_asset([{"name": "fnmedia-ext-1.0.0-1.fpk"}], arch="x86"))


class RuntimeLockTest(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads((ROOT / "packaging/fpk/runtime/runtime.json").read_text(encoding="utf-8"))

    def test_sha256_pinned_for_both_arches(self):
        for section in (self.lock["python"]["sha256"], self.lock["ffmpeg"]["sha256"]):
            for arch in ("x86", "arm"):
                self.assertRegex(section[arch], r"^[0-9a-f]{64}$")

    def test_lock_pins_every_package_and_covers_requirements(self):
        lines = [l.strip() for l in (ROOT / "packaging/fpk/runtime/requirements.lock").read_text(
            encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")]
        self.assertTrue(lines)
        for line in lines:
            self.assertRegex(line, r"^[A-Za-z0-9_.\-]+==[0-9][^\s]*$")
        names = {re.split(r"==", l)[0].lower().replace("_", "-") for l in lines}
        for req in (ROOT / "requirements.txt").read_text(encoding="utf-8").splitlines():
            req = req.split("#")[0].strip()
            if req:
                self.assertIn(req.lower().replace("_", "-"), names)


class NoSystemChangeTest(unittest.TestCase):
    def read(self, rel):
        return (ROOT / rel).read_text(encoding="utf-8")

    def test_fpk_lifecycle_does_not_touch_system_packages(self):
        for rel in ("install_init", "install_callback", "upgrade_init", "upgrade_callback", "_common"):
            text = self.read(f"packaging/fpk/cmd/{rel}")
            code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
            self.assertNotRegex(code, r"\bapt(-get)?\b", rel)
            self.assertNotRegex(code, r"\bpip3?\s+install\b", rel)
            self.assertNotIn("command -v python3", code, rel)

    def test_bundled_mode_never_falls_back_to_system(self):
        text = self.read("deploy/bootstrap_deps.sh")
        before, _, _ = text.partition("# 核心服务启动【强依赖】")
        self.assertIn("fnmedia_bundled", before)
        self.assertIn("exit 2", before)
        self.assertIn("exit 0", before)

    def test_install_builds_bundled_venv(self):
        self.assertIn("bundled_make_venv", self.read("deploy/install.sh"))

    def test_service_prefers_bundled_ffprobe(self):
        self.assertIn("@ROOT@/runtime/ffmpeg", self.read("deploy/fnmedia-ext.service.in"))

    def test_manifest_template(self):
        text = self.read("packaging/fpk/manifest.in")
        self.assertIn("@VERSION@", text)
        self.assertIn("@PLATFORM@", text)
        self.assertRegex(text, r"maintainer\s+=\s+Cob\b")


class BundledVenvTest(unittest.TestCase):
    """用 stage 出来的假运行时验证 bundled_make_venv 的行为（不联网、不装任何东西）。"""

    def test_make_venv_mounts_site_and_scripts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rt = root / "runtime"
            (rt / "site" / "demo_pkg").mkdir(parents=True)
            (rt / "site" / "demo_pkg" / "__init__.py").write_text("VALUE = 42\n")
            (rt / "scripts").mkdir()
            (rt / "scripts" / "demo-cmd").write_text("#!/bin/sh\necho hi\n")
            (rt / "python" / "bin").mkdir(parents=True)
            (rt / "python" / "bin" / "python3").symlink_to(sys.executable)
            (rt / "BUNDLED").write_text("{}")
            script = (f'ROOT="{root}"; . "{ROOT}/deploy/runtime_common.sh"; '
                      f'fnmedia_bundled && bundled_make_venv "{root}/.venv"')
            r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
            if r.returncode != 0 and "venv" in r.stderr.lower() and "ensurepip" in r.stderr.lower():
                self.skipTest("当前 Python 无法 --without-pip 建 venv")
            self.assertEqual(r.returncode, 0, r.stderr)
            out = subprocess.run([str(root / ".venv/bin/python"), "-c", "import demo_pkg;print(demo_pkg.VALUE)"],
                                 capture_output=True, text=True)
            self.assertEqual(out.stdout.strip(), "42", out.stderr)
            self.assertTrue((root / ".venv/bin/demo-cmd").exists())
            # 幂等：再来一次不报错
            again = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
            self.assertEqual(again.returncode, 0, again.stderr)


if __name__ == "__main__":
    unittest.main()
