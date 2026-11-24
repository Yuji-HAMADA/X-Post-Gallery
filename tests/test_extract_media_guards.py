import unittest
from unittest.mock import patch
import sys
import os

# scripts ディレクトリを path に追加
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))

from unittest.mock import MagicMock
try:
    import playwright
except ImportError:
    mock_playwright = MagicMock()
    sys.modules["playwright"] = mock_playwright
    sys.modules["playwright.async_api"] = mock_playwright.async_api

import extract_media
import append_to_gist

class TestExtractMediaGuards(unittest.TestCase):
    def test_extract_media_default_guards(self):
        """extract_media.py のデフォルトセーフティガード値が正しく設定されていること"""
        test_args = ["extract_media.py", "-u", "test_user"]
        with patch.object(sys, "argv", test_args):
            args = extract_media.parse_args()
            self.assertFalse(hasattr(args, "max_scrolls"))
            self.assertEqual(args.max_no_new_scrolls, 40)
            self.assertEqual(args.max_runtime, 7200)

    def test_extract_media_custom_guards(self):
        """extract_media.py のカスタムセーフティガード値が正しくパースされること"""
        test_args = [
            "extract_media.py",
            "-u", "test_user",
            "--max-no-new-scrolls", "20",
            "--max-runtime", "300",
        ]
        with patch.object(sys, "argv", test_args):
            args = extract_media.parse_args()
            self.assertEqual(args.max_no_new_scrolls, 20)
            self.assertEqual(args.max_runtime, 300)

    def test_append_to_gist_guard_options(self):
        """append_to_gist.py がガード引数を正しく受け取ること"""
        test_args = [
            "append_to_gist.py",
            "-g", "dummy_gist_id",
            "-u", "test_user",
            "--max-no-new-scrolls", "25",
            "--max-runtime", "400",
        ]
        with patch.object(sys, "argv", test_args):
            args = append_to_gist.parse_args()
            self.assertFalse(hasattr(args, "max_scrolls"))
            self.assertEqual(args.max_no_new_scrolls, 25)
            self.assertEqual(args.max_runtime, 400)

    @patch("subprocess.run")
    def test_run_extraction_passes_guards(self, mock_run):
        """run_extraction が extract_media.py にセーフティガード引数を伝搬すること"""
        mock_run.return_value.returncode = 0

        test_args = [
            "append_to_gist.py",
            "-g", "dummy_gist_id",
            "-u", "test_user",
            "--max-no-new-scrolls", "33",
            "--max-runtime", "555",
        ]
        with patch.object(sys, "argv", test_args):
            args = append_to_gist.parse_args()
            append_to_gist.run_extraction(args, "/tmp/dummy_skip_ids.txt")

            called_cmd = mock_run.call_args[0][0]
            self.assertNotIn("--max-scrolls", called_cmd)
            self.assertIn("--max-no-new-scrolls", called_cmd)
            self.assertIn("33", called_cmd)
            self.assertIn("--max-runtime", called_cmd)
            self.assertIn("555", called_cmd)

    def test_build_tweet_data_from_raw_photo(self):
        """raw_info から画像付きツイートデータが正しく構築されること"""
        import asyncio
        raw_info = {
            "origin_user": "test_user",
            "origin_status_id": "1234567890",
            "is_pinned": False,
            "raw_text": "Hello world",
            "photo_urls": ["https://pbs.twimg.com/media/abc?format=jpg"],
            "has_video": False,
            "timestamp": "2026-11-10T00:00:00.000Z"
        }
        mock_page = MagicMock()
        data = asyncio.run(extract_media.build_tweet_data_from_raw(mock_page, raw_info))
        self.assertIsNotNone(data)
        self.assertEqual(data["tweet"]["id_str"], "1234567890")
        self.assertEqual(data["tweet"]["full_text"], "@test_user: Hello world")
        self.assertEqual(len(data["tweet"]["entities"]["media"]), 1)
        self.assertEqual(data["tweet"]["entities"]["media"][0]["type"], "photo")
        self.assertEqual(data["is_pinned"], False)
        # UTC 00:00:00 -> JST 09:00:00
        self.assertEqual(data["tweet"]["created_at"], "2026-11-10 09:00:00 JST")

    def test_to_jst_timestamp(self):
        """to_jst_timestamp が ISO UTC 文字列を JST に変換すること"""
        self.assertEqual(extract_media.to_jst_timestamp("2026-11-10T15:30:00.000Z"), "2026-11-11 00:30:00 JST")
        self.assertEqual(extract_media.to_jst_timestamp("Tue Nov 24 22:04:39 +0000 2026"), "2026-11-25 07:04:39 JST")
        self.assertEqual(extract_media.to_jst_timestamp("2026-11-10 09:00:00 JST"), "2026-11-10 09:00:00 JST")
        self.assertEqual(extract_media.to_jst_timestamp(""), "")
        self.assertEqual(extract_media.to_jst_timestamp("invalid_date"), "invalid_date")

    def test_extract_tweets_from_graphql_payload(self):
        """UserOriginalsTimeline / UserTweets GraphQL から画像・動画・固定を抽出しRT/広告を除外すること"""
        self.assertTrue(extract_media.is_user_tweets_graphql_url(
            "https://x.com/i/api/graphql/ZFKu1DFS63hgrkLzR3Hsdw/UserOriginalsTimeline?variables=%7B%7D"
        ))
        payload = {
            "data": {
                "user": {
                    "result": {
                        "timeline": {
                            "timeline": {
                                "instructions": [
                                    {
                                        "type": "TimelinePinEntry",
                                        "entry": {
                                            "entryId": "tweet-100",
                                            "content": {
                                                "itemContent": {
                                                    "tweet_results": {
                                                        "result": {
                                                            "rest_id": "100",
                                                            "core": {"user_results": {"result": {"core": {"screen_name": "creator_x"}}}},
                                                            "legacy": {
                                                                "full_text": "pinned photo",
                                                                "created_at": "Tue Nov 24 00:00:00 +0000 2026",
                                                                "extended_entities": {
                                                                    "media": [{"type": "photo", "media_url_https": "https://pbs.twimg.com/media/pin.jpg&name=small"}]
                                                                },
                                                            },
                                                        }
                                                    }
                                                }
                                            },
                                        },
                                    },
                                    {
                                        "type": "TimelineAddEntries",
                                        "entries": [
                                            {
                                                "entryId": "tweet-200",
                                                "content": {
                                                    "itemContent": {
                                                        "tweet_results": {
                                                            "result": {
                                                                "rest_id": "200",
                                                                "core": {"user_results": {"result": {"core": {"screen_name": "creator_x"}}}},
                                                                "legacy": {
                                                                    "full_text": "video post",
                                                                    "created_at": "Tue Nov 24 15:00:00 +0000 2026",
                                                                    "extended_entities": {
                                                                        "media": [{
                                                                            "type": "video",
                                                                            "media_url_https": "https://pbs.twimg.com/media/poster.jpg",
                                                                            "video_info": {
                                                                                "variants": [
                                                                                    {"content_type": "video/mp4", "bitrate": 832000, "url": "https://video.twimg.com/low.mp4"},
                                                                                    {"content_type": "video/mp4", "bitrate": 2176000, "url": "https://video.twimg.com/hi.mp4"},
                                                                                ]
                                                                            },
                                                                        }]
                                                                    },
                                                                },
                                                            }
                                                        }
                                                    }
                                                },
                                            },
                                            {
                                                "entryId": "tweet-300",
                                                "content": {
                                                    "itemContent": {
                                                        "tweet_results": {
                                                            "result": {
                                                                "rest_id": "300",
                                                                "core": {"user_results": {"result": {"core": {"screen_name": "creator_x"}}}},
                                                                "legacy": {
                                                                    "full_text": "RT @other: skip me",
                                                                    "retweeted_status_result": {"result": {}},
                                                                    "extended_entities": {"media": [{"type": "photo", "media_url_https": "https://pbs.twimg.com/media/rt.jpg"}]},
                                                                },
                                                            }
                                                        }
                                                    }
                                                },
                                            },
                                            {
                                                "entryId": "promoted-tweet-400",
                                                "content": {"itemContent": {"promotedMetadata": {}, "tweet_results": {"result": {"rest_id": "400"}}}},
                                            },
                                            {
                                                "entryId": "cursor-bottom-1",
                                                "content": {"cursorType": "Bottom", "value": "CUR_NEXT"},
                                            },
                                        ],
                                    },
                                ]
                            }
                        }
                    }
                }
            }
        }

        records, tids, cursor = extract_media.extract_tweets_from_graphql_payload(payload, fallback_user="creator_x")
        self.assertEqual(cursor, "CUR_NEXT")
        self.assertEqual(tids, ["200"])
        self.assertEqual(len(records), 2)
        # 1. Pinned photo
        tid0, pin0, item0 = records[0]
        self.assertEqual(tid0, "100")
        self.assertTrue(pin0)
        self.assertEqual(item0["tweet"]["created_at"], "2026-11-24 09:00:00 JST")
        self.assertEqual(item0["tweet"]["entities"]["media"][0]["media_url_https"], "https://pbs.twimg.com/media/pin.jpg")
        # 2. Video (highest bitrate MP4 directly from GraphQL)
        tid1, pin1, item1 = records[1]
        self.assertEqual(tid1, "200")
        self.assertFalse(pin1)
        self.assertEqual(item1["tweet"]["created_at"], "2026-11-25 00:00:00 JST")
        self.assertEqual(
            item1["tweet"]["extended_entities"]["media"][0]["video_info"]["variants"][0]["url"],
            "https://video.twimg.com/hi.mp4",
        )

    def test_build_tweet_data_from_raw_no_media(self):
        """メディアがない場合は None が返ること"""
        import asyncio
        raw_info = {
            "origin_user": "test_user",
            "origin_status_id": "1234567890",
            "is_pinned": False,
            "raw_text": "No media tweet",
            "photo_urls": [],
            "has_video": False,
            "timestamp": "2026-11-10T00:00:00.000Z"
        }
        mock_page = MagicMock()
        data = asyncio.run(extract_media.build_tweet_data_from_raw(mock_page, raw_info))
        self.assertIsNone(data)

    def test_extract_article_js_ad_filtering(self):
        """EXTRACT_ARTICLE_JS がプロモーションテキストを除外し、placementTracking を持つ動画ポストは除外せず抽出すること"""
        import asyncio
        from playwright.async_api import async_playwright

        async def _run():
            async with async_playwright() as p:
                browser = await p.chromium.launch(headless=True)
                page = await browser.new_page()

                # 通常のツイート、プロモーションツイート、placementTrackingを含む動画ポスト
                await page.set_content('''
                    <article id="normal">
                        <time datetime="2026-11-15T00:00:00.000Z"><a href="/user1/status/100">now</a></time>
                        <div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/test?format=jpg" /></div>
                        <div data-testid="tweetText">Normal tweet</div>
                    </article>
                    <article id="ad_promo_ja">
                        <time datetime="2026-11-15T00:00:00.000Z"><a href="/aduser/status/200">now</a></time>
                        <div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/ad?format=jpg" /></div>
                        <div>プロモーション</div>
                    </article>
                    <article id="ad_promoted_en">
                        <time datetime="2026-11-15T00:00:00.000Z"><a href="/aduser2/status/300">now</a></time>
                        <div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/ad2?format=jpg" /></div>
                        <span>Promoted</span>
                    </article>
                    <article id="video_placement_attr">
                        <time datetime="2026-11-15T00:00:00.000Z"><a href="/videouser/status/400">now</a></time>
                        <div data-testid="placementTracking">
                            <div data-testid="videoPlayer"></div>
                        </div>
                        <div data-testid="tweetText">Video tweet</div>
                    </article>
                ''')

                normal_el = await page.query_selector('#normal')
                promo_ja_el = await page.query_selector('#ad_promo_ja')
                promoted_en_el = await page.query_selector('#ad_promoted_en')
                video_placement_el = await page.query_selector('#video_placement_attr')

                res_normal = await normal_el.evaluate(extract_media.EXTRACT_ARTICLE_JS)
                res_promo_ja = await promo_ja_el.evaluate(extract_media.EXTRACT_ARTICLE_JS)
                res_promoted_en = await promoted_en_el.evaluate(extract_media.EXTRACT_ARTICLE_JS)
                res_video = await video_placement_el.evaluate(extract_media.EXTRACT_ARTICLE_JS)

                await browser.close()
                return res_normal, res_promo_ja, res_promoted_en, res_video

        normal, promo_ja, promo_en, video = asyncio.run(_run())
        self.assertIsNotNone(normal)
        self.assertEqual(normal["origin_user"], "user1")
        self.assertIsNone(promo_ja)
        self.assertIsNone(promo_en)
        self.assertIsNotNone(video)
        self.assertEqual(video["origin_user"], "videouser")
        self.assertEqual(video["origin_status_id"], "400")
        self.assertTrue(video["has_video"])

if __name__ == "__main__":
    unittest.main()
