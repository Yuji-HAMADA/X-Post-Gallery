import unittest
from unittest.mock import patch, MagicMock
import sys
import os

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "scripts"))
from append_to_gist import process_multi_user_append
from expand_timeline_candidates import process_account

class TestCandidateLogic(unittest.TestCase):
    def test_new_user_with_is_candidate(self):
        master_data = {
            "user_gists": {},
            "tweets": []
        }
        new_tweets = [
            {
                "username": "new_candidate_user",
                "id_str": "11111",
                "media_urls": ["http://example.com/pic.jpg"]
            }
        ]

        with patch("append_to_gist.create_gist_for_user", return_value="gist_new"), \
             patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_new", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=True
            )

        user_entry = res["user_gists"].get("new_candidate_user")
        self.assertIsNotNone(user_entry)
        self.assertTrue(user_entry.get("is_candidate"))

    def test_existing_user_preserves_regular_status(self):
        # 既存ユーザー（通常ユーザー、is_candidate なし）
        master_data = {
            "user_gists": {
                "regular_user": {
                    "gist_id": "gist_existing",
                    "priority_updated_at": 1000
                }
            },
            "tweets": []
        }
        new_tweets = [
            {
                "username": "regular_user",
                "id_str": "22222",
                "media_urls": ["http://example.com/pic2.jpg"]
            }
        ]

        with patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {"regular_user": {"tweets": []}}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_existing", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=True  # タイムライン取得側が is_candidate を要求しても既存なら維持
            )

        user_entry = res["user_gists"].get("regular_user")
        self.assertIsNotNone(user_entry)
        self.assertFalse(user_entry.get("is_candidate", False))

    def test_existing_candidate_preserves_candidate_status(self):
        # 既存ユーザー（Candidate）
        master_data = {
            "user_gists": {
                "candidate_user": {
                    "gist_id": "gist_cand",
                    "priority_updated_at": 2000,
                    "is_candidate": True
                }
            },
            "tweets": []
        }
        new_tweets = [
            {
                "username": "candidate_user",
                "id_str": "33333",
                "media_urls": ["http://example.com/pic3.jpg"]
            }
        ]

        with patch("append_to_gist.fetch_gist_data", return_value=("data.json", {"users": {"candidate_user": {"tweets": []}}})), \
             patch("append_to_gist.update_or_migrate_user_gist_in_memory", return_value=("gist_cand", {"users": {}})), \
             patch("subprocess.run"):
            res = process_multi_user_append(
                master_data,
                new_tweets,
                is_candidate=False  # 通常アペンドでも candidate 状態を維持
            )

        user_entry = res["user_gists"].get("candidate_user")
        self.assertIsNotNone(user_entry)
        self.assertTrue(user_entry.get("is_candidate"))

    @patch("subprocess.run")
    def test_process_account_command_args(self, mock_run):
        mock_run.return_value = MagicMock(returncode=0)

        # 既存ユーザーの場合: -s が付くこと
        process_account("dummy_gist", "existing_user", 300, is_existing=True)
        call_args_existing = mock_run.call_args[0][0]
        self.assertIn("-s", call_args_existing)
        self.assertNotIn("--is-candidate", call_args_existing)

        # 新規ユーザーの場合: --is-candidate が付き、-s は付かないこと
        process_account("dummy_gist", "new_user", 300, is_existing=False)
        call_args_new = mock_run.call_args[0][0]
        self.assertIn("--is-candidate", call_args_new)
        self.assertNotIn("-s", call_args_new)

    def test_rate_limit_url_filtering(self):
        # サードパーティドメインの429は除外、X APIドメインの429は検知
        valid_domains = ["api.twitter.com", "api.x.com", "x.com/i/api/", "twitter.com/i/api/"]

        def is_x_api_rate_limit(url):
            url_lower = url.lower()
            return any(d in url_lower for d in valid_domains)

        self.assertTrue(is_x_api_rate_limit("https://x.com/i/api/graphql/xxx/UserTweets"))
        self.assertTrue(is_x_api_rate_limit("https://api.x.com/2/users/by/username/test"))
        self.assertFalse(is_x_api_rate_limit("https://analytics.google.com/g/collect?v=2"))
        self.assertFalse(is_x_api_rate_limit("https://adservice.google.com/adsid/integrator.sync"))
        self.assertFalse(is_x_api_rate_limit("https://pbs.twimg.com/media/abc.jpg"))

if __name__ == "__main__":
    unittest.main()
