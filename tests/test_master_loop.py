import asyncio
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, MagicMock

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))
try:
    import playwright  # noqa: F401
except ImportError:
    mock_pw = MagicMock()
    sys.modules["playwright"] = mock_pw
    sys.modules["playwright.async_api"] = mock_pw.async_api

import expand_timeline_candidates as etc


class TestMasterLoopScript(unittest.TestCase):
    def _setup_stub_project(self, tmpdir):
        scripts_dir = os.path.join(tmpdir, "scripts")
        os.makedirs(scripts_dir, exist_ok=True)
        repo_scripts = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))
        shutil.copy2(os.path.join(repo_scripts, "run_master_loop_local.sh"), os.path.join(scripts_dir, "run_master_loop_local.sh"))
        shutil.copy2(os.path.join(repo_scripts, "platform_env.sh"), os.path.join(scripts_dir, "platform_env.sh"))

        log_path = os.path.join(tmpdir, "calls.log")
        for name in ("run_expand_timeline_local.sh", "run_scheduled_fetch_local.sh", "run_sort_master_local.sh"):
            stub_path = os.path.join(scripts_dir, name)
            with open(stub_path, "w", encoding="utf-8") as f:
                f.write(f'#!/bin/bash\necho "{name}:$*" >> "{log_path}"\n')
            os.chmod(stub_path, os.stat(stub_path).st_mode | stat.S_IXUSR)
        return os.path.join(scripts_dir, "run_master_loop_local.sh"), log_path

    def test_max_cycles_stops_after_requested_iterations(self):
        """--max-cycles 指定回数でマスター統合ループが終了し、子スクリプトへ --max-cycles を漏らさないこと"""
        with tempfile.TemporaryDirectory() as tmpdir:
            script_path, log_path = self._setup_stub_project(tmpdir)
            res = subprocess.run(
                ["bash", script_path, "--platform", "tiktok", "--max-cycles", "1", "-n", "30", "--num-existing", "100"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(res.returncode, 0, msg=res.stderr)
            with open(log_path, "r", encoding="utf-8") as f:
                lines = [line.strip() for line in f if line.strip()]
            self.assertEqual(
                lines,
                [
                    "run_expand_timeline_local.sh:--max-cycles 1 -n 30 --num-existing 100",
                    "run_scheduled_fetch_local.sh:-n 30 --num-existing 100",
                    "run_sort_master_local.sh:",
                ],
            )
            self.assertIn("Stopping master loop", res.stdout)

    def test_max_cycles_equals_syntax_runs_exact_count(self):
        """--max-cycles=2 形式でも2巡で終了すること"""
        with tempfile.TemporaryDirectory() as tmpdir:
            script_path, log_path = self._setup_stub_project(tmpdir)
            res = subprocess.run(
                ["bash", script_path, "--max-cycles=2"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(res.returncode, 0, msg=res.stderr)
            with open(log_path, "r", encoding="utf-8") as f:
                lines = [line.strip() for line in f if line.strip()]
            self.assertEqual(len(lines), 6)

    def test_invalid_max_cycles_exits_nonzero(self):
        """数値以外の --max-cycles 指定時はエラー終了すること"""
        with tempfile.TemporaryDirectory() as tmpdir:
            script_path, _ = self._setup_stub_project(tmpdir)
            res = subprocess.run(
                ["bash", script_path, "--max-cycles", "abc"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(res.returncode, 0)

    def test_auth_error_exit_41_stops_master_loop_immediately(self):
        """Step 1 が認証切れ (exit 41) を返したら Step 2/3 や次巡回に進まず即終了すること"""
        with tempfile.TemporaryDirectory() as tmpdir:
            script_path, log_path = self._setup_stub_project(tmpdir)
            expand_stub = os.path.join(tmpdir, "scripts", "run_expand_timeline_local.sh")
            with open(expand_stub, "w", encoding="utf-8") as f:
                f.write(f'#!/bin/bash\necho "run_expand_timeline_local.sh:41" >> "{log_path}"\nexit 41\n')
            os.chmod(expand_stub, os.stat(expand_stub).st_mode | stat.S_IXUSR)

            res = subprocess.run(
                ["bash", script_path, "--platform", "instagram", "--max-cycles", "3"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(res.returncode, 41)
            self.assertIn("Auth session expired", res.stderr)
            with open(log_path, "r", encoding="utf-8") as f:
                lines = [line.strip() for line in f if line.strip()]
            self.assertEqual(lines, ["run_expand_timeline_local.sh:41"])

    def test_detect_timeline_auth_error_catches_instagram_root_login_form(self):
        """Instagram ルートURL上のログイン画面を認証切れとして検知し、正常フィードは誤検知しないこと"""
        login_page = MagicMock()
        login_page.url = "https://www.instagram.com/"
        login_page.evaluate = AsyncMock(return_value={
            "hasPassword": True,
            "hasLoginInput": True,
            "articles": 0,
            "hasInbox": False,
            "text": "log into instagram forgot password?",
        })
        reason = asyncio.run(etc.detect_timeline_auth_error(login_page, "instagram"))
        self.assertIsNotNone(reason)
        self.assertIn("session expired", reason.lower())

        ok_page = MagicMock()
        ok_page.url = "https://www.instagram.com/"
        ok_page.evaluate = AsyncMock(return_value={
            "hasPassword": False,
            "hasLoginInput": False,
            "articles": 5,
            "hasInbox": True,
            "text": "home feed posts",
        })
        self.assertIsNone(asyncio.run(etc.detect_timeline_auth_error(ok_page, "instagram")))

        x_login_page = MagicMock()
        x_login_page.url = "https://x.com/i/flow/login"
        self.assertIsNotNone(asyncio.run(etc.detect_timeline_auth_error(x_login_page, "x")))


if __name__ == "__main__":
    unittest.main()
