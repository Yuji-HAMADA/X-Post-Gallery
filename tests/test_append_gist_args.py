import subprocess
import unittest

class TestAppendGistArgs(unittest.TestCase):
    def test_from_scratch_parsing(self):
        # 存在しないGist IDでも引数パースログが標準出力に出力される
        proc = subprocess.run(
            ["./append_gist.sh", "-g", "dummy_id", "-u", "dummy_user", "-n", "300", "--from-scratch"],
            capture_output=True,
            text=True
        )
        self.assertIn("Append to Gist", proc.stdout)
        self.assertIn("Target           : @dummy_user", proc.stdout)
        self.assertIn("Num              : 300", proc.stdout)
        self.assertIn("From scratch     : --from-scratch", proc.stdout)
        self.assertNotIn("illegal option", proc.stderr)
        self.assertNotIn("Usage: ./append_gist.sh", proc.stderr)

    def test_stop_on_existing_parsing(self):
        proc = subprocess.run(
            ["./append_gist.sh", "-g", "dummy_id", "-u", "dummy_user", "-n", "200", "-s"],
            capture_output=True,
            text=True
        )
        self.assertIn("Stop on existing : -s", proc.stdout)
        self.assertIn("From scratch     : (no)", proc.stdout)
        self.assertNotIn("illegal option", proc.stderr)

    def test_promote_gist_parsing(self):
        proc = subprocess.run(
            ["./append_gist.sh", "-g", "dummy_id", "-u", "dummy_user", "-p", "target_gist_123"],
            capture_output=True,
            text=True
        )
        self.assertIn("Promote Gist     : target_gist_123", proc.stdout)
        self.assertNotIn("illegal option", proc.stderr)

if __name__ == "__main__":
    unittest.main()
