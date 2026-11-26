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

import extract_tiktok_media as tt_ext
import poc_extract_tiktok as tt_poc
import append_to_gist
import sort_master_gallery


class TestTikTokPipeline(unittest.TestCase):
    def test_extract_video_photo_mode_and_exclude_ad(self):
        """TikTok 動画（最高ビットレート＋サムネ）・フォトモード抽出および広告除外が正しく動作すること"""
        payload = {
            "itemList": [
                {
                    "id": "7695367993454251271",
                    "desc": "sample video caption",
                    "createTime": 1795000000,
                    "isAd": False,
                    "author": {"uniqueId": "sample_tt_creator"},
                    "video": {
                        "originCover": "https://p16-common-sign.tiktokcdn.com/cover.jpg?x-expires=1800000000",
                        "bitrateInfo": [
                            {"Bitrate": 500000, "PlayAddr": {"UrlList": ["https://v16-webapp-prime.tiktok.com/low.mp4?expire=1800000000"]}},
                            {"Bitrate": 2000000, "PlayAddr": {"UrlList": ["https://v16-webapp-prime.tiktok.com/high.mp4?expire=1800000000"]}},
                        ],
                    },
                },
                {
                    "id": "7695367993454259999",
                    "desc": "photo mode post",
                    "createTime": 1795100000,
                    "isAd": False,
                    "author": {"uniqueId": "sample_tt_creator"},
                    "imagePost": {
                        "images": [
                            {"imageURL": {"urlList": ["https://p16-common-sign.tiktokcdn.com/slide1.jpg?x-expires=1800000000"]}},
                            {"imageURL": {"urlList": ["https://p16-common-sign.tiktokcdn.com/slide2.jpg?x-expires=1800000000"]}},
                        ]
                    },
                },
                {
                    "id": "9999999999999999999",
                    "desc": "sponsored ad",
                    "isAd": True,
                    "author": {"uniqueId": "ad_brand"},
                    "video": {"playAddr": "https://v16-webapp-prime.tiktok.com/ad.mp4"},
                },
            ]
        }

        posts = tt_ext.extract_items_from_payload(payload)
        self.assertEqual(len(posts), 2)

        archive_items = [tt_ext.to_archive_tweet_format(p) for p in posts]
        converted = append_to_gist.convert_raw_tweets_to_gist_format(archive_items)
        self.assertEqual(len(converted), 2)

        # 動画投稿（サムネイル + 最高ビットレート動画URL + パーマリンク）
        self.assertEqual(converted[0]["id_str"], "7695367993454251271")
        self.assertEqual(converted[0]["post_url"], "https://www.tiktok.com/@sample_tt_creator/video/7695367993454251271")
        self.assertEqual(converted[0]["media_urls"], ["https://p16-common-sign.tiktokcdn.com/cover.jpg?x-expires=1800000000"])
        self.assertEqual(converted[0]["video_url"], "https://v16-webapp-prime.tiktok.com/high.mp4?expire=1800000000")

        # フォトモード
        self.assertEqual(converted[1]["id_str"], "7695367993454259999")
        self.assertEqual(converted[1]["post_url"], "https://www.tiktok.com/@sample_tt_creator/photo/7695367993454259999")
        self.assertEqual(len(converted[1]["media_urls"]), 2)

    def test_allowed_api_url_blocks_explore_prefetch(self):
        """バックグラウンドの Explore 先読みAPIを除外し対象モードのAPIのみ許可すること"""
        self.assertFalse(tt_ext.is_allowed_tiktok_api_url(
            "https://www.tiktok.com/api/prefetch/explore/item_list/?count=20", source_mode="foryou"
        ))
        self.assertFalse(tt_ext.is_allowed_tiktok_api_url(
            "https://www.tiktok.com/api/recommend/item_list/?count=12", source_mode="profile"
        ))
        self.assertTrue(tt_ext.is_allowed_tiktok_api_url(
            "https://www.tiktok.com/api/recommend/item_list/?count=12", source_mode="foryou"
        ))
        self.assertTrue(tt_ext.is_allowed_tiktok_api_url(
            "https://www.tiktok.com/api/post/item_list/?count=30", source_mode="profile"
        ))

    def test_tiktok_sort_key_uses_created_at_not_twitter_snowflake(self):
        """TikTok の 19桁ID に対して Twitter Snowflake 変換を行わず created_at で正しくソートされること"""
        older_tt = {
            "id_str": "7999999999999999999",
            "post_url": "https://www.tiktok.com/@u1/video/7999999999999999999",
            "created_at": "2026-11-10 10:00:00 JST",
            "media_urls": ["https://p16-common-sign.tiktokcdn.com/old.jpg"],
        }
        newer_tt = {
            "id_str": "7111111111111111111",
            "post_url": "https://www.tiktok.com/@u1/video/7111111111111111111",
            "created_at": "2026-11-26 12:00:00 JST",
            "media_urls": ["https://p16-common-sign.tiktokcdn.com/new.jpg"],
        }
        self.assertGreater(
            append_to_gist.get_tweet_sort_key(newer_tt),
            append_to_gist.get_tweet_sort_key(older_tt),
        )
        self.assertGreater(
            sort_master_gallery.get_tweet_sort_key(newer_tt),
            sort_master_gallery.get_tweet_sort_key(older_tt),
        )

    def test_tiktok_url_expiry_and_cross_platform_safety_guard(self):
        """TikTok の x-expires / expire 判定とクロスプラットフォーム上書きガードが動作すること"""
        now_ts = 1795600000
        fresh_img = f"https://p16-common-sign.tiktokcdn.com/a.jpg?x-expires={now_ts + 30 * 3600}"
        expiring_img = f"https://p16-common-sign.tiktokcdn.com/b.jpg?x-expires={now_ts + 2 * 3600}"
        fresh_vid = f"https://v16-webapp-prime.tiktok.com/v.mp4?expire={now_ts + 5 * 3600}"
        expiring_vid = f"https://v16-webapp-prime.tiktok.com/v2.mp4?expire={now_ts + 1 * 3600}"

        self.assertFalse(append_to_gist.needs_tiktok_url_refresh(
            [{"media_urls": [fresh_img], "video_urls": [fresh_vid]}], now=now_ts
        ))
        self.assertTrue(append_to_gist.needs_tiktok_url_refresh(
            [{"media_urls": [expiring_img]}], now=now_ts
        ))
        self.assertTrue(append_to_gist.needs_tiktok_url_refresh(
            [{"media_urls": [fresh_img], "video_urls": [expiring_vid]}], now=now_ts
        ))

        # クロスプラットフォーム保護
        initial = {"u1": "g1"}
        ok_x, _ = append_to_gist.validate_master_gist_update(
            initial, {"user_screen_name": "TikTok", "user_gists": initial, "tweets": []}, platform="x"
        )
        self.assertFalse(ok_x)
        ok_ig, _ = append_to_gist.validate_master_gist_update(
            initial, {"user_screen_name": "TikTok", "user_gists": initial, "tweets": []}, platform="instagram"
        )
        self.assertFalse(ok_ig)
        ok_tt, _ = append_to_gist.validate_master_gist_update(
            initial, {"user_screen_name": "Instagram", "user_gists": initial, "tweets": []}, platform="tiktok"
        )
        self.assertFalse(ok_tt)

    @patch("subprocess.run")
    def test_run_extraction_dispatches_tiktok(self, mock_run):
        """--platform tiktok 指定時に extract_tiktok_media.py が呼び出されること"""
        mock_run.return_value.returncode = 0
        with patch.object(sys, "argv", ["append_to_gist.py", "-g", "gid", "-u", "tt_user", "--platform", "tiktok"]):
            args = append_to_gist.parse_args()
            append_to_gist.run_extraction(args, "/tmp/dummy_skip.txt")
        called_cmd = mock_run.call_args[0][0]
        self.assertIn("scripts/extract_tiktok_media.py", called_cmd)
        self.assertIn(append_to_gist.TIKTOK_TWEETS_JS, called_cmd)

    def test_pick_best_video_variant_prefers_cookieless_h264(self):
        """TikTok 動画URL選出で Cookie 不要の /aweme/v1/play/ かつ H.264 を優先すること"""
        video_obj = {
            "bitrateInfo": [
                {
                    "Bitrate": 3000000,
                    "CodecType": "h265_hvc1",
                    "PlayAddr": {
                        "UrlList": [
                            "https://v16-webapp-prime.tiktok.com/hevc.mp4",
                            "https://www.tiktok.com/aweme/v1/play/?video_id=hevc_high",
                        ]
                    },
                },
                {
                    "Bitrate": 1200000,
                    "CodecType": "h264",
                    "PlayAddr": {
                        "UrlList": [
                            "https://v16-webapp-prime.tiktok.com/h264.mp4",
                            "https://v19-webapp-prime.tiktok.com/h264.mp4",
                            "https://www.tiktok.com/aweme/v1/play/?video_id=h264_main",
                        ]
                    },
                },
            ]
        }
        url, br = tt_ext._pick_best_video_variant(video_obj)
        self.assertEqual(url, "https://www.tiktok.com/aweme/v1/play/?video_id=h264_main")
        self.assertEqual(br, 1200000)

    def test_poc_parse_cookies_input(self):
        """Cookie ヘッダおよび JSON 配列が TikTok Playwright Cookie へ変換されること"""
        c1 = tt_poc.parse_cookies_input("Cookie: sessionid=s1; sid_tt=t1")
        self.assertEqual({c["name"] for c in c1}, {"sessionid", "sid_tt"})
        self.assertTrue(all(c["domain"] == ".tiktok.com" for c in c1))


if __name__ == "__main__":
    unittest.main()
