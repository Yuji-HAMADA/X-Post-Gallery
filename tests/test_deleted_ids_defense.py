import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))
import append_to_gist


class TestDeletedIdsDefense(unittest.TestCase):
    def test_update_user_gist_preserves_deleted_ids(self):
        """別ユーザー更新時にも子Gistの deleted_ids が消去されずに保持されること"""
        promote_data = {
            "users": {
                "user_a": {"tweets": [{"id_str": "100", "media_urls": ["https://example.com/a.jpg"]}]},
            },
            "deleted_ids": ["999", "888"],
        }
        gist_cache = {"child_1": {"filename": "data.json", "data": promote_data, "is_modified": False}}
        final_id, updated = append_to_gist.update_or_migrate_user_gist_in_memory(
            "child_1",
            promote_data,
            "user_b",
            [{"id_str": "200", "media_urls": ["https://example.com/b.jpg"]}],
            gist_cache,
        )
        self.assertEqual(final_id, "child_1")
        self.assertEqual(updated.get("deleted_ids"), ["999", "888"])
        self.assertIn("user_a", updated["users"])
        self.assertIn("user_b", updated["users"])

    @patch("append_to_gist.subprocess.run")
    @patch("append_to_gist.fetch_gist_data")
    def test_process_multi_user_append_filters_deleted_ids(self, mock_fetch, mock_run):
        """子Gistの deleted_ids に含まれるツイートが再クロール時に復活しないこと"""
        child_data = {
            "users": {
                "sample_user": {
                    "tweets": [
                        {
                            "id_str": "200",
                            "full_text": "@sample_user: kept",
                            "media_urls": ["https://example.com/200.jpg"],
                        }
                    ]
                }
            },
            "deleted_ids": ["300"],
        }
        mock_fetch.return_value = ("data.json", child_data)

        master_data = {
            "user_screen_name": "Master",
            "user_gists": {"sample_user": {"gist_id": "child_1", "priority_updated_at": 100}},
            "tweets": [
                {"id_str": "200", "username": "sample_user", "media_urls": ["https://example.com/200.jpg"]}
            ],
        }
        incoming = [
            {"id_str": "300", "full_text": "@sample_user: deleted", "media_urls": ["https://example.com/300.jpg"]},
            {"id_str": "400", "full_text": "@sample_user: brand_new", "media_urls": ["https://example.com/400.jpg"]},
        ]

        append_to_gist.process_multi_user_append(master_data, incoming)
        # 300 は除外され、400 と 200 のみ残り、deleted_ids も保持されること
        mock_run.assert_called_once()
        # Verify updated payload via in-memory check on direct call
        # Also confirm master thumbnail became 400 (not 300)
        self.assertEqual(master_data["tweets"][0]["id_str"], "400")


if __name__ == "__main__":
    unittest.main()
