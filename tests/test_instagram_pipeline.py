import os
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

try:
    import playwright  # noqa: F401
except ImportError:
    mock_pw = MagicMock()
    sys.modules["playwright"] = mock_pw
    sys.modules["playwright.async_api"] = mock_pw.async_api

import extract_instagram_media as ig_ext
import append_to_gist
import sort_master_gallery


class TestInstagramPipeline(unittest.TestCase):
    def test_extract_carousel_and_video_to_gist_format(self):
        """Instagram のカルーセル・動画・広告除外・X互換アーカイブ変換が正しく動作すること"""
        payload = {
            "data": {
                "xdt_api__v1__feed__user_timeline_graphql_connection": {
                    "edges": [
                        {
                            "node": {
                                "pk": "4033243665556695716",
                                "code": "AbCdEf123",
                                "taken_at": 1795000000,
                                "user": {"username": "sample_ig_user"},
                                "caption": {"text": "carousel caption"},
                                "carousel_media": [
                                    {"image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/img1.jpg?oe=6B0AFC30", "width": 1080, "height": 1350}]}},
                                    {"image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/img2.jpg?oe=6B0AFC30", "width": 1080, "height": 1350}]}},
                                ],
                            }
                        },
                        {
                            "node": {
                                "pk": "4037171921773934012",
                                "code": "ReelCode99",
                                "taken_at": 1795100000,
                                "product_type": "clips",
                                "user": {"username": "sample_ig_user"},
                                "caption": {"text": "reel caption"},
                                "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/poster.jpg?oe=6B0AFC30", "width": 720, "height": 1280}]},
                                "video_versions": [{"url": "https://scontent.cdninstagram.com/video.mp4?oe=6B0AFC30", "width": 720, "height": 1280}],
                            }
                        },
                        {
                            "node": {
                                "pk": "9999999999999999999",
                                "code": "AdPost",
                                "ad_id": "12345",
                                "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/ad.jpg", "width": 500, "height": 500}]},
                            }
                        },
                    ]
                }
            }
        }

        posts = ig_ext.extract_posts_from_payload(payload)
        self.assertEqual(len(posts), 2)

        archive_items = [ig_ext.to_archive_tweet_format(p) for p in posts]
        converted = append_to_gist.convert_raw_tweets_to_gist_format(archive_items)
        self.assertEqual(len(converted), 2)

        # カルーセル
        self.assertEqual(converted[0]["id_str"], "4033243665556695716")
        self.assertEqual(converted[0]["post_url"], "https://www.instagram.com/p/AbCdEf123/")
        self.assertEqual(len(converted[0]["media_urls"]), 2)
        self.assertTrue(converted[0]["full_text"].startswith("@sample_ig_user: carousel caption"))

        # リール動画
        self.assertEqual(converted[1]["id_str"], "4037171921773934012")
        self.assertEqual(converted[1]["post_url"], "https://www.instagram.com/reel/ReelCode99/")
        self.assertEqual(converted[1]["media_urls"], ["https://scontent.cdninstagram.com/poster.jpg?oe=6B0AFC30"])
        self.assertEqual(converted[1]["video_url"], "https://scontent.cdninstagram.com/video.mp4?oe=6B0AFC30")
        self.assertEqual(converted[1]["video_urls"], ["https://scontent.cdninstagram.com/video.mp4?oe=6B0AFC30"])

    def test_instagram_sort_key_uses_created_at_not_twitter_snowflake(self):
        """Instagram の 19桁 pk に対して Twitter Snowflake 変換を行わず created_at で正しくソートされること"""
        older_ig = {
            "id_str": "4099999999999999999",
            "post_url": "https://www.instagram.com/p/OLD/",
            "created_at": "2026-11-10 10:00:00 JST",
            "media_urls": ["https://scontent.cdninstagram.com/old.jpg"],
        }
        newer_ig = {
            "id_str": "4011111111111111111",
            "post_url": "https://www.instagram.com/p/NEW/",
            "created_at": "2026-11-24 12:00:00 JST",
            "media_urls": ["https://scontent.cdninstagram.com/new.jpg"],
        }
        self.assertGreater(
            append_to_gist.get_tweet_sort_key(newer_ig),
            append_to_gist.get_tweet_sort_key(older_ig),
        )
        self.assertGreater(
            sort_master_gallery.get_tweet_sort_key(newer_ig),
            sort_master_gallery.get_tweet_sort_key(older_ig),
        )

    def test_instagram_url_expiry_and_inplace_refresh(self):
        """oe= 有効期限切れ間近の検知と、既存投稿URLのインプレースリフレッシュが動作すること"""
        now_ts = 1795500000
        # 10時間後に期限切れ (画像 buffer 24h 以内 -> 要リフレッシュ)
        expiring_hex = format(now_ts + 10 * 3600, "X")
        # 72時間後に期限切れ (画像 buffer 24h 超 -> 不要)
        fresh_hex = format(now_ts + 72 * 3600, "X")
        # 動画URL: 残り20時間 (動画 buffer 6h 超 -> リフレッシュ不要で毎回再取得を防止)
        video_fresh_hex = format(now_ts + 20 * 3600, "X")
        # 動画URL: 残り3時間 (動画 buffer 6h 以内 -> 要リフレッシュ)
        video_expiring_hex = format(now_ts + 3 * 3600, "X")

        existing = [
            {
                "id_str": "1001",
                "post_url": "https://www.instagram.com/p/AAA/",
                "media_urls": [f"https://scontent.cdninstagram.com/a.jpg?oe={expiring_hex}"],
            }
        ]
        self.assertTrue(append_to_gist.needs_instagram_url_refresh(existing, buffer_seconds=24 * 3600, now=now_ts))

        # 動画寿命(~24h)の取得直後(残り20h)はリフレッシュ不要、残り3hなら要リフレッシュ
        video_ok_post = [{
            "id_str": "2001",
            "media_urls": [f"https://scontent.cdninstagram.com/p.jpg?oe={fresh_hex}"],
            "video_urls": [f"https://scontent.cdninstagram.com/v.mp4?oe={video_fresh_hex}"],
        }]
        self.assertFalse(append_to_gist.needs_instagram_url_refresh(video_ok_post, now=now_ts))
        video_soon_post = [{
            "id_str": "2002",
            "media_urls": [f"https://scontent.cdninstagram.com/p.jpg?oe={fresh_hex}"],
            "video_urls": [f"https://scontent.cdninstagram.com/v.mp4?oe={video_expiring_hex}"],
        }]
        self.assertTrue(append_to_gist.needs_instagram_url_refresh(video_soon_post, now=now_ts))

        # check_limit より後ろの古い投稿は無視して無限リフレッシュを防止
        self.assertFalse(append_to_gist.needs_instagram_url_refresh(video_ok_post + existing, check_limit=1, now=now_ts))

        refreshed_input = [
            {
                "id_str": "1002",
                "post_url": "https://www.instagram.com/p/BBB/",
                "media_urls": [f"https://scontent.cdninstagram.com/b.jpg?oe={fresh_hex}"],
            },
            {
                "id_str": "1001",
                "post_url": "https://www.instagram.com/p/AAA/",
                "media_urls": [f"https://scontent.cdninstagram.com/a_new.jpg?oe={fresh_hex}"],
            },
        ]
        merged = append_to_gist.append_tweets(existing, refreshed_input, refresh_urls=True)
        self.assertEqual([t["id_str"] for t in merged], ["1002", "1001"])
        self.assertEqual(merged[1]["media_urls"], [f"https://scontent.cdninstagram.com/a_new.jpg?oe={fresh_hex}"])
        self.assertFalse(append_to_gist.needs_instagram_url_refresh(merged, buffer_seconds=48 * 3600, now=now_ts))

        # マスターサムネイルURL差し替え検知
        old_master = [{"username": "u1", "id_str": "1001", "created_at": "2026-11-24 10:00:00 JST", "media_urls": ["https://old"]}]
        new_master = [{"username": "u1", "id_str": "1001", "created_at": "2026-11-24 10:00:00 JST", "media_urls": ["https://new"]}]
        self.assertTrue(append_to_gist.has_master_tweets_changed(old_master, new_master, "u1"))

    @patch("subprocess.run")
    def test_run_extraction_dispatches_instagram(self, mock_run):
        """--platform instagram 指定時に extract_instagram_media.py が呼び出されること"""
        mock_run.return_value.returncode = 0
        with patch.object(sys, "argv", ["append_to_gist.py", "-g", "gid", "-u", "ig_user", "--platform", "instagram"]):
            args = append_to_gist.parse_args()
            append_to_gist.run_extraction(args, "/tmp/dummy_skip.txt")
        called_cmd = mock_run.call_args[0][0]
        self.assertIn("scripts/extract_instagram_media.py", called_cmd)
        self.assertIn(append_to_gist.IG_TWEETS_JS, called_cmd)

    def test_profile_only_excludes_home_feed_and_forces_collab_user(self):
        """profile_only=True で背景ホームフィード先読みを除外し、コラボ投稿を対象ユーザー名義で保存すること"""
        home_feed_payload = {
            "data": {
                "xdt_api__v1__feed__timeline__connection": {
                    "edges": [
                        {
                            "node": {
                                "media": {
                                    "pk": "1111111",
                                    "code": "HomeFeed1",
                                    "user": {"username": "unrelated_home_user"},
                                    "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/h.jpg", "width": 1080, "height": 1080}]},
                                }
                            }
                        }
                    ]
                }
            }
        }
        self.assertEqual(ig_ext.extract_posts_from_payload(home_feed_payload, profile_only=True), [])
        self.assertEqual(len(ig_ext.extract_posts_from_payload(home_feed_payload, profile_only=False)), 1)

        profile_payload = {
            "data": {
                "xdt_api__v1__feed__user_timeline_graphql_connection": {
                    "edges": [
                        {
                            "node": {
                                "pk": "2222222",
                                "code": "CollabPost1",
                                "taken_at": 1795100000,
                                "user": {"username": "collab_partner"},
                                "caption": {"text": "joint post"},
                                "image_versions2": {"candidates": [{"url": "https://scontent.cdninstagram.com/c.jpg", "width": 1080, "height": 1080}]},
                            }
                        }
                    ],
                    "page_info": {"has_next_page": False},
                }
            }
        }
        posts = ig_ext.extract_posts_from_payload(profile_payload, profile_only=True)
        self.assertEqual(len(posts), 1)
        self.assertIs(ig_ext.extract_profile_has_next_page(profile_payload), False)

        archive_item = ig_ext.to_archive_tweet_format(posts[0], fallback_user="target_profile", force_user="target_profile")
        converted = append_to_gist.convert_raw_tweets_to_gist_format([archive_item])
        grouped = append_to_gist.group_tweets_by_user(converted)
        self.assertEqual(list(grouped.keys()), ["target_profile"])
        self.assertIn("[collab @collab_partner]", converted[0]["full_text"])

    def test_validate_master_gist_update_blocks_cross_platform_and_shrink(self):
        """Xマスター更新時にInstagramデータ混入や大幅減少をブロックすること"""
        initial = {f"user_{i}": f"g_{i}" for i in range(100)}
        # 1. プラットフォーム不一致（Xなのに user_screen_name=Instagram）
        ok1, _ = append_to_gist.validate_master_gist_update(
            initial,
            {"user_screen_name": "Instagram", "user_gists": initial, "tweets": []},
            platform="x",
        )
        self.assertFalse(ok1)

        # 2. 急激な減少（100 -> 10）
        small = {f"user_{i}": f"g_{i}" for i in range(10)}
        ok2, _ = append_to_gist.validate_master_gist_update(
            initial,
            {"user_screen_name": "", "user_gists": small, "tweets": []},
            platform="x",
        )
        self.assertFalse(ok2)

        # 3. 正常な増加（100 -> 101）
        grown = dict(initial)
        grown["user_new"] = "g_new"
        ok3, _ = append_to_gist.validate_master_gist_update(
            initial,
            {"user_screen_name": "", "user_gists": grown, "tweets": []},
            platform="x",
        )
        self.assertTrue(ok3)


if __name__ == "__main__":
    unittest.main()
