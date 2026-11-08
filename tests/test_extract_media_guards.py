import unittest
from unittest.mock import patch
import sys
import os

# scripts ディレクトリを path に追加
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

from unittest.mock import MagicMock
try:
    import playwright
except ImportError:
    mock_playwright = MagicMock()
    sys.modules["playwright"] = mock_playwright
    sys.modules["playwright.async_api"] = mock_playwright.async_api

import extract_media
import append_to_gist

class TestExtractMediaGuards(unittest.TestCase):
    def test_extract_media_default_guards(self):
        """extract_media.py のデフォルトセーフティガード値が正しく設定されていること"""
        test_args = ["extract_media.py", "-u", "test_user"]
        with patch.object(sys, "argv", test_args):
            args = extract_media.parse_args()
            self.assertEqual(args.max_scrolls, 150)
            self.assertEqual(args.max_no_new_scrolls, 40)
            self.assertEqual(args.max_runtime, 600)

    def test_extract_media_custom_guards(self):
        """extract_media.py のカスタムセーフティガード値が正しくパースされること"""
        test_args = [
            "extract_media.py",
            "-u", "test_user",
            "--max-scrolls", "50",
            "--max-no-new-scrolls", "20",
            "--max-runtime", "300",
        ]
        with patch.object(sys, "argv", test_args):
            args = extract_media.parse_args()
            self.assertEqual(args.max_scrolls, 50)
            self.assertEqual(args.max_no_new_scrolls, 20)
            self.assertEqual(args.max_runtime, 300)

    def test_append_to_gist_guard_options(self):
        """append_to_gist.py がガード引数を正しく受け取ること"""
        test_args = [
            "append_to_gist.py",
            "-g", "dummy_gist_id",
            "-u", "test_user",
            "--max-scrolls", "80",
            "--max-no-new-scrolls", "25",
            "--max-runtime", "400",
        ]
        with patch.object(sys, "argv", test_args):
            args = append_to_gist.parse_args()
            self.assertEqual(args.max_scrolls, 80)
            self.assertEqual(args.max_no_new_scrolls, 25)
            self.assertEqual(args.max_runtime, 400)

    @patch("subprocess.run")
    def test_run_extraction_passes_guards(self, mock_run):
        """run_extraction が extract_media.py にセーフティガード引数を伝搬すること"""
        mock_run.return_value.returncode = 0

        test_args = [
            "append_to_gist.py",
            "-g", "dummy_gist_id",
            "-u", "test_user",
            "--max-scrolls", "99",
            "--max-no-new-scrolls", "33",
            "--max-runtime", "555",
        ]
        with patch.object(sys, "argv", test_args):
            args = append_to_gist.parse_args()
            append_to_gist.run_extraction(args, "/tmp/dummy_skip_ids.txt")

            called_cmd = mock_run.call_args[0][0]
            self.assertIn("--max-scrolls", called_cmd)
            self.assertIn("99", called_cmd)
            self.assertIn("--max-no-new-scrolls", called_cmd)
            self.assertIn("33", called_cmd)
            self.assertIn("--max-runtime", called_cmd)
            self.assertIn("555", called_cmd)

if __name__ == "__main__":
    unittest.main()
