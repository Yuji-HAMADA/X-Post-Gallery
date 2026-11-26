import os
import shutil
import stat
import subprocess
import tempfile
import unittest


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


if __name__ == "__main__":
    unittest.main()
