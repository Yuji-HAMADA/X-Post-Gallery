import unittest
from unittest.mock import patch, MagicMock
import sys
import os
import json

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

import sync_favorites

class TestSyncFavorites(unittest.TestCase):
    @patch("sync_favorites.update_gist_json")
    @patch("sync_favorites.get_gist_json")
    def test_sync_removes_unfavorited_and_adds_new(self, mock_get_gist, mock_update_gist):
        """お気に入り解除されたユーザーが除外され、新規お気に入りが追加されること"""
        mock_get_gist.side_effect = lambda gist_id, filename: (
            {"favorite_users": ["Alice", "Bob", "Charlie"]}
            if filename == "favorites.json"
            else {
                "default_count": 500,
                "users": [
                    {"user": "Alice", "done": True, "skip_count": 1},
                    {"user": "kira_kira0nly1", "done": True, "skip_count": 2}, # 解除済み
                    {"user": "PendingUser", "done": False}, # アプリからの未処理リクエスト
                ]
            }
        )
        mock_update_gist.return_value = True

        ok = sync_favorites.sync_favorites_to_queue("dummy_fav", "dummy_q0", dry_run=False)
        self.assertTrue(ok)
        
        self.assertTrue(mock_update_gist.called)
        call_args = mock_update_gist.call_args[0]
        updated_data = call_args[2]
        updated_users = updated_data["users"]
        user_names = [u["user"] for u in updated_users]

        # Alice: 既存お気に入り（維持、状態保持）
        self.assertIn("Alice", user_names)
        alice_entry = next(u for u in updated_users if u["user"] == "Alice")
        self.assertEqual(alice_entry["skip_count"], 1)

        # kira_kira0nly1: お気に入り解除済み（除外）
        self.assertNotIn("kira_kira0nly1", user_names)

        # PendingUser: 未処理（done: false）のアプリリクエスト（保護）
        self.assertIn("PendingUser", user_names)

        # Bob, Charlie: 新規お気に入り（追加）
        self.assertIn("Bob", user_names)
        self.assertIn("Charlie", user_names)

if __name__ == "__main__":
    unittest.main()
