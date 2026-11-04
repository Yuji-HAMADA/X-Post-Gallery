#!/usr/bin/env python3
"""
test_adaptive_skip.py - アダプティブ・スキップ機能のユニットテスト
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# scripts ディレクトリを path に追加
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

from adaptive_skip import AdaptiveSkipManager


class TestAdaptiveSkipManager(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_file = os.path.join(self.temp_dir.name, "test_state.json")
        self.manager = AdaptiveSkipManager(state_file=self.state_file, max_skip=5)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_initial_state(self):
        """初期状態のアカウントはスキップされずクロール対象となること"""
        skip, remaining, count = self.manager.should_skip("user1")
        self.assertFalse(skip)
        self.assertEqual(remaining, 0)
        self.assertEqual(count, 0)

    def test_incremental_backoff_on_zero_tweets(self):
        """0件保存時にスキップカウンタが段階的にインクリメントされ、指定回数スキップされること"""
        # 1回目の0件
        count, remaining = self.manager.record_result("user1", 0)
        self.assertEqual(count, 1)
        self.assertEqual(remaining, 1)

        # 巡回1回目: スキップされる (残り 1 -> 0)
        skip, rem, cnt = self.manager.should_skip("user1")
        self.assertTrue(skip)
        self.assertEqual(rem, 0)
        self.assertEqual(cnt, 1)

        # 巡回2回目: 残り0なのでクロール実行対象
        skip, rem, cnt = self.manager.should_skip("user1")
        self.assertFalse(skip)
        self.assertEqual(rem, 0)
        self.assertEqual(cnt, 1)

        # 再度0件保存 -> レベル2へ
        count, remaining = self.manager.record_result("user1", 0)
        self.assertEqual(count, 2)
        self.assertEqual(remaining, 2)

        # 巡回3回目: スキップされる (残り 2 -> 1)
        skip, rem, cnt = self.manager.should_skip("user1")
        self.assertTrue(skip)
        self.assertEqual(rem, 1)
        self.assertEqual(cnt, 2)

        # 巡回4回目: スキップされる (残り 1 -> 0)
        skip, rem, cnt = self.manager.should_skip("user1")
        self.assertTrue(skip)
        self.assertEqual(rem, 0)
        self.assertEqual(cnt, 2)

        # 巡回5回目: 残り0なのでクロール実行対象
        skip, rem, cnt = self.manager.should_skip("user1")
        self.assertFalse(skip)

    def test_counter_reset_on_new_tweets(self):
        """1件以上の新着ツイートが保存された場合、スキップカウンタが0にリセットされること"""
        # バックオフを複数回重ねる (level 3)
        self.manager.record_result("active_user", 0)
        self.manager.record_result("active_user", 0)
        count, remaining = self.manager.record_result("active_user", 0)
        self.assertEqual(count, 3)
        self.assertEqual(remaining, 3)

        # 新着ツイートあり (> 0)
        count, remaining = self.manager.record_result("active_user", 4)
        self.assertEqual(count, 0)
        self.assertEqual(remaining, 0)

        # 次回は即座に通常クロール対象
        skip, rem, cnt = self.manager.should_skip("active_user")
        self.assertFalse(skip)
        self.assertEqual(rem, 0)
        self.assertEqual(cnt, 0)

    def test_max_skip_limit(self):
        """最大スキップ上限 (max_skip) を超えてインクリメントされないこと"""
        for _ in range(10):
            count, remaining = self.manager.record_result("dead_user", 0)

        # max_skip=5 を設定しているため、5で頭打ちになること
        self.assertEqual(count, 5)
        self.assertEqual(remaining, 5)

    def test_persistence_across_instances(self):
        """インスタンスを再生成しても状態ファイルからデータが永続化・復元されること"""
        self.manager.record_result("persist_user", 0)
        self.manager.record_result("persist_user", 0)

        # 別のマネージャーインスタンスで同一ファイルをロード
        new_manager = AdaptiveSkipManager(state_file=self.state_file, max_skip=5)
        state = new_manager.get_user_state("persist_user")

        self.assertEqual(state["skip_count"], 2)
        self.assertEqual(state["skip_remaining"], 2)
        self.assertEqual(state["consecutive_zeros"], 2)

    def test_queue_json_update_and_cycle_reset(self):
        """fetch_queue.json の更新およびサイクルリセット機能の検証"""
        queue_file = os.path.join(self.temp_dir.name, "fetch_queue.json")
        initial_data = {
            "status": "idle",
            "users": [
                {"user": "user_a", "count": 500, "done": False},
                {"user": "user_b", "count": 500, "done": False},
            ],
        }
        with open(queue_file, "w", encoding="utf-8") as f:
            json.dump(initial_data, f)

        # user_a を 0件で記録・queue更新
        self.manager.record_result("user_a", 0)
        self.manager.update_queue_json_file(
            queue_file,
            "user_a",
            skip_count=1,
            skip_remaining=1,
            done=True,
            saved_count=0,
        )

        with open(queue_file, "r", encoding="utf-8") as f:
            updated = json.load(f)

        entry_a = next(u for u in updated["users"] if u["user"] == "user_a")
        self.assertTrue(entry_a["done"])
        self.assertEqual(entry_a["skip_count"], 1)
        self.assertEqual(entry_a["skip_remaining"], 1)
        self.assertEqual(entry_a["last_saved_count"], 0)

        # user_b も done: true に設定
        entry_b = next(u for u in updated["users"] if u["user"] == "user_b")
        entry_b["done"] = True
        with open(queue_file, "w", encoding="utf-8") as f:
            json.dump(updated, f)

        # 全員 done になったのでサイクルリセット実行
        self.manager.reset_queue_cycle(queue_file)

        with open(queue_file, "r", encoding="utf-8") as f:
            reset_data = json.load(f)

        for u in reset_data["users"]:
            self.assertFalse(u["done"], f"User {u['user']} done flag should be False")

        # user_a の skip_count, skip_remaining は保持されていること
        res_a = next(u for u in reset_data["users"] if u["user"] == "user_a")
        self.assertEqual(res_a["skip_count"], 1)
        self.assertEqual(res_a["skip_remaining"], 1)


if __name__ == "__main__":
    unittest.main()
