import unittest
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

from append_to_gist import process_multi_user_append, has_user_gists_id_changed

class TestAppendToGistFromScratch(unittest.TestCase):
    def test_has_user_gists_id_changed(self):
        initial_map = {
            "user1": "gist_aaa",
            "user2": "gist_bbb",
        }

        # 1. 変更なし（同一ID、dict形式）
        no_change = {
            "user1": {"gist_id": "gist_aaa", "priority_updated_at": 100},
            "user2": {"gist_id": "gist_bbb", "priority_updated_at": 200},
        }
        self.assertFalse(has_user_gists_id_changed(initial_map, no_change))

        # 2. 変更なし（同一ID、legacy string形式）
        no_change_legacy = {
            "user1": "gist_aaa",
            "user2": "gist_bbb",
        }
        self.assertFalse(has_user_gists_id_changed(initial_map, no_change_legacy))

        # 3. 新規ユーザー追加
        new_user = {
            "user1": {"gist_id": "gist_aaa", "priority_updated_at": 100},
            "user2": {"gist_id": "gist_bbb", "priority_updated_at": 200},
            "user3": {"gist_id": "gist_ccc", "priority_updated_at": 300},
        }
        self.assertTrue(has_user_gists_id_changed(initial_map, new_user))

        # 4. 既存ユーザーの所属 Gist ID 変更（容量超過等によるマイグレーション）
        migrated_user = {
            "user1": {"gist_id": "gist_aaa_NEW", "priority_updated_at": 100},
            "user2": {"gist_id": "gist_bbb", "priority_updated_at": 200},
        }
        self.assertTrue(has_user_gists_id_changed(initial_map, migrated_user))

    def test_process_multi_user_append_from_scratch(self):
        """from_scratch=True の場合、既存ツイートが削除され新ツイートで置き換わること"""
        master_data = {
            "user_gists": {
                "test_user": {
                    "gist_id": "child_gist_1",
                    "priority_updated_at": 0
                }
            },
            "tweets": [
                {
                    "id_str": "old_tweet_1",
                    "username": "test_user",
                    "media_urls": ["https://pbs.twimg.com/media/old1.jpg"]
                },
                {
                    "id_str": "other_tweet",
                    "username": "other_user",
                    "media_urls": ["https://pbs.twimg.com/media/other.jpg"]
                }
            ]
        }

        new_tweets = [
            {
                "id_str": "new_tweet_1",
                "full_text": "@test_user: new post 1",
                "created_at": "2026-11-10T10:00:00.000Z",
                "media_urls": ["https://pbs.twimg.com/media/new1.jpg"],
                "post_url": "https://x.com/test_user/status/new_tweet_1"
            },
            {
                "id_str": "new_tweet_2",
                "full_text": "@test_user: new post 2",
                "created_at": "2026-11-10T09:00:00.000Z",
                "media_urls": ["https://pbs.twimg.com/media/new2.jpg"],
                "post_url": "https://x.com/test_user/status/new_tweet_2"
            }
        ]

        # fetch_gist_data をモック化するためにグローバル関数を一時差し替え
        import append_to_gist
        original_fetch = append_to_gist.fetch_gist_data
        original_run = append_to_gist.subprocess.run
        append_to_gist.subprocess.run = lambda *args, **kwargs: None
        append_to_gist.fetch_gist_data = lambda g_id: (
            "data.json",
            {
                "users": {
                    "test_user": {
                        "tweets": [
                            {"id_str": "old_tweet_1", "media_urls": ["old1.jpg"]},
                            {"id_str": "old_tweet_2", "media_urls": ["old2.jpg"]},
                        ]
                    }
                }
            }
        )

        try:
            result = process_multi_user_append(
                master_data,
                new_tweets,
                from_scratch=True
            )

            # 1. マスターGist の tweets から test_user の過去ツイート（old_tweet_1）が削除され、
            #    new_tweets[0]（new_tweet_1）のみが先頭に存在すること
            test_user_master_tweets = [
                t for t in result["tweets"]
                if t.get("username") == "test_user"
            ]
            self.assertEqual(len(test_user_master_tweets), 1)
            self.assertEqual(test_user_master_tweets[0]["id_str"], "new_tweet_1")

            # 他ユーザーのツイートは保持されていること
            other_user_tweets = [
                t for t in result["tweets"]
                if t.get("username") == "other_user"
            ]
            self.assertEqual(len(other_user_tweets), 1)
            self.assertEqual(other_user_tweets[0]["id_str"], "other_tweet")

        finally:
            append_to_gist.fetch_gist_data = original_fetch
            append_to_gist.subprocess.run = original_run

if __name__ == "__main__":
    unittest.main()
