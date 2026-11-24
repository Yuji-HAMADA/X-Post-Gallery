import unittest
from unittest.mock import patch, MagicMock
import os
import sys

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "scripts"))
from verify_and_repair_gists import (
    get_gist_id_from_entry,
    verify_single_gist,
    is_tweet_from_invalid_users,
    remove_users_from_queue_gist,
)

class TestVerifyAndRepairGists(unittest.TestCase):
    def test_get_gist_id_from_entry(self):
        # 新形式 dict
        entry_dict = {"gist_id": "gid_123", "priority_updated_at": 1000}
        self.assertEqual(get_gist_id_from_entry(entry_dict), "gid_123")

        # 旧形式 str
        self.assertEqual(get_gist_id_from_entry("gid_456"), "gid_456")

        # 不正形式 None
        self.assertIsNone(get_gist_id_from_entry(None))

    def test_verify_single_gist_multi_user_case_insensitive(self):
        # 子Gistには 'MixedCase_User' で保存されており、マスターGistからは 'mixedcase_user' で照会
        child_gist_data = {
            "users": {
                "MixedCase_User": {
                    "tweets": [{"id_str": "123", "media_urls": ["http://example.com/1.jpg"]}]
                },
                "EmptyUser": {
                    "tweets": []
                }
            }
        }

        with patch("verify_and_repair_gists.download_gist_content", return_value=(200, child_gist_data, "OK")):
            res = verify_single_gist("gist_test", ["mixedcase_user", "EmptyUser", "NotFoundUser"], {})

        results = res["results"]
        # 大文字小文字違いでもツイートがあれば Valid (True)
        self.assertTrue(results["mixedcase_user"][0])
        self.assertIn("Valid", results["mixedcase_user"][1])

        # ツイートが0件の場合は Invalid (False)
        self.assertFalse(results["EmptyUser"][0])

        # 存在しない場合は Invalid (False)
        self.assertFalse(results["NotFoundUser"][0])

    def test_verify_single_gist_single_user_case_insensitive(self):
        child_gist_data = {
            "user_screen_name": "TargetUser",
            "tweets": [{"id_str": "123", "media_urls": ["http://example.com/1.jpg"]}]
        }

        with patch("verify_and_repair_gists.download_gist_content", return_value=(200, child_gist_data, "OK")):
            res = verify_single_gist("gist_test", ["targetuser", "otheruser"], {})

        results = res["results"]
        self.assertTrue(results["targetuser"][0])
        self.assertFalse(results["otheruser"][0])

    def test_is_tweet_from_invalid_users(self):
        invalid_lower = {"baduser", "deleteduser"}

        # username 一致 (大文字小文字問わず)
        t1 = {"username": "BadUser", "id_str": "1"}
        self.assertTrue(is_tweet_from_invalid_users(t1, invalid_lower))

        # full_text の @user: 形式
        t2 = {"full_text": "@deleteduser: Some content", "id_str": "2"}
        self.assertTrue(is_tweet_from_invalid_users(t2, invalid_lower))

        # post_url 一致
        t3 = {"post_url": "https://x.com/BadUser/status/123", "id_str": "3"}
        self.assertTrue(is_tweet_from_invalid_users(t3, invalid_lower))

        # 正常ユーザー
        t4 = {"username": "GoodUser", "full_text": "@GoodUser: Hello", "post_url": "https://x.com/GoodUser/status/456"}
        self.assertFalse(is_tweet_from_invalid_users(t4, invalid_lower))

    def test_remove_users_from_queue_gist(self):
        queue_data = {
            "users": [
                {"user": "ValidUser1", "count": 100},
                {"user": "InvalidUser", "count": 100},
                {"user": "ValidUser2", "count": 100},
            ],
            "sibling_gist_id": "slot1_id"
        }

        meta = {
            "files": {
                "fetch_queue.json": {
                    "raw_url": "https://gist.githubusercontent.com/raw/fetch_queue.json"
                }
            }
        }

        with patch("verify_and_repair_gists.fetch_gist_meta_with_retry", return_value=(200, meta)), \
             patch("verify_and_repair_gists.download_raw_json", return_value=queue_data), \
             patch("verify_and_repair_gists.requests.patch") as mock_patch:
            mock_patch.return_value.status_code = 200
            ok, count, sibling = remove_users_from_queue_gist("queue_id", {"invaliduser"}, {})

        self.assertTrue(ok)
        self.assertEqual(count, 1)
        self.assertEqual(sibling, "slot1_id")

        # PATCH の内容を確認: InvalidUser が除外されていること
        called_payload = mock_patch.call_args[1]["json"]
        import json
        updated_queue = json.loads(called_payload["files"]["fetch_queue.json"]["content"])
        users_in_queue = [u["user"] for u in updated_queue["users"]]
        self.assertEqual(users_in_queue, ["ValidUser1", "ValidUser2"])

if __name__ == "__main__":
    unittest.main()
