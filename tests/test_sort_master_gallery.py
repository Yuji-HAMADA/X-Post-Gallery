import unittest
from scripts.sort_master_gallery import (
    get_tweet_sort_key,
    select_latest_thumbnail_tweet,
    sort_master_gallery,
)

class TestSortMasterGallery(unittest.TestCase):
    def test_get_tweet_sort_key_snowflake(self):
        # Snowflake ID のタイムスタンプ算出
        # ID: 1768875567341850624 -> ms: 1710569766952
        tweet = {"id_str": "1768875567341850624"}
        key = get_tweet_sort_key(tweet)
        self.assertGreater(key, 1700000000000)

    def test_get_tweet_sort_key_created_at(self):
        tweet = {"id_str": "", "created_at": "Wed Oct 10 20:19:24 +0000 2018"}
        key = get_tweet_sort_key(tweet)
        self.assertGreater(key, 1500000000000)

    def test_select_latest_thumbnail_tweet_prefers_media_and_newest(self):
        tweets = [
            # 1. 古いメディア付きツイート
            {"id_str": "1000000000000000000", "media_urls": ["https://old_img.jpg"]},
            # 2. 最新だがテキストのみ（メディアなし）
            {"id_str": "3000000000000000000", "media_urls": []},
            # 3. 新しいメディア付きツイート
            {"id_str": "2000000000000000000", "media_urls": ["https://new_img.jpg"]},
        ]
        best = select_latest_thumbnail_tweet(tweets)
        # メディア付きの中で最新の 2000000000000000000 が選ばれること
        self.assertEqual(best["id_str"], "2000000000000000000")
        self.assertEqual(best["media_urls"], ["https://new_img.jpg"])

    def test_sort_master_gallery_logic(self):
        master_data = {
            "user_gists": {
                # 未ピン留め: UserB (最新: ID 300)
                "UserB": {"gist_id": "g_b", "priority_updated_at": 0},
                # ピン留め: PinA (最新: ID 100)
                "PinA": {"gist_id": "g_pa", "priority_updated_at": 1000},
                # 未ピン留め: UserA (最新: ID 200)
                "UserA": {"gist_id": "g_a", "priority_updated_at": 0},
                # ピン留め: PinB (最新: ID 400)
                "PinB": {"gist_id": "g_pb", "priority_updated_at": 2000},
            },
            "tweets": [
                {"id_str": "1000000000000000000", "username": "PinA", "media_urls": ["pa.jpg"]},
                {"id_str": "4000000000000000000", "username": "PinB", "media_urls": ["pb.jpg"]},
                {"id_str": "2000000000000000000", "username": "UserA", "media_urls": ["ua.jpg"]},
                {"id_str": "3000000000000000000", "username": "UserB", "media_urls": ["ub.jpg"]},
            ],
        }

        sorted_data, pinned, unpinned, sort_keys = sort_master_gallery(
            master_data,
            fetch_child=False,
        )

        # ピン留めグループ内ソート: PinB (400) -> PinA (100)
        self.assertEqual(pinned, ["PinB", "PinA"])

        # 未ピン留めグループ内ソート: UserB (300) -> UserA (200)
        self.assertEqual(unpinned, ["UserB", "UserA"])

        # 全体のキー順序
        expected_keys = ["PinB", "PinA", "UserB", "UserA"]
        self.assertEqual(list(sorted_data["user_gists"].keys()), expected_keys)

        # tweets の順序
        tweet_users = [t["username"] for t in sorted_data["tweets"]]
        self.assertEqual(tweet_users, expected_keys)

        # ピン留めグループの priority_updated_at がポスト時刻に合わせて更新されていること (PinB > PinA > 0)
        p_b = sorted_data["user_gists"]["PinB"]["priority_updated_at"]
        p_a = sorted_data["user_gists"]["PinA"]["priority_updated_at"]
        self.assertGreater(p_b, p_a)
        self.assertGreater(p_a, 0)

        # 未ピン留めは priority_updated_at == 0 であること
        self.assertEqual(sorted_data["user_gists"]["UserB"]["priority_updated_at"], 0)
        self.assertEqual(sorted_data["user_gists"]["UserA"]["priority_updated_at"], 0)

if __name__ == "__main__":
    unittest.main()
