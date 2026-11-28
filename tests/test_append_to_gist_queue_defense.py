import os
import sys
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

import append_to_gist

class TestAppendToGistQueueDefense(unittest.TestCase):
    def setUp(self):
        self.original_env = os.environ.copy()

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.original_env)

    @patch("append_to_gist.fetch_queue_data")
    def test_fetch_all_queue_users_single_slot(self, mock_fetch_queue_data):
        os.environ["FETCH_QUEUE_GIST_ID"] = "slot0_gist"
        os.environ.pop("FETCH_QUEUE_SLOT1_GIST_ID", None)

        mock_fetch_queue_data.side_effect = lambda gist_id: {
            "users": [{"user": "User_A"}, {"user": "User_B"}]
        } if gist_id == "slot0_gist" else None

        users = append_to_gist.fetch_all_queue_users()
        self.assertIsNotNone(users)
        self.assertEqual(users, {"user_a", "user_b"})
        self.assertEqual(mock_fetch_queue_data.call_count, 1)

    @patch("append_to_gist.fetch_queue_data")
    def test_fetch_all_queue_users_with_sibling_gist_id(self, mock_fetch_queue_data):
        os.environ["FETCH_QUEUE_GIST_ID"] = "slot0_gist"
        os.environ.pop("FETCH_QUEUE_SLOT1_GIST_ID", None)

        def mock_fetch(gist_id):
            if gist_id == "slot0_gist":
                return {
                    "sibling_gist_id": "slot1_gist",
                    "users": [{"user": "Alice"}]
                }
            elif gist_id == "slot1_gist":
                return {
                    "users": [{"user": "TestTargetUser"}, {"user": "Bob"}]
                }
            return None

        mock_fetch_queue_data.side_effect = mock_fetch

        users = append_to_gist.fetch_all_queue_users()
        self.assertIsNotNone(users)
        self.assertIn("alice", users)
        self.assertIn("testtargetuser", users)
        self.assertIn("bob", users)

    @patch("append_to_gist.fetch_queue_data")
    def test_fetch_all_queue_users_with_slot1_env_var(self, mock_fetch_queue_data):
        os.environ["FETCH_QUEUE_GIST_ID"] = "slot0_gist"
        os.environ["FETCH_QUEUE_SLOT1_GIST_ID"] = "custom_slot1_gist"

        def mock_fetch(gist_id):
            if gist_id == "slot0_gist":
                return {"users": [{"user": "User0"}]}
            elif gist_id == "custom_slot1_gist":
                return {"users": [{"user": "User1"}]}
            return None

        mock_fetch_queue_data.side_effect = mock_fetch

        users = append_to_gist.fetch_all_queue_users()
        self.assertIsNotNone(users)
        self.assertEqual(users, {"user0", "user1"})

    @patch("append_to_gist.write_fetch_result")
    @patch("append_to_gist.fetch_all_queue_users")
    @patch("append_to_gist.fetch_gist_data")
    @patch("append_to_gist.parse_tweets_js")
    @patch("append_to_gist.run_extraction")
    @patch("append_to_gist.write_skip_ids_file")
    @patch("append_to_gist.parse_args")
    def test_slot1_user_preserved_not_aborted(
        self,
        mock_parse_args,
        mock_write_skip_ids_file,
        mock_run_extraction,
        mock_parse_tweets_js,
        mock_fetch_gist_data,
        mock_fetch_all_queue_users,
        mock_write_fetch_result,
    ):
        """Slot 1 に登録されているユーザーがクロール中も存在し続ける場合、正常に処理が進むこと"""
        args = MagicMock()
        args.gist_id = "master_gist"
        args.user = "testtargetuser"
        args.from_scratch = False
        args.stop_on_existing = True
        args.promote_gist_id = None
        mock_parse_args.return_value = args

        master_data = {
            "user_gists": {},
            "tweets": []
        }
        mock_fetch_gist_data.return_value = ("data.json", master_data)
        mock_write_skip_ids_file.return_value = "/tmp/dummy_skip_ids.txt"

        # クロール前もクロール後も Slot 1 に testtargetuser が存在している
        mock_fetch_all_queue_users.return_value = {"testtargetuser", "other_user"}
        mock_parse_tweets_js.return_value = [
            {"id_str": "123", "full_text": "hello", "media_urls": ["http://example.com/1.jpg"]}
        ]

        with patch("append_to_gist.process_multi_user_append") as mock_append, \
             patch("append_to_gist.has_user_gists_id_changed", return_value=False), \
             patch("os.unlink"), patch("builtins.open", unittest.mock.mock_open()):
            mock_append.return_value = {"user_gists": {"testtargetuser": "child_1"}, "tweets": []}
            append_to_gist.main()

        # 中断されずに success が書き込まれていること
        mock_write_fetch_result.assert_called_with("testtargetuser", 1, status="success")

    @patch("append_to_gist.write_fetch_result")
    @patch("append_to_gist.fetch_all_queue_users")
    @patch("append_to_gist.fetch_gist_data")
    @patch("append_to_gist.parse_tweets_js")
    @patch("append_to_gist.run_extraction")
    @patch("append_to_gist.write_skip_ids_file")
    @patch("append_to_gist.parse_args")
    def test_slot1_user_deleted_during_crawl_aborts(
        self,
        mock_parse_args,
        mock_write_skip_ids_file,
        mock_run_extraction,
        mock_parse_tweets_js,
        mock_fetch_gist_data,
        mock_fetch_all_queue_users,
        mock_write_fetch_result,
    ):
        """Slot 1 に登録されていたユーザーがクロール中にキューから削除された場合、中断されること"""
        args = MagicMock()
        args.gist_id = "master_gist"
        args.user = "testtargetuser"
        args.from_scratch = False
        args.stop_on_existing = True
        args.promote_gist_id = None
        mock_parse_args.return_value = args

        master_data = {
            "user_gists": {},
            "tweets": []
        }
        mock_fetch_gist_data.return_value = ("data.json", master_data)
        mock_write_skip_ids_file.return_value = "/tmp/dummy_skip_ids.txt"

        # 開始時はキューに存在していたが、クロール完了時に消えている
        call_count = 0
        def side_effect_queue_users():
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return {"testtargetuser"} # クロール前
            else:
                return set() # クロール後（削除された）

        mock_fetch_all_queue_users.side_effect = side_effect_queue_users
        mock_parse_tweets_js.return_value = [
            {"id_str": "123", "full_text": "hello", "media_urls": ["http://example.com/1.jpg"]}
        ]

        with patch("os.unlink"), self.assertRaises(SystemExit) as cm:
            append_to_gist.main()

        self.assertEqual(cm.exception.code, 0)
        # cancelled_user_deleted が書き込まれていること
        mock_write_fetch_result.assert_called_with("testtargetuser", 0, status="cancelled_user_deleted")

    @patch("append_to_gist.write_fetch_result")
    @patch("append_to_gist.fetch_all_queue_users")
    @patch("append_to_gist.fetch_gist_data")
    @patch("append_to_gist.parse_tweets_js")
    @patch("append_to_gist.run_extraction")
    @patch("append_to_gist.write_skip_ids_file")
    @patch("append_to_gist.parse_args")
    def test_manual_crawl_user_not_in_queue_not_aborted(
        self,
        mock_parse_args,
        mock_write_skip_ids_file,
        mock_run_extraction,
        mock_parse_tweets_js,
        mock_fetch_gist_data,
        mock_fetch_all_queue_users,
        mock_write_fetch_result,
    ):
        """キューに元々いないユーザーを手動クロールした場合、誤検知で中断されず正常完了すること"""
        args = MagicMock()
        args.gist_id = "master_gist"
        args.user = "manual_user"
        args.from_scratch = False
        args.stop_on_existing = True
        args.promote_gist_id = None
        mock_parse_args.return_value = args

        master_data = {
            "user_gists": {},
            "tweets": []
        }
        mock_fetch_gist_data.return_value = ("data.json", master_data)
        mock_write_skip_ids_file.return_value = "/tmp/dummy_skip_ids.txt"

        # 開始時も完了時もキューにはいない
        mock_fetch_all_queue_users.return_value = {"other_user"}
        mock_parse_tweets_js.return_value = [
            {"id_str": "999", "full_text": "manual post", "media_urls": ["http://example.com/m.jpg"]}
        ]

        with patch("append_to_gist.process_multi_user_append") as mock_append, \
             patch("append_to_gist.has_user_gists_id_changed", return_value=False), \
             patch("os.unlink"), patch("builtins.open", unittest.mock.mock_open()):
            mock_append.return_value = {"user_gists": {"manual_user": "child_1"}, "tweets": []}
            append_to_gist.main()

        # 中断されずに success が書き込まれていること
        mock_write_fetch_result.assert_called_with("manual_user", 1, status="success")

    @patch("append_to_gist.write_fetch_result")
    @patch("append_to_gist.fetch_all_queue_users")
    @patch("append_to_gist.fetch_gist_data")
    @patch("append_to_gist.parse_tweets_js")
    @patch("append_to_gist.run_extraction")
    @patch("append_to_gist.write_skip_ids_file")
    @patch("append_to_gist.parse_args")
    def test_skip_queue_check_skips_queue_fetch(
        self,
        mock_parse_args,
        mock_write_skip_ids_file,
        mock_run_extraction,
        mock_parse_tweets_js,
        mock_fetch_gist_data,
        mock_fetch_all_queue_users,
        mock_write_fetch_result,
    ):
        """--skip-queue-check 指定時は fetch_all_queue_users() を一切呼ばないこと"""
        args = MagicMock()
        args.gist_id = "master_gist"
        args.user = "timeline_user"
        args.from_scratch = False
        args.stop_on_existing = True
        args.promote_gist_id = None
        args.skip_extract = False
        args.skip_queue_check = True
        args.platform = "x"
        mock_parse_args.return_value = args

        master_data = {"user_gists": {}, "tweets": []}
        mock_fetch_gist_data.return_value = ("data.json", master_data)
        mock_write_skip_ids_file.return_value = "/tmp/dummy_skip_ids.txt"
        mock_parse_tweets_js.return_value = []

        with patch("os.unlink"), self.assertRaises(SystemExit) as cm:
            append_to_gist.main()

        self.assertEqual(cm.exception.code, 0)
        mock_fetch_all_queue_users.assert_not_called()
        mock_write_fetch_result.assert_called_with("timeline_user", 0, status="no_new_tweets")

    @patch("append_to_gist.subprocess.run")
    def test_fetch_gist_data_uses_inline_content_when_not_truncated(self, mock_run):
        """truncated=False の場合は gh api 応答の content を使い curl を省略すること"""
        import json as _json

        inline_payload = {"users": {"alice": {"tweets": []}}}
        mock_api = MagicMock(returncode=0)
        mock_api.stdout = _json.dumps({
            "files": {
                "data.json": {
                    "truncated": False,
                    "content": _json.dumps(inline_payload),
                    "raw_url": "https://gist.githubusercontent.com/raw/data.json",
                }
            }
        })
        mock_run.return_value = mock_api

        filename, data = append_to_gist.fetch_gist_data("gist_inline")
        self.assertEqual(filename, "data.json")
        self.assertEqual(data, inline_payload)
        self.assertEqual(mock_run.call_count, 1)

    @patch("append_to_gist.subprocess.run")
    def test_fetch_gist_data_falls_back_to_curl_when_truncated(self, mock_run):
        """truncated=True の場合は raw_url から curl 取得へフォールバックすること"""
        import json as _json

        full_payload = {"users": {"bob": {"tweets": [{"id_str": "1"}]}}}
        mock_api = MagicMock(returncode=0)
        mock_api.stdout = _json.dumps({
            "files": {
                "data.json": {
                    "truncated": True,
                    "content": "{truncated...",
                    "raw_url": "https://gist.githubusercontent.com/raw/data.json",
                }
            }
        })
        mock_curl = MagicMock(returncode=0)
        mock_curl.stdout = _json.dumps(full_payload)
        mock_run.side_effect = [mock_api, mock_curl]

        filename, data = append_to_gist.fetch_gist_data("gist_truncated")
        self.assertEqual(filename, "data.json")
        self.assertEqual(data, full_payload)
        self.assertEqual(mock_run.call_count, 2)

    def test_case_insensitive_lookup_and_prefetched_cache_reuse(self):
        """大文字・小文字違いでも user_gists / get_user_tweets が一致し、事前取得キャッシュが再利用されること"""
        master_data = {
            "user_gists": {"SampleUser": {"gist_id": "child_1", "priority_updated_at": 100}},
            "tweets": [],
        }
        canonical, entry = append_to_gist.find_user_gist_entry(master_data["user_gists"], "sampleuser")
        self.assertEqual(canonical, "SampleUser")
        self.assertEqual(append_to_gist.get_gist_id_from_entry(entry), "child_1")

        child_data = {
            "users": {
                "SampleUser": {
                    "tweets": [{"id_str": "10", "media_urls": ["https://example.com/10.jpg"]}]
                }
            }
        }
        self.assertEqual(len(append_to_gist.get_user_tweets(child_data, "sampleuser")), 1)

        prefetched = {"child_1": {"filename": "data.json", "data": child_data, "is_modified": False}}
        incoming = [
            {"username": "sampleuser", "id_str": "20", "media_urls": ["https://example.com/20.jpg"]}
        ]
        with patch("append_to_gist.fetch_gist_data") as mock_fetch, \
             patch("append_to_gist.subprocess.run"):
            append_to_gist.process_multi_user_append(
                master_data,
                incoming,
                initial_gist_cache=prefetched,
            )
            mock_fetch.assert_not_called()

if __name__ == "__main__":
    unittest.main()
